const std = @import("std");

const std_options: std.Options = .{ .log_level = .debug };

const Command = enum {
    run_command,
};

const ClientMessage = union(Command) {
    run_command: ClientCommandMessage,
};

const ClientCommandMessage = struct {
    command: []const []const u8,
};

const RunResult = struct {
    exit_code: u32,
    stdout: []u8,
    stderr: []u8,
};

const ServerMessage = union(enum) {
    @"error": anyerror,
    result: union(Command) {
        run_command: RunResult,
    },
};

fn runCommand(allocator: std.mem.Allocator, conn: *std.net.Server.Connection, args: ClientCommandMessage) anyerror!void {
    const run_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.command,
    });

    const out = try std.json.stringifyAlloc(
        allocator,
        ServerMessage{ .result = .{ .run_command = .{
            .exit_code = switch (run_result.term) {
                .Exited => |exited| @as(u32, exited),
                .Signal => |signal| signal,
                .Stopped => |stopped| stopped,
                .Unknown => |unknown| unknown,
            },
            .stderr = run_result.stderr,
            .stdout = run_result.stdout,
        } } },
        .{},
    );

    try conn.stream.writeAll(out);
}

fn handleConnection(allocator: std.mem.Allocator, conn: *std.net.Server.Connection) !void {
    while (true) {
        const raw_message = conn.stream.reader().readUntilDelimiterAlloc(allocator, 0, std.math.maxInt(usize)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        const message = std.json.parseFromSlice(ClientMessage, allocator, raw_message, .{}) catch |err| {
            const out = try std.json.stringifyAlloc(allocator, ServerMessage{
                .@"error" = err,
            }, .{});
            try conn.stream.writeAll(out);
            return;
        };

        const res = switch (message.value) {
            .run_command => runCommand(allocator, conn, message.value.run_command),
        };

        res catch |err| {
            const out = try std.json.stringifyAlloc(allocator, ServerMessage{
                .@"error" = err,
            }, .{});
            try conn.stream.writeAll(out);
        };
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var args = std.process.args();
    _ = args.next() orelse std.debug.panic("missing argv[0]", .{});
    const port = if (args.next()) |arg| try std.fmt.parseInt(u16, arg, 10) else 8000;

    const addr = try std.net.Address.parseIp("::", port);

    var server = try addr.listen(.{});

    std.log.info("mixos test backdoor server listening on {}", .{addr});

    while (true) {
        defer {
            _ = arena.reset(.retain_capacity);
        }

        var conn = try server.accept();
        defer conn.stream.close();

        std.log.debug("connection started with {}", .{conn.address});

        handleConnection(arena.allocator(), &conn) catch |err| {
            std.log.err("connection handling failed: {}", .{err});
        };

        std.log.debug("connection ended with {}", .{conn.address});
    }
}
