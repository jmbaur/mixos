const std = @import("std");
const system = std.posix.system;
const fs = @import("./fs.zig");
const kmsg = @import("./kmsg.zig");

const log = std.log.scoped(.mixos);

pub const std_options = kmsg.std_options;

const LOOP_SET_FD = 0x4C00;
const LOOP_CTL_GET_FREE = 0x4C82;

fn find_cmdline(cmdline: []const u8, want_key: []const u8) ?[]const u8 {
    var entry_split = std.mem.tokenizeSequence(u8, cmdline, &std.ascii.whitespace);
    while (entry_split.next()) |entry| {
        var split = std.mem.splitScalar(u8, entry, '=');
        const key = split.next() orelse continue;
        const value = split.next() orelse continue;

        if (std.mem.eql(u8, key, want_key)) {
            return std.mem.trim(u8, value, &std.ascii.whitespace);
        }
    }

    return null;
}

test "find_cmdline" {
    try std.testing.expectEqual(null, find_cmdline("foo", ""));
    try std.testing.expectEqualStrings("1", find_cmdline("foo=1", "foo") orelse unreachable);
    try std.testing.expectEqualStrings("1", find_cmdline("foo=1 \t\n", "foo") orelse unreachable);
}

fn switch_root(allocator: std.mem.Allocator) ![]const u8 {
    try std.fs.cwd().makePath("/dev");
    try std.fs.cwd().makePath("/sys");
    try std.fs.cwd().makePath("/proc");
    try std.fs.cwd().makePath("/sysroot");

    try fs.mount("devtmpfs", "/dev", "devtmpfs", system.MS.NOEXEC | system.MS.NOSUID, 0);
    try fs.mount("sysfs", "/sys", "sysfs", system.MS.NOEXEC | system.MS.NOSUID, 0);
    try fs.mount("proc", "/proc", "proc", system.MS.NOEXEC | system.MS.NOSUID | system.MS.NODEV, 0);

    // We must wait until now to setup the /dev/kmsg logger, since /dev is not
    // mounted until right before this.
    kmsg.init();
    defer kmsg.deinit();

    const cmdline_file = try std.fs.cwd().openFile("/proc/cmdline", .{});
    defer cmdline_file.close();

    const cmdline = std.mem.trimRight(u8, try cmdline_file.readToEndAlloc(allocator, std.math.maxInt(usize)), &std.ascii.whitespace);
    log.debug("using kernel cmdline \"{s}\"", .{cmdline});

    const init = find_cmdline(cmdline, "init") orelse "/init";
    log.debug("using init \"{s}\"", .{init});

    // dupeZ since we will need to pass this to the kernel's mount() syscall
    const rootfstype = try allocator.dupeZ(u8, find_cmdline(cmdline, "rootfstype") orelse "erofs");
    log.debug("using root filesystem type \"{s}\"", .{rootfstype});

    const loop_control = try std.fs.cwd().openFile("/dev/loop-control", .{ .mode = .read_write });
    defer loop_control.close();

    const loop_nr = system.ioctl(loop_control.handle, LOOP_CTL_GET_FREE, 0);
    const loop_nr_err = system.E.init(loop_nr);
    if (loop_nr_err != .SUCCESS) {
        log.err("failed to get next free loopback number: {s}", .{@tagName(loop_nr_err)});
        return std.posix.unexpectedErrno(loop_nr_err);
    }

    const loop_device_path = try std.fmt.allocPrintSentinel(allocator, "/dev/loop{}", .{@as(usize, loop_nr)}, 0);
    log.debug("using loopback device {s}", .{loop_device_path});

    const loop_device = try std.fs.cwd().openFile(loop_device_path, .{ .mode = .read_write });
    defer loop_device.close();

    const backing_file = try std.fs.cwd().openFile("/rootfs", .{});
    defer backing_file.close();

    switch (system.E.init(system.ioctl(loop_device.handle, LOOP_SET_FD, @intCast(backing_file.handle)))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to set backing file on loopback device: {s}", .{@tagName(err)});
            return std.posix.unexpectedErrno(err);
        },
    }

    try fs.mount(loop_device_path, "/sysroot", rootfstype, system.MS.RDONLY | system.MS.NODEV | system.MS.NOSUID, 0);

    var passthru_dir = std.fs.cwd().openDir("/passthru", .{});
    if (passthru_dir) |*dir| {
        dir.close();
        log.debug("passing through contents of /passthru", .{});
        try fs.mount("/passthru", "/sysroot/passthru", "", system.MS.BIND, 0);
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }

    switch (system.E.init(system.chdir("/sysroot"))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to change directory to /sysroot: {s}", .{@tagName(err)});
            return std.posix.unexpectedErrno(err);
        },
    }

    log.debug("removing remnants of initrd rootfs", .{});
    if (std.fs.cwd().realpathAlloc(allocator, "/init")) |init_realpath| {
        std.fs.cwd().deleteFile(init_realpath) catch {};
        if (!std.mem.eql(u8, init_realpath, "/init")) {
            std.fs.deleteFileAbsolute("/init") catch {};
        }
    } else |_| {}

    log.debug("moving pseudofilesystems into final root filesystem", .{});
    try fs.mount("/dev", "/sysroot/dev", "", system.MS.MOVE, 0);
    try fs.mount("/sys", "/sysroot/sys", "", system.MS.MOVE, 0);
    try fs.mount("/proc", "/sysroot/proc", "", system.MS.MOVE, 0);
    try fs.mount(".", "/", "", system.MS.MOVE, 0);

    log.debug("chrooting into final root filesystem", .{});
    switch (system.E.init(system.chroot("."))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to chroot: {s}", .{@tagName(err)});
            return std.posix.unexpectedErrno(err);
        },
    }

    log.debug("executing init of final root filesystem", .{});

    return init;
}

pub fn main() noreturn {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const init = switch_root(allocator) catch |err| {
        std.debug.panic("initrd failed: {}", .{err});
    };

    if (!arena.reset(.retain_capacity)) {
        log.warn("failed to reset arena", .{});
    }

    const err = std.process.execv(allocator, &.{init});
    std.debug.panic("execv /init failed: {}", .{err});
}
