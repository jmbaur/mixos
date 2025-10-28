const std = @import("std");

const SYSLOG_FACILITY_USER = 1;

// https://github.com/torvalds/linux/blob/55027e689933ba2e64f3d245fb1ff185b3e7fc81/kernel/printk/internal.h#L38C9-L38C28
// https://github.com/torvalds/linux/blob/55027e689933ba2e64f3d245fb1ff185b3e7fc81/kernel/printk/printk.c#L735
const PRINTKRB_RECORD_MAX = 1024;

var mutex: std.Thread.Mutex = .{};
var kmsg: ?std.fs.File = null;

// The Zig string formatter can make many individual writes to our
// writer depending on the format string, so we do all the formatting
// ahead of time here so we can perform the write all at once when the
// log line goes to the kernel.
var log_buf: [PRINTKRB_RECORD_MAX]u8 = undefined;
var stream = std.io.fixedBufferStream(&log_buf);

pub fn init() @This() {
    // disable kmsg rate limit
    if (std.fs.cwd().openFile(
        "/proc/sys/kernel/printk_devkmsg",
        .{ .mode = .write_only },
    )) |printk_devkmsg| {
        defer printk_devkmsg.close();
        printk_devkmsg.writeAll("on\n") catch {};
    } else |_| {}

    if (std.fs.cwd().openFile("/dev/kmsg", .{ .mode = .write_only })) |kmsg_file| {
        kmsg = kmsg_file;
    } else |_| {}

    return .{};
}

pub fn deinit(self: *@This()) void {
    _ = self;

    if (kmsg) |file| {
        file.close();
    }
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
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

    const file = kmsg orelse return;

    mutex.lock();
    defer mutex.unlock();

    const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";

    stream.writer().print(
        "<" ++ syslog_prefix ++ ">" ++ prefix ++ format ++ "\n",
        args,
    ) catch {};

    file.writeAll(stream.getWritten()) catch {};

    stream.reset();
}

pub const std_options: std.Options = .{
    // We write to /dev/kmsg, so we let the kernel do the log filtering for us.
    .log_level = .debug,
    .logFn = logFn,
};
