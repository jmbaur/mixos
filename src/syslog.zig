const std = @import("std");
const C = @cImport({
    @cInclude("syslog.h");
});

var log_buffer = std.mem.zeroes([1024]u8);

pub fn init(name: [*c]const u8) void {
    C.openlog(name, 0, C.LOG_USER);
}

pub fn deinit() void {
    C.closelog();
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

    C.syslog(switch (message_level) {
        .debug => C.LOG_DEBUG,
        .err => C.LOG_ERR,
        .info => C.LOG_INFO,
        .warn => C.LOG_WARNING,
    }, @as([*c]const u8, @ptrCast(log_writer.buffer[0..log_writer.end])));

    // Resets `end`
    _ = log_writer.consumeAll();

    @memset(log_writer.buffer, 0);
}
