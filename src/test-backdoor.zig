const std = @import("std");

const std_options: std.Options = .{ .log_level = .debug };

const ClientMessage = struct {
    command: []const []const u8,
};

const ServerMessage = struct {
    response: union(enum) {
        success: std.process.Child.RunResult,
        failure: []const u8,
    },
};

fn handleConnection(allocator: std.mem.Allocator, conn: *std.net.Server.Connection) !void {
    const raw_message = try conn.stream.reader().readUntilDelimiterAlloc(allocator, 0, std.math.maxInt(usize));

    const message = try std.json.parseFromSlice(ClientMessage, allocator, raw_message, .{});

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = message.value.command,
    });

    const out = if (result) |run_result| try std.json.stringifyAlloc(
        allocator,
        ServerMessage{ .response = .{ .success = run_result } },
        .{},
    ) else |err| try std.json.stringifyAlloc(
        allocator,
        ServerMessage{ .response = .{ .failure = try std.fmt.allocPrint(allocator, "{}", .{err}) } },
        .{},
    );

    var buffered_writer = std.io.bufferedWriter(conn.stream.writer());
    try buffered_writer.writer().writeAll(out);
    try buffered_writer.flush();
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
