const std = @import("std");
const posix = std.posix;

const C = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("sys/socket.h");
    @cInclude("linux/vm_sockets.h");
});

pub const VMADDR_CID_HOST = C.VMADDR_CID_HOST;

pub const Address = struct {
    cid: u32,
    port: u16,

    pub const ListenOptions = struct {
        reuse_addr: bool = true,
    };

    pub fn listen(self: *const @This(), opts: ListenOptions) !std.Io.net.Socket.Handle {
        const socket_fd = while (true) {
            const rc = posix.system.socket(posix.AF.VSOCK, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    const fd: posix.fd_t = @intCast(rc);
                    break fd;
                },
                .INTR => continue,
                .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                .INVAL => return error.ProtocolUnsupportedBySystem,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
                .PROTOTYPE => return error.SocketModeUnsupported,
                else => |err| return posix.unexpectedErrno(err),
            }
        };

        if (opts.reuse_addr) {
            try posix.setsockopt(
                socket_fd,
                posix.SOL.SOCKET,
                posix.SO.REUSEADDR,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        }

        switch (posix.system.errno(posix.system.bind(
            socket_fd,
            @ptrCast(&posix.sockaddr.vm{
                .cid = self.cid,
                .port = @as(u32, self.port),
                .flags = 0,
            }),
            @sizeOf(posix.sockaddr.vm),
        ))) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }

        while (true) {
            switch (posix.errno(posix.system.listen(socket_fd, std.Io.net.default_kernel_backlog))) {
                .SUCCESS => break,
                .INTR => continue,
                .NOBUFS => return error.SystemResources,
                else => |err| return posix.unexpectedErrno(err),
            }
        }

        return socket_fd;
    }
};

pub fn currentCid(io: std.Io) !u32 {
    var dev_vsock = try std.Io.Dir.cwd().openFile(io, "/dev/vsock", .{});
    defer dev_vsock.close(io);

    var cid: u32 = undefined;
    switch (posix.system.errno(posix.system.ioctl(dev_vsock.handle, C.IOCTL_VM_SOCKETS_GET_LOCAL_CID, @intFromPtr(&cid)))) {
        .SUCCESS => return cid,
        else => return error.UnknownLocalCid,
    }
}
