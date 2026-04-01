const std = @import("std");
const varlink = @import("varlink");
const mixos_varlink = @import("mixos_varlink");
const posix = std.posix;
const C = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("sys/socket.h");
    @cInclude("linux/vm_sockets.h");
});

const Context = struct {
    pub const vendor = "jmbaur";
    pub const product = "mixos";
    pub const version = "1.0.2";
    pub const url = "http://mixos.jmbaur.com";
    @"com.jmbaur.mixos": struct {
        pub const interface = mixos_varlink;
        pub fn handleRunCommand(
            context: *@This(),
            parameters: mixos_varlink.RunCommand.Parameters,
            request_context: anytype,
        ) !void {
            _ = context;

            if (parameters.command.len == 0) {
                try request_context.serializeError(mixos_varlink.MissingCommand{});
                return;
            }

            const run_result = try std.process.Child.run(.{
                .allocator = request_context.getData(),
                .argv = parameters.command,
                .max_output_bytes = std.math.maxInt(usize),
            });

            try request_context.serializeResponse(.{
                .exit_code = switch (run_result.term) {
                    .Exited => |exited| @as(u32, exited),
                    .Signal => |signal| signal,
                    .Stopped => |stopped| stopped,
                    .Unknown => |unknown| unknown,
                },
                .stderr = run_result.stderr,
                .stdout = run_result.stdout,
            });
        }
    } = .{},
};

const Connection = varlink.server.Connection(
    Context,
    std.mem.Allocator,
);

fn handleRequest(
    allocator: std.mem.Allocator,
    connection: *Connection,
    reader: anytype,
    context: *Context,
) !void {
    const request = try readMessage(reader);
    try connection.handleRequest(
        request,
        allocator,
        context,
    );
}

fn readMessage(reader: *std.Io.Reader) ![]u8 {
    const res = try reader.takeDelimiterExclusive(0);
    reader.toss(1);
    return res;
}

fn handleConnection(allocator: std.mem.Allocator, stream: *std.net.Stream) !void {
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(&read_buffer);
    var context: Context = .{};

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(&write_buffer);
    var varlink_connection: Connection = .{
        .response_writer = &writer.interface,
        .data = allocator,
    };

    while (true) {
        handleRequest(
            allocator,
            &varlink_connection,
            reader.interface(),
            &context,
        ) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try writer.interface.flush();
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

const ListenParam = union(enum) {
    address: std.net.Address,
    vsock: struct { cid: u32, port: u16 },

    pub fn format(self: @This(), writer: *std.io.Writer) std.io.Writer.Error!void {
        switch (self) {
            .address => |address| try writer.print("{f}", .{address}),
            .vsock => |vsock| try writer.print("vsock:{}:{}", .{ vsock.cid, vsock.port }),
        }
    }

    /// Supports most of the same strings as systemd.socket's ListenStream=.
    pub fn parse(arg: []const u8) !ListenParam {
        if (std.mem.startsWith(u8, arg, "vsock:")) {
            const vsock_arg = std.mem.trimStart(u8, arg, "vsock:");
            var split = std.mem.splitScalar(u8, vsock_arg, ':');
            const cid_arg = split.next() orelse return error.MissingCID;
            const port_arg = split.next() orelse return error.MissingPort;
            const cid = try std.fmt.parseInt(u32, cid_arg, 10);
            const port = try std.fmt.parseInt(u16, port_arg, 10);
            return .{ .vsock = .{ .cid = cid, .port = port } };
        } else if (std.mem.startsWith(u8, arg, std.fs.path.sep_str)) {
            return .{ .address = try std.net.Address.initUnix(arg) };
        } else {
            const address = try std.net.Address.parseIpAndPort(arg);
            return .{ .address = address };
        }
    }
};

fn parseKernelCmdline() !?ListenParam {
    var buf: [1024]u8 = undefined;

    var cmdline = try std.fs.cwd().openFile("/proc/cmdline", .{});
    defer cmdline.close();

    var cmdline_reader = cmdline.reader(&buf);

    while (try cmdline_reader.interface.takeDelimiter(' ')) |entry| {
        var entry_split = std.mem.splitScalar(u8, entry, '=');

        if (std.mem.eql(u8, entry_split.next() orelse continue, "mixos.test_backdoor")) {
            return ListenParam.parse(entry_split.next() orelse continue) catch |err| {
                std.log.warn("failed to parse mixos.test_backdoor= kernel param: {}", .{err});
                continue;
            };
        }
    }

    return null;
}

const default_port = 8000;

fn detectDefaultListenParams() !ListenParam {
    if (std.fs.cwd().access("/dev/vsock", .{})) {
        if (currentCid()) |cid| {
            if (cid > C.VMADDR_CID_HOST) {
                return .{ .vsock = .{ .cid = cid, .port = default_port } };
            }
        } else |err| {
            std.log.warn("failed to obtain current vsock CID: {}", .{err});
        }
    } else |_| {}

    return .{ .address = comptime std.net.Address.parseIp6(
        "::",
        default_port,
    ) catch @compileError("invalid IPv6 address") };
}

pub fn main(args: *std.process.ArgIterator) anyerror!void {
    var listen_param = try detectDefaultListenParams();

    if (try parseKernelCmdline()) |param| {
        listen_param = param;
    }

    if (args.next()) |arg| {
        listen_param = try ListenParam.parse(arg);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const sockfd = try posix.socket(
        switch (listen_param) {
            .vsock => posix.AF.VSOCK,
            .address => |address| address.any.family,
        },
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        switch (listen_param) {
            .vsock => 0,
            .address => |address| if (address.any.family == posix.AF.UNIX) 0 else posix.IPPROTO.TCP,
        },
    );
    defer posix.close(sockfd);

    try posix.setsockopt(
        sockfd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    if (listen_param == .address and listen_param.address.any.family != posix.AF.UNIX and @hasDecl(posix.SO, "REUSEPORT")) {
        try posix.setsockopt(
            sockfd,
            posix.SOL.SOCKET,
            posix.SO.REUSEPORT,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    }

    switch (listen_param) {
        .vsock => |vsock| {
            try std.posix.bind(sockfd, @ptrCast(&std.posix.sockaddr.vm{
                .cid = vsock.cid,
                .port = @as(u32, vsock.port),
                .flags = 0,
            }), @sizeOf(std.posix.sockaddr.vm));
        },
        .address => |address| {
            if (address.any.family == posix.AF.UNIX) {
                try std.fs.cwd().deleteFileZ(
                    address.un.path[0 .. address.un.path.len - 1 :0],
                );
            }
            try std.posix.bind(sockfd, &address.any, address.getOsSockLen());
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
