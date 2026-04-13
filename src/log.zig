const kmsg = @import("kmsg.zig");
const std = @import("std");
const syslog = @import("syslog.zig");

pub const Logger = enum {
    default,
    kmsg,
    syslog,
};

var global_logger: Logger = .default;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    switch (global_logger) {
        .kmsg => kmsg.logFn(level, scope, format, args),
        .syslog => syslog.logFn(level, scope, format, args),
        .default => std.log.defaultLog(level, scope, format, args),
    }
}

pub fn setLogger(logger: Logger) void {
    global_logger = logger;
}
