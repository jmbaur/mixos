const std = @import("std");
const system = std.posix.system;
const log = std.log.scoped(.mixos);

pub const std_options: std.Options = .{
    // We write to /dev/kmsg, so we let the kernel do the log filtering for us.
    .log_level = .debug,
    .logFn = kmsgLog,
};

const LOOP_SET_FD = 0x4C00;
const LOOP_CTL_GET_FREE = 0x4C82;

const SYSLOG_FACILITY_USER = 1;

// https://github.com/torvalds/linux/blob/55027e689933ba2e64f3d245fb1ff185b3e7fc81/kernel/printk/internal.h#L38C9-L38C28
// https://github.com/torvalds/linux/blob/55027e689933ba2e64f3d245fb1ff185b3e7fc81/kernel/printk/printk.c#L735
const PRINTKRB_RECORD_MAX = 1024;

var mutex = std.Thread.Mutex{};
var kmsg: ?std.fs.File = null;

// The Zig string formatter can make many individual writes to our
// writer depending on the format string, so we do all the formatting
// ahead of time here so we can perform the write all at once when the
// log line goes to the kernel.
var log_buf: [PRINTKRB_RECORD_MAX]u8 = undefined;
var stream = std.io.fixedBufferStream(&log_buf);

fn kmsgLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const syslog_prefix = comptime b: {
        var buf: [2]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);

        // 0 KERN_EMERG
        // 1 KERN_ALERT
        // 2 KERN_CRIT
        // 3 KERN_ERR
        // 4 KERN_WARNING
        // 5 KERN_NOTICE
        // 6 KERN_INFO
        // 7 KERN_DEBUG

        // https://github.com/torvalds/linux/blob/f2661062f16b2de5d7b6a5c42a9a5c96326b8454/Documentation/ABI/testing/dev-kmsg#L1
        const syslog_level = ((SYSLOG_FACILITY_USER << 3) | switch (level) {
            .err => 3,
            .warn => 4,
            .info => 6,
            .debug => 7,
        });

        std.fmt.formatIntValue(syslog_level, "", .{}, fbs.writer()) catch return;
        break :b fbs.getWritten();
    };

    const file = kmsg orelse return;

    mutex.lock();
    defer mutex.unlock();

    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    stream.writer().print(
        "<" ++ syslog_prefix ++ ">" ++ prefix ++ format,
        args,
    ) catch {};

    file.writeAll(stream.getWritten()) catch {};

    stream.reset();
}

pub fn mount(special: [*:0]const u8, dir: [*:0]const u8, fstype: ?[*:0]const u8, flags: u32, data: usize) !void {
    switch (system.E.init(system.mount(special, dir, fstype, flags, data))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to mount \"{s}\" on \"{s}\": {s}", .{ special, dir, @tagName(err) });
            return std.posix.unexpectedErrno(err);
        },
    }
}

fn find_cmdline(cmdline: []const u8, want_key: []const u8) ?[]const u8 {
    var entry_split = std.mem.splitSequence(u8, cmdline, &std.ascii.whitespace);
    while (entry_split.next()) |entry| {
        var split = std.mem.splitScalar(u8, entry, '=');
        const key = split.next() orelse continue;
        const value = split.next() orelse continue;

        if (std.mem.eql(u8, key, want_key)) {
            return value;
        }
    }

    return null;
}

fn switch_root(allocator: std.mem.Allocator) ![]const u8 {
    try std.fs.cwd().makePath("/dev");
    try std.fs.cwd().makePath("/sys");
    try std.fs.cwd().makePath("/proc");
    try std.fs.cwd().makePath("/sysroot");

    try mount("devtmpfs", "/dev", "devtmpfs", system.MS.NOEXEC | system.MS.NOSUID, 0);
    try mount("sysfs", "/sys", "sysfs", system.MS.NOEXEC | system.MS.NOSUID, 0);
    try mount("proc", "/proc", "proc", system.MS.NOEXEC | system.MS.NOSUID | system.MS.NODEV, 0);

    // disable kmsg rate limit
    if (std.fs.cwd().openFile(
        "/proc/sys/kernel/printk_devkmsg",
        .{ .mode = .write_only },
    )) |printk_devkmsg| {
        defer printk_devkmsg.close();
        printk_devkmsg.writer().writeAll("on\n") catch {};
    } else |_| {}

    if (std.fs.cwd().openFile("/dev/kmsg", .{ .mode = .write_only })) |file| {
        kmsg = file;
    } else |_| {}
    defer {
        if (kmsg) |file| {
            file.close();
        }
    }

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

    const loop_device_path = try std.fmt.allocPrintZ(allocator, "/dev/loop{}", .{@as(usize, loop_nr)});
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

    try mount(loop_device_path, "/sysroot", rootfstype, system.MS.RDONLY | system.MS.NODEV | system.MS.NOSUID, 0);

    switch (system.E.init(system.chdir("/sysroot"))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to change directory to /sysroot: {s}", .{@tagName(err)});
            return std.posix.unexpectedErrno(err);
        },
    }

    log.debug("removing remnants of initrd rootfs", .{});
    std.fs.deleteFileAbsolute("/init") catch {};

    log.debug("moving pseudofilesystems into final root filesystem", .{});
    try mount("/dev", "/sysroot/dev", "", system.MS.MOVE, 0);
    try mount("/sys", "/sysroot/sys", "", system.MS.MOVE, 0);
    try mount("/proc", "/sysroot/proc", "/proc", system.MS.MOVE, 0);
    try mount(".", "/", "", system.MS.MOVE, 0);

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

    const err = std.process.execv(allocator, &.{init});
    std.debug.panic("execv /init failed: {}", .{err});
}
