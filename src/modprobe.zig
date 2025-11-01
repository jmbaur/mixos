const std = @import("std");
const Kmod = @import("./kmod.zig");

/// Returns a tuple of the module name and the parameters to load the module
/// with. Caller is responsible for freeing the params buffer.
fn parseArgs(allocator: std.mem.Allocator, args: anytype) !std.meta.Tuple(&.{ []const u8, []const u8 }) {
    var maybe_module_query: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            continue;
        } else {
            maybe_module_query = arg;
            break;
        }
    }

    const module_query = maybe_module_query orelse return error.NoModuleSpecified;

    var params: std.Io.Writer.Allocating = .init(allocator);
    errdefer params.deinit();

    while (args.next()) |param| {
        try params.writer.writeAll(param);
        try params.writer.writeByte(' ');
    }

    // remove potentially trailing whitespace
    params.writer.end -|= 1;

    return .{ module_query, try params.toOwnedSlice() };
}

test "parseArgs" {
    // Test passing args the same as linux (https://github.com/torvalds/linux/blob/ec0b62ccc986c06552c57f54116171cfd186ef92/kernel/module/kmod.c#L91).
    {
        const kernel_modprobe_example_args = "-q -- nvme";
        var args = try std.process.ArgIteratorGeneral(.{}).init(std.testing.allocator, kernel_modprobe_example_args);
        defer args.deinit();

        const module_query, const params = try parseArgs(std.testing.allocator, &args);
        defer std.testing.allocator.free(params);

        try std.testing.expectEqualStrings("nvme", module_query);
        try std.testing.expectEqualStrings("", params);
    }

    {
        var args = try std.process.ArgIteratorGeneral(.{}).init(std.testing.allocator, "foo bar=1 baz");
        defer args.deinit();

        const module_query, const params = try parseArgs(std.testing.allocator, &args);
        defer std.testing.allocator.free(params);

        try std.testing.expectEqualStrings("foo", module_query);
        try std.testing.expectEqualStrings("bar=1 baz", params);
    }
}

pub fn mixosMain(args: *std.process.ArgIterator) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const module_query, const params = try parseArgs(allocator, args);
    defer allocator.free(params);

    var kmod = try Kmod.init(allocator);
    defer kmod.deinit();

    try kmod.modprobe(module_query, if (params.len > 0) params else null);
}
