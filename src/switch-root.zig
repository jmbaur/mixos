//! Replace the running system with another one, without rebooting the machine.
//!
//! This has to run as PID1, since the whole point is to replace the init that
//! is running. Busybox's init will do that for us: an inittab entry with the
//! "restart" action is exec'd in place of init when it receives SIGQUIT, after
//! it has run the shutdown actions and killed everything else off. So the way
//! to get here is to put this command in such an entry and send that signal.
//!
//! The system to switch into is expected at `init.sysroot` and nowhere else, so
//! that there is no way to name one the shutdown before us has already taken
//! down. Everything this command is told is named relative to there.

const std = @import("std");
const system = std.os.linux;

const Mount = @import("mount.zig");
const init_mod = @import("init.zig");
const linux = @import("linux.zig");
const log = std.log.scoped(.mixos);
const syslog = @import("syslog.zig");

const usage =
    \\usage: switch-root <manifest>
    \\
    \\  manifest  the new system's manifest, as a path within /sysroot
    \\
;

/// Loopback devices, so that one can be told apart from any other block device
/// by the number alone.
const LOOP_MAJOR = 7;

/// The loopback device the system we are running from lives on, if it is on one
/// at all.
///
/// Asked before pivoting, while that system is still mounted and can still
/// answer. The binary executing this is in its store by definition, so the
/// filesystem underneath it is the store, whatever it happens to be called.
fn loopDeviceBackingSelf() ?u32 {
    var stx: system.Statx = undefined;

    const rc = system.statx(system.AT.FDCWD, "/proc/self/exe", 0, .{}, &stx);
    if (system.errno(rc) != .SUCCESS) {
        return null;
    }

    if (stx.dev_major != LOOP_MAJOR) {
        return null;
    }

    return stx.dev_minor;
}

/// The name the kernel gives a block device we know only by number.
///
/// Asked rather than assumed. With the loopback driver set up for partitions
/// the minor numbers are spaced out, so the minor is no longer the number in
/// the name and "/dev/loop" ++ minor would be some other device entirely.
fn blockDeviceName(io: std.Io, out: []u8, major: u32, minor: u32) ?[]const u8 {
    var sys_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sys_path = std.fmt.bufPrint(
        &sys_path_buf,
        "/sys/dev/block/{d}:{d}",
        .{ major, minor },
    ) catch return null;

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.cwd().readLink(io, sys_path, &link_buf) catch return null;

    const name = std.fs.path.basename(link_buf[0..len]);
    if (name.len == 0 or name.len > out.len) {
        return null;
    }

    @memcpy(out[0..name.len], name);
    return out[0..name.len];
}

/// Let go of the loopback device the system we just left was running from.
///
/// Only that one, and only once nothing is mounted from it. An initrd boot puts
/// the whole store image in a memfd and attaches it here, so what is being
/// handed back is a copy of a system that has stopped running, sitting in RAM
/// with nothing left to read it. Nobody else will do it: the initrd that set it
/// up is long gone, and the device holds its reference until told otherwise.
///
/// Every other loopback device on the machine is somebody else's -- a disk
/// image a user attached, something a service set up -- and detaching one of
/// those destroys what it was doing, with no warning and nothing to undo it.
/// So the device is named by the kernel from the system that was actually
/// running, and checked to be that one again once open, rather than being
/// guessed at or found by sweeping /dev for whatever looks unused.
fn releaseLoopDevice(io: std.Io, minor: u32) void {
    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    const name = blockDeviceName(io, &name_buf, LOOP_MAJOR, minor) orelse {
        log.warn("cannot name loopback device {d}:{d}, leaving it alone", .{ LOOP_MAJOR, minor });
        return;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/dev/{s}", .{name}) catch return;

    const device = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| {
        log.warn("cannot open {s} to release it: {}", .{ path, err });
        return;
    };
    defer device.close(io);

    // What we opened is what we meant to open. Everything past here is a thing
    // done to whatever is on the other end of this descriptor, so being wrong
    // about which device that is has to be impossible rather than unlikely.
    var stx: system.Statx = undefined;
    const rc = system.statx(device.handle, "", system.AT.EMPTY_PATH, .{}, &stx);
    if (system.errno(rc) != .SUCCESS or stx.rdev_major != LOOP_MAJOR or stx.rdev_minor != minor) {
        log.warn("{s} is not the device the previous system was on, leaving it alone", .{path});
        return;
    }

    linux.loopbackClearFD(device.handle) catch |err| switch (err) {
        // Mounted after all, or never had anything on it. Either way there is
        // nothing here to give back.
        error.DeviceBusy, error.DeviceNotBound => return,
        else => {
            log.warn("cannot detach {s}: {}", .{ path, err });
            return;
        },
    };

    log.info("released {s}, which the previous system was running from", .{path});
}

pub fn main(
    init: std.process.Init,
    name: []const u8,
    args: *std.process.Args.Iterator,
) anyerror!void {
    syslog.init(name);
    defer syslog.deinit();

    // Replacing PID1 is the entire operation; as anyone else we would merely
    // detach ourselves from the system and leave the real init behind.
    if (system.getpid() != 1) {
        log.err("not running as PID1, refusing to continue", .{});
        return error.NotPid1;
    }

    const manifest_path = args.next() orelse {
        log.err("{s}", .{usage});
        return error.MissingManifest;
    };

    const allocator = init.arena.allocator();

    const manifest_relative = std.mem.trimStart(u8, manifest_path, std.fs.path.sep_str);

    // Read out before anything is mounted or pivoted: this is the last point at
    // which giving up costs nothing. Past it, init has already killed the rest
    // of the system off, so failures are named rather than left as an errno.
    const manifest_contents = b: {
        var sysroot_dir = std.Io.Dir.cwd().openDir(init.io, init_mod.sysroot, .{}) catch |err| {
            log.err("cannot open '{s}', where a system to switch into is staged: {}", .{ init_mod.sysroot, err });
            return err;
        };
        defer sysroot_dir.close(init.io);

        const manifest_file = sysroot_dir.openFile(init.io, manifest_relative, .{}) catch |err| {
            log.err("cannot read the manifest at '{s}/{s}': {}", .{ init_mod.sysroot, manifest_relative, err });
            return err;
        };
        defer manifest_file.close(init.io);

        var manifest_reader = manifest_file.reader(init.io, &.{});
        break :b try manifest_reader.interface.allocRemaining(allocator, .unlimited);
    };

    const parsed = try std.json.parseFromSlice(init_mod.Manifest, allocator, manifest_contents, .{});
    const manifest = parsed.value;

    // Take a handle on the store before pivoting. The old root is detached on
    // the way out, so anything we still need afterwards has to be held open
    // across it rather than looked up by name on the other side.
    var store = try Mount.initTree(std.Io.Dir.cwd(), init_mod.sysroot);

    var root_dir = try std.Io.Dir.cwd().openDir(init.io, "/", .{});
    defer root_dir.close(init.io);

    // Asked while the system we are leaving is still mounted; acted on further
    // down, once it is not.
    const old_loop_device = loopDeviceBackingSelf();

    log.info("switching to the system described by {s}/{s}", .{ init_mod.sysroot, manifest_relative });

    try init_mod.switchRoot(init.io, root_dir);

    var stage2_buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
    var stage2_fba: std.heap.FixedBufferAllocator = .init(&stage2_buffer);

    const stage2_init = try init_mod.bringUp(
        init,
        allocator,
        stage2_fba.allocator(),
        &manifest,
        .{ .tree = &store },
    );

    // Only now, with the new system mounted and the old root detached, is what
    // the old one was running from actually unused.
    if (old_loop_device) |minor| {
        releaseLoopDevice(init.io, minor);
    }

    // Everything below this point belongs to the new system.
    const argv_buf = try stage2_fba.allocator().allocSentinel(?[*:0]const u8, 1, null);
    argv_buf[0] = stage2_init;

    const err = system.errno(system.execve(
        argv_buf.ptr[0].?,
        argv_buf.ptr,
        std.process.Environ.empty.block.slice,
    ));
    log.err("execve of new init '{s}' failed: {}", .{ stage2_init, err });
    return error.ExecFailed;
}
