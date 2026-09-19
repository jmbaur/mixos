//! Replaces the running system with another one, without rebooting the
//! machine. Intended to be used with busybox's restart inittab action.

const std = @import("std");
const clap = @import("clap");
const system = std.os.linux;

const Mount = @import("mount.zig");
const init_mod = @import("init.zig");
const linux = @import("linux.zig");
const log = std.log.scoped(.mixos);
const kmsg = @import("kmsg.zig");

const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\
);

const next_store = "/run/nextstore";

fn mountOf(path: [*:0]const u8) ?u64 {
    var stx: system.Statx = undefined;

    if (system.errno(system.statx(
        system.AT.FDCWD,
        path,
        0,
        .{ .MNT_ID_UNIQUE = true },
        &stx,
    )) != .SUCCESS) {
        return null;
    }

    return stx.mnt_id;
}

// TODO(jared): use STATX_ATTR_MOUNT_ROOT when we have https://codeberg.org/ziglang/zig/pulls/36882
fn isMountpoint(comptime path: [:0]const u8) bool {
    const mount = mountOf(path) orelse return false;
    const parent = mountOf(path ++ "/..") orelse return false;
    return mount != parent;
}

fn loadManifest(allocator: std.mem.Allocator, contents: []const u8) !init_mod.Manifest {
    const parsed = try std.json.parseFromSlice(init_mod.Manifest, allocator, contents, .{});
    return parsed.value;
}

/// The manifest in the next store
fn stagedManifest(io: std.Io, allocator: std.mem.Allocator) ?init_mod.Manifest {
    if (!isMountpoint(next_store)) {
        return null;
    }

    var store_dir = std.Io.Dir.cwd().openDir(io, next_store, .{}) catch |err| {
        log.warn("cannot open {s}: {}", .{ next_store, err });
        return null;
    };
    defer store_dir.close(io);

    const manifest_file = store_dir.openFile(io, init_mod.manifest_path[1..], .{}) catch |err| {
        log.warn("no manifest at {s} under {s}: {}", .{ init_mod.manifest_path, next_store, err });
        return null;
    };
    defer manifest_file.close(io);

    var manifest_reader = manifest_file.reader(io, &.{});
    const contents = manifest_reader.interface.allocRemaining(allocator, .unlimited) catch |err| {
        log.warn("cannot read the manifest under {s}: {}", .{ next_store, err });
        return null;
    };

    return loadManifest(allocator, contents) catch |err| {
        log.warn("invalid manifest under {s}: {}", .{ next_store, err });
        return null;
    };
}

fn loopDeviceBackingPath(path: []const u8) ?u32 {
    var stx: system.Statx = undefined;

    var pathZ = std.mem.zeroes([std.fs.max_path_bytes]u8);
    std.mem.copyForwards(u8, &pathZ, path);

    if (system.errno(system.statx(
        system.AT.FDCWD,
        pathZ[0..path.len :0],
        0,
        .{},
        &stx,
    )) != .SUCCESS) {
        return null;
    }

    if (stx.dev_major != linux.LOOP_MAJOR) {
        return null;
    }

    return stx.dev_minor;
}

// Obtain loopback device name from sysfs rather than assuming block device
// name under devtmpfs.
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

fn releaseLoopDevice(io: std.Io, minor: u32) void {
    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    const name = blockDeviceName(io, &name_buf, linux.LOOP_MAJOR, minor) orelse {
        log.warn("failed to find block device path for loopback device {d}:{d}, leaving it alone", .{ linux.LOOP_MAJOR, minor });
        return;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/dev/{s}", .{name}) catch return;

    const device = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| {
        log.warn("failed to open {s}: {}", .{ path, err });
        return;
    };
    defer device.close(io);

    linux.loopbackClearFD(device.handle) catch |err| switch (err) {
        // nothing to do
        error.DeviceBusy, error.DeviceNotBound => return,
        else => {
            log.warn("failed to detach {s}: {}", .{ path, err });
            return;
        },
    };

    log.debug("released {s}", .{path});
}

pub fn main(
    init: std.process.Init,
    name: []const u8,
    args: *std.process.Args.Iterator,
) anyerror!void {
    _ = name;

    kmsg.init(init.io);
    defer kmsg.deinit();

    const allocator = init.arena.allocator();

    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.reportToFile(init.io, .stderr(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});
    }

    if (system.getpid() != 1) {
        log.err("not running as PID1, refusing to continue", .{});
        @panic("PANIC");
    }

    const staged = stagedManifest(init.io, allocator);

    const manifest = staged orelse b: {
        const manifest_file = std.Io.Dir.cwd().openFile(init.io, init_mod.active_manifest_path, .{}) catch |err| {
            log.err("cannot read the running system's manifest '{s}': {}", .{ init_mod.active_manifest_path, err });
            return err;
        };
        defer manifest_file.close(init.io);

        var manifest_reader = manifest_file.reader(init.io, &.{});
        break :b try loadManifest(
            allocator,
            try manifest_reader.interface.allocRemaining(allocator, .unlimited),
        );
    };

    // Take a handle on the store before pivoting. The old root is detached on
    // the way out, so anything we still need afterwards has to be held open
    // across it rather than looked up by name on the other side. Bringing the
    // running system up again, that store is the one we are already running
    // from, which is held open across the pivot the same way.
    var store = try Mount.initTree(
        std.Io.Dir.cwd(),
        if (staged == null) manifest.storeDir else next_store,
    );

    var root_dir = try std.Io.Dir.cwd().openDir(init.io, "/", .{});
    defer root_dir.close(init.io);

    // Ensure we know which loop device we might need to release after
    // switching, to ensure we can clean up resources from the first system.
    const old_loop_device = if (staged == null) null else loopDeviceBackingPath(manifest.storeDir);

    log.info("switching to {s}", .{if (staged == null) "/" else next_store});

    try init_mod.switchRoot(init.io, root_dir);

    var stage2_buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
    var stage2_fba: std.heap.FixedBufferAllocator = .init(&stage2_buffer);

    const stage2_init = try init_mod.bringUp(
        init,
        allocator,
        stage2_fba.allocator(),
        &manifest,
        &store,
    );

    if (old_loop_device) |minor| {
        // Ensures the loopback device that is setup during early boot is
        // released from memory, since it is no longer being accessed.
        releaseLoopDevice(init.io, minor);
    }

    const argv_buf = try stage2_fba.allocator().allocSentinel(?[*:0]const u8, 1, null);
    argv_buf[0] = stage2_init;

    const err = system.errno(system.execve(
        argv_buf.ptr[0].?,
        argv_buf.ptr,
        std.process.Environ.empty.block.slice,
    ));
    log.err("execve '{s}' failed: {}", .{ stage2_init, err });
    @panic("PANIC");
}
