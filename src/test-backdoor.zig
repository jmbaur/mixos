const std = @import("std");
const posix = std.posix;
const C = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("sys/socket.h");
    @cInclude("linux/vm_sockets.h");
});

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

fn handleConnection(allocator: std.mem.Allocator, stream: *std.net.Stream) !void {
    var read_buf = [_]u8{0} ** 4096;
    var write_buf = [_]u8{0} ** 4096;

    var stream_writer = stream.writer(&write_buf);

    while (true) {
        defer stream_writer.interface.flush() catch {};

        var message_writer = std.Io.Writer.Allocating.init(allocator);
        defer message_writer.deinit();

        var stream_reader = stream.reader(&read_buf);
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
                &stream_writer.interface,
            );
            return;
        };

        const res = switch (message.value) {
            .run_command => runCommand(allocator, &stream_writer.interface, message.value.run_command),
        };

        res catch |err| {
            try std.json.Stringify.value(ServerMessage{ .@"error" = err }, .{}, &stream_writer.interface);
        };

        try stream_writer.interface.writeByte(0);
    }
}

fn currentCid() !u32 {
    var vsock = try std.fs.cwd().openFile("/dev/vsock", .{});
    defer vsock.close();

    var cid: u32 = undefined;
    if (0 != posix.system.ioctl(vsock.handle, C.IOCTL_VM_SOCKETS_GET_LOCAL_CID, &cid)) {
        return error.UnknownLocalCid;
    }
    return cid;
}

const Protocol = union(enum) { inet, vsock: u32 };

const ListenParam = struct {
    protocol: Protocol,
    port: u16,

    pub fn format(self: @This(), writer: *std.io.Writer) std.io.Writer.Error!void {
        switch (self.protocol) {
            .inet => try writer.print("inet6://[::]:{}", .{self.port}),
            .vsock => |cid| try writer.print("vsock://{}:{}", .{ cid, self.port }),
        }
    }
};

fn parseListenArgs(arg: []const u8) !ListenParam {
    var split = std.mem.splitScalar(u8, arg, ':');

    const proto_str = split.next() orelse return error.MissingProtocol;

    const protocol: Protocol = b: {
        if (std.mem.eql(u8, proto_str, "inet")) {
            break :b .inet;
        } else if (std.mem.eql(u8, proto_str, "vsock")) {
            break :b .{ .vsock = try currentCid() };
        } else {
            return error.InvalidProtocol;
        }
    };

    const port = split.next() orelse return error.MissingPort;

    return .{
        .protocol = protocol,
        .port = try std.fmt.parseInt(u16, port, 10),
    };
}

fn parseKernelCmdline() !?ListenParam {
    var buf: [1024]u8 = undefined;

    var cmdline = try std.fs.cwd().openFile("/proc/cmdline", .{});
    defer cmdline.close();

    var cmdline_reader = cmdline.reader(&buf);

    while (try cmdline_reader.interface.takeDelimiter(' ')) |entry| {
        var entry_split = std.mem.splitScalar(u8, entry, '=');

        if (std.mem.eql(u8, entry_split.next() orelse continue, "mixos.test_backdoor")) {
            return parseListenArgs(entry_split.next() orelse continue) catch |err| {
                std.log.warn("failed to parse mixos.test_backdoor= kernel param: {}", .{err});
                continue;
            };
        }
    }

    return null;
}

fn detectDefaultProtocol() !Protocol {
    if (std.fs.cwd().access("/dev/vsock", .{})) {
        return .{ .vsock = try currentCid() };
    } else |_| {
        return .inet;
    }
}

pub fn main(args: *std.process.ArgIterator) !void {
    var listen_param: ListenParam = .{
        .port = 8000,
        .protocol = try detectDefaultProtocol(),
    };

    if (try parseKernelCmdline()) |param| {
        listen_param = param;
    }

    if (args.next()) |arg| {
        listen_param = try parseListenArgs(arg);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const sockfd = try posix.socket(
        switch (listen_param.protocol) {
            .vsock => posix.AF.VSOCK,
            .inet => posix.AF.INET6,
        },
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        switch (listen_param.protocol) {
            .vsock => 0,
            .inet => posix.IPPROTO.IP,
        },
    );
    defer posix.close(sockfd);

    try posix.setsockopt(
        sockfd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    if (listen_param.protocol == .inet and @hasDecl(posix.SO, "REUSEPORT")) {
        try posix.setsockopt(
            sockfd,
            posix.SOL.SOCKET,
            posix.SO.REUSEPORT,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    }

    switch (listen_param.protocol) {
        .vsock => |cid| {
            try std.posix.bind(sockfd, @ptrCast(&std.posix.sockaddr.vm{
                .cid = cid,
                .port = @as(u32, listen_param.port),
                .flags = 0,
            }), @sizeOf(std.posix.sockaddr.vm));
        },
        .inet => {
            try std.posix.bind(sockfd, @ptrCast(&std.posix.sockaddr.in6{
                .addr = [_]u8{0} ** 16, // TODO(jared): support custom bind address
                .port = std.mem.nativeToBig(u16, listen_param.port),
                .flowinfo = 0,
                .scope_id = 0,
            }), @sizeOf(std.posix.sockaddr.in6));
        },
    }

    try std.posix.listen(sockfd, 1);

    std.log.info("server listening on {f}", .{listen_param});

    while (true) {
        defer {
            _ = arena.reset(.retain_capacity);
        }

        var client_addr: std.posix.sockaddr = undefined;
        var addr_size: std.posix.socklen_t = @sizeOf(@TypeOf(client_addr));
        var stream: std.net.Stream = .{ .handle = try std.posix.accept(
            sockfd,
            @ptrCast(&client_addr),
            &addr_size,
            std.posix.SOCK.CLOEXEC,
        ) };
        defer stream.close();

        std.log.debug("connection started", .{});
        handleConnection(arena.allocator(), &stream) catch |err| {
            std.log.err("connection handling failed: {}", .{err});
        };
        std.log.debug("connection ended", .{});
    }
}
