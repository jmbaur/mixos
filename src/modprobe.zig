const std = @import("std");
const Kmod = @import("./kmod.zig");

const log = std.log.scoped(.mixos);

pub fn main(args: *std.process.ArgIterator) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var kmod = try Kmod.init(allocator);
    defer kmod.deinit();

    while (args.next()) |arg| {
        kmod.modprobe(arg) catch |err| {
            log.err("module load for '{s}' failed: {}", .{ arg, err });
        };
    }
}
