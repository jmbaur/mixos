const mixos_varlink = @import("mixos_varlink");
const posix = std.posix;
const process = @import("process.zig");
const std = @import("std");
const syslog = @import("syslog.zig");
const system = std.os.linux;
const varlink = @import("varlink");
const C = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("sys/socket.h");
    @cInclude("linux/vm_sockets.h");
});

const log = std.log.scoped(.mixos);

const Context = struct {
    pub const vendor = "jmbaur";
    pub const product = "mixos";
    pub const version = "1.1.1";
    pub const url = "http://mixos.jmbaur.com";
    @"com.jmbaur.mixos": struct {
        pub const interface = mixos_varlink;

        pub fn handleReboot(
            context: *@This(),
            parameters: mixos_varlink.Reboot.Parameters,
            request_context: anytype,
        ) !void {
            _ = context;

            const ready = if (parameters.reboot_type == .kexec) b: {
                const kexec_loaded = std.fs.cwd().openFile("/sys/kernel/kexec_loaded", .{}) catch break :b false;
                defer kexec_loaded.close();
                var buf = [_]u8{0};
                _ = kexec_loaded.read(&buf) catch break :b false;
                break :b buf[0] == '1';
            } else true;

            if (!ready) {
                return try request_context.serializeError(mixos_varlink.RebootNotReady{});
            }

            try request_context.serializeResponse(.{});

            switch (parameters.reboot_type) {
                .kexec => {
                    posix.reboot(.KEXEC) catch |err| {
                        log.err("failed to kexec: {}", .{err});
                    };
                },
                .reboot => {
                    posix.kill(1, posix.SIG.TERM) catch |err| {
                        log.err("failed to reboot: {}", .{err});
                    };
                },
                .poweroff => {
                    posix.kill(1, posix.SIG.USR2) catch |err| {
                        log.err("failed to poweroff: {}", .{err});
                    };
                },
            }
        }

        pub fn handleRunCommand(
            context: *@This(),
            parameters: mixos_varlink.RunCommand.Parameters,
            request_context: anytype,
        ) !void {
            _ = context;

            if (parameters.command.len == 0) {
                return try request_context.serializeError(mixos_varlink.CommandFailed{});
            }

            const arena: std.mem.Allocator = request_context.getData();
            var stdout: std.Io.Writer.Allocating = .init(arena);
            defer stdout.deinit();

            var stderr: std.Io.Writer.Allocating = .init(arena);
            defer stderr.deinit();

            const term = process.run(arena, parameters.command, .{
                .stdout_writer = &stdout.writer,
                .stderr_writer = &stderr.writer,
                .timeout = parameters.timeout,
            }) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied => return try request_context.serializeError(mixos_varlink.CommandFailed{}),
                error.Timeout => return try request_context.serializeError(mixos_varlink.Timeout{}),
                else => return err,
            };

            log.debug("process ended with term {}", .{term});

            try request_context.serializeResponse(.{
                .exit_code = switch (term) {
                    .Exited => |exited| @as(u32, exited),
                    .Signal => |signal| signal,
                    .Stopped => |stopped| stopped,
                    .Unknown => |unknown| unknown,
                },
                .stdout = stdout.written(),
                .stderr = stderr.written(),
            });
        }
    } = .{},
};

const Connection = varlink.server.Connection(
    Context,
    std.mem.Allocator,
);

fn handleRequest(
    arena: std.mem.Allocator,
    connection: *Connection,
    reader: anytype,
    context: *Context,
) !void {
    const request = try readMessage(reader);
    try connection.handleRequest(
        request,
        arena,
        context,
    );
}

fn readMessage(reader: *std.Io.Reader) ![]u8 {
    const res = try reader.takeDelimiterExclusive(0);
    reader.toss(1);
    return res;
}

fn handleConnection(arena: std.mem.Allocator, stream: *std.net.Stream) !void {
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(&read_buffer);
    var context: Context = .{};

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(&write_buffer);
    var varlink_connection: Connection = .{
        .response_writer = &writer.interface,
        .data = arena,
    };

    while (true) {
        handleRequest(
            arena,
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
    if (0 != system.ioctl(vsock.handle, C.IOCTL_VM_SOCKETS_GET_LOCAL_CID, @intFromPtr(&cid))) {
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
                log.warn("failed to parse mixos.test_backdoor= kernel param: {}", .{err});
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
            log.warn("failed to obtain current vsock CID: {}", .{err});
        }
    } else |_| {}

    return .{ .address = comptime std.net.Address.parseIp6(
        "::",
        default_port,
    ) catch @compileError("invalid IPv6 address") };
}

pub fn main(name: []const u8, args: *std.process.ArgIterator) anyerror!void {
    syslog.init(name);
    defer syslog.deinit();

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

    log.info("server listening on {f}", .{listen_param});

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

        log.debug("connection started", .{});
        handleConnection(arena.allocator(), &stream) catch |err| {
            log.err("connection handling failed: {}", .{err});
        };
        log.debug("connection ended", .{});
    }
}
