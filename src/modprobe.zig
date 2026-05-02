const std = @import("std");
const syslog = @import("syslog.zig");
const Kmod = @import("kmod.zig");

const log = std.log.scoped(.mixos);

pub fn main(init: std.process.Init, name: []const u8, args: *std.process.Args.Iterator) anyerror!void {
    syslog.init(name);
    defer syslog.deinit();

    const allocator = init.arena.allocator();

    var kmod = try Kmod.init(allocator);
    defer kmod.deinit();

    while (args.next()) |arg| {
        // Ignore flags passed by kernel
        // https://github.com/torvalds/linux/blob/4ae12d8bd9a830799db335ee661d6cbc6597f838/kernel/module/kmod.c#L92
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--")) {
            continue;
        }

        kmod.modprobe(arg) catch |err| {
            log.err("module load for '{s}' failed: {}", .{ arg, err });
        };
    }
}
