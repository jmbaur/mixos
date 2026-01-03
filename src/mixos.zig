const std = @import("std");
const kmsg = @import("./kmsg.zig");
const sysinit = @import("./sysinit.zig");
const syslog = @import("./syslog.zig");
const test_backdoor = @import("./test-backdoor.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

var logger: enum { kmsg, syslog, default } = .default;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    return switch (logger) {
        .kmsg => kmsg.logFn(level, scope, format, args),
        .syslog => syslog.logFn(level, scope, format, args),
        .default => std.log.defaultLog(level, scope, format, args),
    };
}

pub fn main() !void {
    var args = std.process.args();
    const argv0 = args.next() orelse std.debug.panic("missing argv[0]", .{});

    var name = std.fs.path.basename(argv0);

    var i: usize = 0;
    while (i < 2) : (i += 1) {
        if (i == 0 and std.mem.eql(u8, name, "mixos")) {
            name = args.next() orelse return error.MissingCommand;
            continue;
        } else if (std.mem.eql(u8, name, "sysinit")) {
            // We log to /dev/kmsg in sysinit since at this point in time syslogd is
            // not yet started. The klogd process will pick up our userspace logs sent
            // to the kernel and forward them to syslog.
            kmsg.init();
            defer kmsg.deinit();
            logger = .kmsg;

            return sysinit.mixosMain(&args);
        } else if (std.mem.eql(u8, name, "test-backdoor")) {
            if (!std.posix.isatty(std.fs.File.stdin().handle)) {
                syslog.init("mixos-test-backdoor");
                defer syslog.deinit();
                logger = .syslog;
            }

            return test_backdoor.mixosMain(&args);
        } else {
            break;
        }
    }

    return error.UnknownCommand;
}
