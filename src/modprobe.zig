const std = @import("std");
const Kmod = @import("./kmod.zig");

pub fn main(args: *std.process.ArgIterator) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var kmod = try Kmod.init(allocator);
    defer kmod.deinit();

    while (args.next()) |arg| {
        try kmod.modprobe(arg);
    }
}
