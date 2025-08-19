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

    try conn.stream.writeAll(out);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var args = std.process.args();
    _ = args.next() orelse std.debug.panic("missing argv[0]", .{});
    const port = if (args.next()) |arg| try std.fmt.parseInt(u16, arg, 10) else 8000;

    const addr = try std.net.Address.parseIp("::", port);
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
