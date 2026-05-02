const std = @import("std");
const log = @import("log.zig");
const C = @cImport({
    @cInclude("syslog.h");
});

/// Larger than the default read buffer of the busybox syslogd implementation, so this should be fine.
/// https://github.com/mirror/busybox/blob/371fe9f71d445d18be28c82a2a6d82115c8af19d/sysklogd/syslogd.c#L76
var log_buffer = std.mem.zeroes([1024]u8);

var logger: std.Io.Writer = .fixed(&log_buffer);

pub fn init(name: []const u8) void {
    var name_buf = std.mem.zeroes([std.fs.max_name_bytes:0]u8);
    std.mem.copyForwards(u8, &name_buf, name);

    C.openlog(std.mem.sliceTo(&name_buf, 0), C.LOG_ODELAY | C.LOG_PERROR, C.LOG_USER);

    log.setLogger(.syslog);
}

pub fn deinit() void {
    C.closelog();
    log.setLogger(.default);
}

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ "): ";

    logger.print(prefix ++ format, args) catch return;
    logger.flush() catch return;

    // The call to print() above would fail if we were to overrun our buffer,
    // however we also need to ensure our buffer has a null terminator to play
    // well with syslog(). So we drop logs that are the same length as our
    // buffer.
    if (logger.end == logger.buffer.len) {
        return;
    }

    C.syslog(switch (message_level) {
        .debug => C.LOG_DEBUG,
        .err => C.LOG_ERR,
        .info => C.LOG_INFO,
        .warn => C.LOG_WARNING,
    }, @as([*c]const u8, @ptrCast(logger.buffer[0..logger.end])));

    // Resets `end`
    _ = logger.consumeAll();

    @memset(logger.buffer, 0);
}
