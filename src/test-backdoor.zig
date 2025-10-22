const std = @import("std");
const c = @cImport({
    @cInclude("syslog.h");
});

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = logFn };

var log_buffer = [_]u8{0} ** 1024;

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ "): ";

    var log_writer = std.Io.Writer.fixed(&log_buffer);
    log_writer.print(prefix ++ format, args) catch return;
    log_writer.flush() catch return;

    // The call to print() above would fail if we were to overrun our buffer,
    // however we also need to ensure our buffer has a null terminator to play
    // well with syslog(). So we drop logs that are the same length as our
    // buffer.
    if (log_writer.end == log_writer.buffer.len) {
        return;
    }

    c.syslog(switch (message_level) {
        .debug => c.LOG_DEBUG,
        .err => c.LOG_ERR,
        .info => c.LOG_INFO,
        .warn => c.LOG_WARNING,
    }, @as([*c]const u8, @ptrCast(log_writer.buffer[0..log_writer.end])));

    // Resets `end`
    _ = log_writer.consumeAll();

    @memset(log_writer.buffer, 0);
}

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

    var stream = conn.stream.writer(&write_buf);
    var stream_writer = &stream.interface;

    while (true) {
        defer stream_writer.flush() catch {};

        var message_writer = std.Io.Writer.Allocating.init(allocator);
        defer message_writer.deinit();

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
    }
}

pub fn main() !void {
    c.openlog("mixos-test-backdoor", 0, c.LOG_USER);
    defer c.closelog();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var args = std.process.args();
    _ = args.next() orelse std.debug.panic("missing argv[0]", .{});
    const port = if (args.next()) |arg| try std.fmt.parseInt(u16, arg, 10) else 8000;

    const addr = try std.net.Address.parseIp("::", port);

    var server = try addr.listen(.{});

    std.log.info("server listening on {f}", .{addr});

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
