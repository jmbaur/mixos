const std = @import("std");
const Kmod = @import("./kmod.zig");

pub fn mixosMain(args: *std.process.ArgIterator) !void {
    const module_filepath = args.next() orelse return error.MissingModuleFile;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var has_params = false;
    var params: std.Io.Writer.Allocating = .init(allocator);
    defer params.deinit();

    while (args.next()) |arg| {
        has_params = true;
        try params.writer.writeAll(arg);
        try params.writer.writeByte(' ');
    }

    var kmod = try Kmod.init(allocator);
    defer kmod.deinit();

    if (has_params) {
        params.writer.undo(1); // remove trailing whitespace
        try kmod.insmod(module_filepath, try params.toOwnedSliceSentinel(0));
    } else {
        try kmod.insmod(module_filepath, null);
    }
}
