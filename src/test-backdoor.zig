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

fn runCommand(allocator: std.mem.Allocator, writer: *std.Io.Writer, args: ClientCommandMessage) anyerror!void {
    const run_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args.command,
        .max_output_bytes = std.math.maxInt(usize),
    });

    try std.json.Stringify.value(
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
        .{ .emit_strings_as_arrays = true },
        writer,
    );
}

fn handleConnection(allocator: std.mem.Allocator, conn: *std.net.Server.Connection) !void {
    var read_buf = [_]u8{0} ** 4096;
    var write_buf = [_]u8{0} ** 4096;

    var message_writer = std.Io.Writer.Allocating.init(allocator);
    var stream = conn.stream.writer(&write_buf);
    var stream_writer = &stream.interface;

    while (true) {
        var stream_reader = conn.stream.reader(&read_buf);
        var reader: *std.Io.Reader = stream_reader.interface();
        while (true) {
            const end = try reader.streamDelimiterEnding(&message_writer.writer, 0);
            if (reader.bufferedLen() == 0) {
                return;
            }
            if (end == 0) {
                break;
            }
        }

        const message = std.json.parseFromSlice(ClientMessage, allocator, message_writer.written(), .{}) catch |err| {
            try std.json.Stringify.value(
                ServerMessage{ .@"error" = err },
                .{},
                stream_writer,
            );
            return;
        };

        const res = switch (message.value) {
            .run_command => runCommand(allocator, stream_writer, message.value.run_command),
        };

        res catch |err| {
            try std.json.Stringify.value(ServerMessage{ .@"error" = err }, .{}, stream_writer);
        };

        try stream_writer.writeByte(0);
        try stream_writer.flush();
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

    std.log.info("mixos test backdoor server listening on {f}", .{addr});

    while (true) {
        defer {
            _ = arena.reset(.retain_capacity);
        }

        var conn = try server.accept();
        defer conn.stream.close();

        std.log.debug("connection started with {f}", .{conn.address});

        handleConnection(arena.allocator(), &conn) catch |err| {
            std.log.err("connection handling failed: {}", .{err});
        };

        std.log.debug("connection ended with {f}", .{conn.address});
    }
}
