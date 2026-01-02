const std = @import("std");
const c = @cImport({
    @cInclude("syslog.h");
});

var log_buffer = std.mem.zeroes([1024]u8);

pub fn init(name: [*c]const u8) void {
    c.openlog(name, 0, c.LOG_USER);
}

pub fn deinit() void {
    c.closelog();
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ "): ";

    var log_writer: std.io.Writer = .fixed(&log_buffer);
    log_writer.print(prefix ++ format, args) catch return;
    log_writer.flush() catch return;

    // The call to print() above would fail if we were to overrun our buffer,
    // however we also need to ensure our buffer has a null terminator to play
    // well with syslog(). So we drop logs that are the same length as our
    // buffer.
    if (log_writer.end == log_writer.buffer.len) {
        return;
    }

    c.syslog(switch (message_level) {
        .debug => c.LOG_DEBUG,
        .err => c.LOG_ERR,
        .info => c.LOG_INFO,
        .warn => c.LOG_WARNING,
    }, @as([*c]const u8, @ptrCast(log_writer.buffer[0..log_writer.end])));

    // Resets `end`
    _ = log_writer.consumeAll();

    @memset(log_writer.buffer, 0);
}
