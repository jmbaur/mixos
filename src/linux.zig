const posix = std.posix;
const std = @import("std");
const system = std.os.linux;

const C = @cImport({
    @cInclude("fcntl.h");
    @cInclude("linux/loop.h");
    @cInclude("linux/mount.h");
    @cInclude("linux/watchdog.h");
});

const log = std.log.scoped(.mixos);

pub fn setHostname(hostname: []const u8) !void {
    switch (system.errno(system.syscall2(.sethostname, @intFromPtr(hostname.ptr), hostname.len))) {
        .SUCCESS => return,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const Error = error{
    NoChildProcess,
    FileNotFound,
    FilesystemFdUsed,
    InvalidArguments,
    OutOfMemory,
    PermissionDenied,
    UnsupportedFilesystem,
} || posix.UnexpectedError;

pub fn fsopen(fsname: [*:0]const u8) Error!posix.fd_t {
    const ret = system.syscall2(.fsopen, @intFromPtr(fsname), C.FSOPEN_CLOEXEC);
    switch (system.errno(ret)) {
        .SUCCESS => return @intCast(ret),
        .FAULT, .INVAL => return Error.InvalidArguments,
        .NODEV => return Error.UnsupportedFilesystem,
        .NOMEM => return Error.OutOfMemory,
        .PERM => return Error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn fsconfig(fd: posix.fd_t, cmd: usize, key: ?[*:0]const u8, value: ?[*:0]const u8, aux: usize) Error!void {
    switch (system.errno(system.syscall5(
        .fsconfig,
        @bitCast(@as(isize, fd)),
        cmd,
        @intFromPtr(key),
        @intFromPtr(value),
        aux,
    ))) {
        .SUCCESS => {},
        .ACCES, .FAULT, .INVAL => return Error.InvalidArguments,
        .NODEV => return Error.UnsupportedFilesystem,
        .NOMEM => return Error.OutOfMemory,
        .PERM => return Error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn fsmount(
    fd: posix.fd_t,
    flags: usize,
    attr_flags: usize,
) Error!posix.fd_t {
    const ret = system.syscall3(.fsmount, @bitCast(@as(isize, fd)), flags, attr_flags);
    switch (system.errno(ret)) {
        .SUCCESS => return @intCast(ret),
        .BUSY => return Error.FilesystemFdUsed,
        .INVAL => return Error.InvalidArguments,
        .NOMEM => return Error.OutOfMemory,
        .PERM => return Error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn openTree(fd: posix.fd_t, path: [*:0]const u8, flags: usize) Error!posix.fd_t {
    const ret = system.syscall3(.open_tree, @bitCast(@as(isize, fd)), @intFromPtr(path), flags);
    switch (system.errno(ret)) {
        .SUCCESS => return @intCast(ret),
        .NOENT => return Error.FileNotFound,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn fspick(fd: posix.fd_t, path: [*:0]const u8, flags: usize) Error!posix.fd_t {
    const ret = system.syscall3(.fspick, @bitCast(@as(isize, fd)), @intFromPtr(path), flags);
    switch (system.errno(ret)) {
        .SUCCESS => return @intCast(ret),
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn moveMount(
    from_fd: posix.fd_t,
    from_path: [*:0]const u8,
    to_fd: posix.fd_t,
    to_path: [*:0]const u8,
    flags: usize,
) Error!void {
    switch (system.errno(system.syscall5(
        .move_mount,
        @bitCast(@as(isize, from_fd)),
        @intFromPtr(from_path),
        @bitCast(@as(isize, to_fd)),
        @intFromPtr(to_path),
        flags,
    ))) {
        .SUCCESS => {},
        .NOENT => return Error.FileNotFound,
        .INVAL => return Error.InvalidArguments,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn mount(
    special: [*:0]const u8,
    dir: [*:0]const u8,
    fstype: ?[*:0]const u8,
    flags: u32,
    data: usize,
) Error!void {
    // TODO(jared): enumerate all possible errors
    switch (system.errno(system.mount(special, dir, fstype, flags, data))) {
        .SUCCESS => {},
        .NOENT => return Error.UnsupportedFilesystem,
        .NOMEM => return Error.OutOfMemory,
        else => |err| {
            log.err("failed to mount \"{s}\" on \"{s}\": {s}", .{ special, dir, @tagName(err) });
            return std.posix.unexpectedErrno(err);
        },
    }
}

pub fn umount(path: []const u8) Error!void {
    var path_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
    std.mem.copyForwards(u8, &path_buf, path);
    const pathZ: [*:0]const u8 = path_buf[0..path.len :0];
    switch (system.errno(system.umount2(pathZ, system.MNT.FORCE))) {
        .SUCCESS => {},
        .INVAL => return Error.InvalidArguments,
        .NOMEM => return Error.OutOfMemory,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn pidfdOpen(pid: posix.pid_t, flags: u32) !posix.fd_t {
    const ret = system.pidfd_open(pid, flags);
    if (ret < 0) {
        return switch (std.os.linux.errno(ret)) {
            .INVAL => error.UnsupportedFlags,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOMEM => error.OutOfMemory,
            .SRCH => error.ProcessNotFound,
            else => |err| posix.unexpectedErrno(err),
        };
    } else {
        return @intCast(ret);
    }
}

pub fn waitid(id_type: system.P, id: i32, infop: *system.siginfo_t, flags: u32, usage: ?*system.rusage) !void {
    while (true) {
        switch (system.errno(system.waitid(id_type, id, infop, flags, usage))) {
            .SUCCESS => {},
            .CHILD => return error.NoChildProcess,
            .INTR => continue,
            .INVAL => return error.InvalidArguments,
            else => |err| return posix.unexpectedErrno(err),
        }
        break;
    }
}

pub fn loopbackGetFree(io: std.Io) !usize {
    const loop_control = try std.Io.Dir.cwd().openFile(io, "/dev/loop-control", .{ .mode = .read_write });
    defer loop_control.close(io);

    const loop_nr = system.ioctl(loop_control.handle, C.LOOP_CTL_GET_FREE, 0);

    // TODO(jared): enumerate all possible errors
    switch (system.errno(loop_nr)) {
        .SUCCESS => return loop_nr,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn loopbackSetFD(loopback_device: posix.fd_t, handle: posix.fd_t) !void {
    switch (system.errno(system.ioctl(loopback_device, C.LOOP_SET_FD, @intCast(handle)))) {
        .SUCCESS => {},
        .BADF => unreachable,
        .INVAL => return error.InvalidBackingFile,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn ftruncate(fd: posix.fd_t, length: u64) !void {
    while (true) {
        switch (system.errno(system.ftruncate(fd, @intCast(length)))) {
            .SUCCESS => {},
            .INTR => continue,
            .INVAL => unreachable,
            .FBIG => return error.LengthTooBig,
            else => |err| return posix.unexpectedErrno(err),
        }
        break;
    }
}

pub fn memfdCreate(name: [*:0]const u8, flags: u32) !posix.fd_t {
    const ret = system.memfd_create(name, flags);
    switch (system.errno(ret)) {
        .SUCCESS => return @intCast(ret),
        .FAULT, .INVAL => unreachable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .PERM => return error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn sendfile(outfd: posix.fd_t, infd: posix.fd_t, offset: ?*i64, count: u64) !usize {
    const ret = system.sendfile(outfd, infd, offset, @intCast(count));
    switch (system.errno(ret)) {
        .SUCCESS => return ret,
        .INVAL => unreachable,
        .SPIPE => return error.Unseekable,
        .OVERFLOW => return error.CountTooBig,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn timerfdSetTime(fd: i32, flags: system.TFD.TIMER, new_value: *const system.itimerspec, old_value: ?*system.itimerspec) !void {
    switch (system.errno(system.timerfd_settime(fd, flags, new_value, old_value))) {
        .SUCCESS => {},
        .INVAL => unreachable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .PERM => return error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const Watchdog = struct {
    inner: std.Io.File,

    pub const Options = packed struct {
        disable_card: bool = false,
        enable_card: bool = false,
        temp_panic: bool = false,
    };

    pub fn init(io: std.Io) !@This() {
        return .{ .inner = try std.Io.Dir.cwd().openFile(
            io,
            "/dev/watchdog",
            .{ .mode = .read_write },
        ) };
    }

    pub fn deinit(self: *@This(), io: std.Io) void {
        self.inner.close(io);
    }

    pub fn keepAlive(self: *@This()) !void {
        switch (system.errno(system.ioctl(
            self.inner.handle,
            C.WDIOC_KEEPALIVE,
            0,
        ))) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    pub fn getTimeout(self: *@This()) !u32 {
        var watchdog_timeout: u32 = 0;
        switch (system.errno(system.ioctl(
            self.inner.handle,
            C.WDIOC_GETTIMEOUT,
            @intFromPtr(&watchdog_timeout),
        ))) {
            .SUCCESS => {},
            .OPNOTSUPP => return error.TimeoutUnknown,
            else => |err| return posix.unexpectedErrno(err),
        }
        return watchdog_timeout;
    }

    pub fn setOptions(self: *@This(), opts: Options) !void {
        const opts_n: usize = @intCast(@as(u3, @bitCast(opts)));
        switch (system.errno(system.ioctl(
            self.inner.handle,
            C.WDIOC_SETOPTIONS,
            @intFromPtr(&opts_n),
        ))) {
            .SUCCESS => {},
            .BUSY => return error.DeviceBusy,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
};
