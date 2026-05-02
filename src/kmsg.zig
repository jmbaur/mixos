const log = @import("log.zig");
const std = @import("std");

const SYSLOG_FACILITY_USER = 1;

// https://github.com/torvalds/linux/blob/55027e689933ba2e64f3d245fb1ff185b3e7fc81/kernel/printk/internal.h#L38C9-L38C28
// https://github.com/torvalds/linux/blob/55027e689933ba2e64f3d245fb1ff185b3e7fc81/kernel/printk/printk.c#L735
const PRINTKRB_RECORD_MAX = 1024;

var mutex: std.Io.Mutex = .init;
var kmsg: ?std.Io.File = null;
var io_: ?std.Io = null;

var kmsg_buffer: [PRINTKRB_RECORD_MAX]u8 = undefined;

pub fn init(io: std.Io) void {
    // disable kmsg rate limit
    if (std.Io.Dir.cwd().openFile(
        io,
        "/proc/sys/kernel/printk_devkmsg",
        .{ .mode = .write_only },
    )) |printk_devkmsg| {
        defer printk_devkmsg.close(io);
        var buf: [3]u8 = undefined;
        var writer = printk_devkmsg.writer(io, &buf);
        writer.interface.writeAll("on\n") catch {};
        writer.interface.flush() catch {};
    } else |_| {}

    if (std.Io.Dir.cwd().openFile(
        io,
        "/dev/kmsg",
        .{ .mode = .write_only },
    )) |kmsg_file| {
        kmsg = kmsg_file;
    } else |_| {}

    io_ = io;
    log.setLogger(.kmsg);
}

pub fn deinit(io: std.Io) void {
    if (kmsg) |file| {
        file.close(io);
    }
    kmsg = null;
    log.setLogger(.default);
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
    const syslog_prefix = comptime b: {
        var buf: [2]u8 = undefined;
        var fixed_writer: std.Io.Writer = .fixed(&buf);

        // 0 KERN_EMERG
        // 1 KERN_ALERT
        // 2 KERN_CRIT
        // 3 KERN_ERR
        // 4 KERN_WARNING
        // 5 KERN_NOTICE
        // 6 KERN_INFO
        // 7 KERN_DEBUG

        // https://github.com/torvalds/linux/blob/f2661062f16b2de5d7b6a5c42a9a5c96326b8454/Documentation/ABI/testing/dev-kmsg#L1
        const syslog_level: u16 = ((SYSLOG_FACILITY_USER << 3) | switch (level) {
            .err => 3,
            .warn => 4,
            .info => 6,
            .debug => 7,
        });

        fixed_writer.printInt(syslog_level, 10, .lower, .{}) catch @compileError("invalid syslog prefix");
        break :b fixed_writer.buffer;
    };

    const file = kmsg orelse {
        return std.log.defaultLog(
            level,
            scope,
            format,
            args,
        );
    };

    const io = io_ orelse return;

    mutex.lock(io) catch return;
    defer mutex.unlock(io);

    var writer = file.writer(io, &kmsg_buffer);
    writer.interface.print(
        "<" ++ syslog_prefix ++ ">" ++ prefix ++ format ++ "\n",
        args,
    ) catch {};
    writer.flush() catch {};
}
