const std = @import("std");
const posix = std.posix;

const mixos_varlink = @import("mixos_varlink");
const varlink = @import("varlink");

const process = @import("process.zig");
const syslog = @import("syslog.zig");
const vsock = @import("vsock.zig");

const log = std.log.scoped(.mixos);

const ConnectionData = struct { allocator: std.mem.Allocator, io: std.Io };
const Connection = varlink.server.Connection(Context, ConnectionData);

const Context = struct {
    pub const vendor = "jmbaur";
    pub const product = "mixos";
    pub const version = "1.3.0";
    pub const url = "http://mixos.jmbaur.com";
    @"com.jmbaur.mixos": struct {
        pub const interface = mixos_varlink;

        pub fn handleReboot(
            context: *@This(),
            parameters: mixos_varlink.Reboot.Parameters,
            request_context: anytype,
        ) !void {
            _ = context;

            const conn_data: ConnectionData = request_context.getData();
            const io = conn_data.io;

            const ready = if (parameters.reboot_type == .kexec) b: {
                const kexec_loaded = std.Io.Dir.cwd().openFile(
                    io,
                    "/sys/kernel/kexec_loaded",
                    .{},
                ) catch break :b false;
                var reader = kexec_loaded.reader(io, &.{});
                const byte = reader.interface.takeByte() catch break :b false;
                break :b byte == '1';
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

            const conn_data: ConnectionData = request_context.getData();
            const allocator = conn_data.allocator;
            const io = conn_data.io;

            var stdout: std.Io.Writer.Allocating = .init(allocator);
            defer stdout.deinit();

            var stderr: std.Io.Writer.Allocating = .init(allocator);
            defer stderr.deinit();

            const term = process.run(io, allocator, parameters.command, .{
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
                    .exited => |exited| @as(u32, exited),
                    .signal => |signal| @intFromEnum(signal),
                    .stopped => |stopped| @intFromEnum(stopped),
                    .unknown => |unknown| unknown,
                },
                .stdout = stdout.written(),
                .stderr = stderr.written(),
            });
        }
    } = .{},
};

const ListenParam = union(enum) {
    vsock: vsock.Address,
    unix: std.Io.net.UnixAddress,
    ip_address: std.Io.net.IpAddress,

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .vsock => |address| try writer.print("device:/dev/vsock:{}:{}", .{ address.cid, address.port }),
            .unix => |address| try writer.print("unix:{s}", .{address.path}),
            .ip_address => |address| try writer.print("tcp:{f}", .{address}),
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
            return .{ .unix = try .init(arg) };
        } else {
            return .{ .ip_address = try .parseLiteral(arg) };
        }
    }
};

fn parseKernelCmdline(io: std.Io) !?ListenParam {
    var buf: [1024]u8 = undefined;

    var cmdline = try std.Io.Dir.cwd().openFile(io, "/proc/cmdline", .{});
    defer cmdline.close(io);

    var cmdline_reader = cmdline.reader(io, &buf);

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

fn detectDefaultListenParams(io: std.Io) !ListenParam {
    if (std.Io.Dir.cwd().access(io, "/dev/vsock", .{})) {
        if (vsock.currentCid(io)) |cid| {
            if (cid > vsock.VMADDR_CID_HOST) {
                return .{ .vsock = .{ .cid = cid, .port = default_port } };
            }
        } else |err| {
            log.warn("failed to obtain current vsock CID: {}", .{err});
        }
    } else |_| {}

    return .{ .ip_address = comptime std.Io.net.IpAddress.parseIp6(
        "::",
        default_port,
    ) catch @compileError("invalid IPv6 address") };
}

fn handleRequest(
    conn_data: ConnectionData,
    connection: *Connection,
    reader: anytype,
    context: *Context,
) !void {
    const request = try readMessage(reader);
    try connection.handleRequest(request, conn_data.allocator, context);
}

fn readMessage(reader: *std.Io.Reader) ![]u8 {
    const res = try reader.takeDelimiterExclusive(0);
    reader.toss(1);
    return res;
}

fn handleConnection(
    io: std.Io,
    gpa: std.mem.Allocator,
    client: std.Io.net.Stream,
) !void {
    defer client.close(io);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const allocator = arena.allocator();

    var read_buffer: [1024]u8 = undefined;
    var reader = client.reader(io, &read_buffer);
    var context: Context = .{};

    var write_buffer: [1024]u8 = undefined;
    var writer = client.writer(io, &write_buffer);
    var varlink_connection: Connection = .{
        .response_writer = &writer.interface,
        .data = .{ .io = io, .allocator = allocator },
    };

    while (true) {
        handleRequest(
            .{ .io = io, .allocator = allocator },
            &varlink_connection,
            &reader.interface,
            &context,
        ) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try writer.interface.flush();
    }
}

pub fn main(
    init: std.process.Init,
    name: []const u8,
    args: *std.process.Args.Iterator,
) anyerror!void {
    syslog.init(name);
    defer syslog.deinit();

    var listen_param = try detectDefaultListenParams(init.io);

    if (try parseKernelCmdline(init.io)) |param| {
        listen_param = param;
    }

    if (args.next()) |arg| {
        listen_param = try ListenParam.parse(arg);
    }

    const garbage_address = comptime std.Io.net.IpAddress.parseIp6("::", 0) catch @panic("invalid IP address"); // unused

    const socket: std.Io.net.Socket = switch (listen_param) {
        .vsock => |address| .{ .handle = try address.listen(.{}), .address = garbage_address },
        .unix => |address| b: {
            std.Io.Dir.cwd().deleteFile(init.io, address.path) catch {};
            break :b .{ .handle = try init.io.vtable.netListenUnix(init.io.userdata, &address, .{}), .address = garbage_address };
        },
        .ip_address => |address| try init.io.vtable.netListenIp(init.io.userdata, &address, .{ .reuse_address = true }),
    };
    var server: std.Io.net.Server = .{ .socket = socket, .options = void{} };
    defer server.deinit(init.io);

    log.info("server listening on {f}", .{listen_param});

    while (true) {
        const stream = try server.accept(init.io);
        _ = init.io.concurrent(handleConnection, .{ init.io, init.gpa, stream }) catch |err| {
            log.err("failed to dispatch task for connection: {}", .{err});
        };
    }
}
