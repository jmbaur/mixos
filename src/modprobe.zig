const std = @import("std");
const syslog = @import("syslog.zig");
const Kmod = @import("kmod.zig");

const log = std.log.scoped(.mixos);

pub fn main(init: std.process.Init, name: []const u8, args: *std.process.Args.Iterator) anyerror!void {
    var initrd_modules_queue: std.Io.Writer.Allocating = .init(init.arena.allocator());

    syslog.init(name);
    defer syslog.deinit();

    const in_initrd = if (std.Io.Dir.cwd().access(
        init.io,
        "/initrd_loaded_modules",
        .{},
    )) true else |_| b: {
        break :b false;
    };

    var kmod = try Kmod.init(.{});
    defer kmod.deinit();

    while (args.next()) |arg| {
        // Ignore flags passed by kernel
        // https://github.com/torvalds/linux/blob/4ae12d8bd9a830799db335ee661d6cbc6597f838/kernel/module/kmod.c#L92
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--")) {
            continue;
        }

        if (in_initrd) {
            try initrd_modules_queue.writer.print("{s}\n", .{arg});
        } else {
            kmod.modprobe(arg) catch |err| {
                log.err("module load for '{s}' failed: {}", .{ arg, err });
            };
        }
    }

    if (in_initrd) {
        var file = try std.Io.Dir.cwd().openFile(
            init.io,
            "/initrd_loaded_modules",
            .{},
        );
        defer file.close(init.io);

        var writer = file.writer(init.io, &.{});
        try writer.interface.writeAll(initrd_modules_queue.written());
        try writer.interface.flush();
    }
}
