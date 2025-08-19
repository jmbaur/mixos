const std = @import("std");

const ClientMessage = struct {
    command: []const []const u8,
};

const ServerMessage = union(enum) {
    err: []const u8,
    res: std.process.Child.RunResult,
};

fn handleConnection(allocator: std.mem.Allocator, conn: *std.net.Server.Connection) !void {
    const raw_message = try conn.stream.reader().readUntilDelimiterAlloc(allocator, 0, std.math.maxInt(usize));

    const message = try std.json.parseFromSlice(ClientMessage, allocator, raw_message, .{});

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = message.value.command,
    });

    if (result) |run_result| {
        const response = try std.json.stringifyAlloc(allocator, ServerMessage{
            .res = run_result,
        }, .{});
        try conn.stream.writeAll(response);
    } else |err| {
        const response = try std.json.stringifyAlloc(allocator, ServerMessage{
            .err = try std.fmt.allocPrint(allocator, "{}", .{err}),
        }, .{});
        try conn.stream.writeAll(response);
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const addr = try std.net.Address.parseIp("::", 8000);
    std.log.info("mixos test backdoor server listening on {}", .{addr});

    var server = try addr.listen(.{});

    while (true) {
        defer {
            _ = arena.reset(.retain_capacity);
        }

        var conn = try server.accept();
        defer conn.stream.close();

        std.log.debug("new connection from {}", .{conn.address});

        handleConnection(arena.allocator(), &conn) catch |err| {
            std.log.err("connection handling failed: {}", .{err});
        };
    }
}
