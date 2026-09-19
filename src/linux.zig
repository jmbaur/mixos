const posix = std.posix;
const std = @import("std");
const system = std.os.linux;

const C = @cImport({
    @cInclude("fcntl.h");
    @cInclude("linux/loop.h");
    @cInclude("linux/major.h");
    @cInclude("linux/mount.h");
    @cInclude("linux/watchdog.h");
});

// Separate from the import above, since the kernel's <linux/fcntl.h> that this
// brings in clashes with libc's <fcntl.h>.
const pidfd_h = @cImport({
    @cInclude("linux/pidfd.h");
});

const log = std.log.scoped(.mixos);

pub fn setHostname(hostname: []const u8) !void {
    switch (system.errno(system.syscall2(.sethostname, @intFromPtr(hostname.ptr), hostname.len))) {
        .SUCCESS => return,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const Error = error{
    DeviceBusy,
    DeviceNotBound,
    DeviceNotFound,
    FileNotFound,
    FilesystemFdUsed,
    Interrupted,
    InvalidArguments,
    InvalidMountpoint,
    NameTooLong,
    NoChildProcess,
    NoLoopDeviceAvailable,
    NotABlockDevice,
    NotADirectory,
    OutOfMemory,
    PermissionDenied,
    ReadOnlyFileSystem,
    SymLinkLoop,
    SystemResources,
    UnsupportedFilesystem,
} || posix.UnexpectedError;

pub fn fchdir(dir: std.Io.Dir) Error!void {
    while (true) {
        return switch (system.errno(system.fchdir(dir.handle))) {
            .SUCCESS => {},
            .BADF => return Error.InvalidArguments,
            .NOTDIR => return Error.NotADirectory,
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        };
    }
}

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
        .BUSY => return Error.DeviceBusy,
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
    switch (system.errno(system.mount(special, dir, fstype, flags, data))) {
        .SUCCESS => {},
        .ACCES, .PERM => return Error.PermissionDenied,
        .BUSY => return Error.DeviceBusy,
        .FAULT, .INVAL => return Error.InvalidArguments,
        .LOOP => return Error.SymLinkLoop,
        .MFILE, .NOSPC => return Error.SystemResources,
        .NAMETOOLONG => return Error.NameTooLong,
        .NODEV => return Error.UnsupportedFilesystem,
        .NOENT => return Error.FileNotFound,
        .NOMEM => return Error.OutOfMemory,
        .NOTBLK => return Error.NotABlockDevice,
        .NOTDIR => return Error.NotADirectory,
        .NXIO => return Error.DeviceNotFound,
        .ROFS => return Error.ReadOnlyFileSystem,
        else => |err| {
            log.err("failed to mount \"{s}\" on \"{s}\": {s}", .{ special, dir, @tagName(err) });
            return std.posix.unexpectedErrno(err);
        },
    }
}

/// `struct mnt_id_req`. The kernel tells versions of this apart by the size the
/// caller reports, so `size` has to match the fields actually filled in.
pub const MountIdReq = extern struct {
    size: u32 = @sizeOf(MountIdReq),
    spare: u32 = 0,
    mnt_id: u64,
    param: u64 = 0,
    mnt_ns_id: u64 = 0,

    /// Passed as `mnt_id` to list the mounts of the current namespace from its
    /// root, rather than the children of some particular mount.
    pub const LSMT_ROOT = C.LSMT_ROOT;
};

/// What `statmount` should fill in. It writes only what is asked for, and says
/// in `Statmount.mask` what it managed to produce.
pub const STATMOUNT = struct {
    pub const SB_BASIC = C.STATMOUNT_SB_BASIC;
    pub const MNT_BASIC = C.STATMOUNT_MNT_BASIC;
    pub const PROPAGATE_FROM = C.STATMOUNT_PROPAGATE_FROM;
    pub const MNT_ROOT = C.STATMOUNT_MNT_ROOT;
    pub const MNT_POINT = C.STATMOUNT_MNT_POINT;
    pub const FS_TYPE = C.STATMOUNT_FS_TYPE;
    pub const MNT_NS_ID = C.STATMOUNT_MNT_NS_ID;
    pub const MNT_OPTS = C.STATMOUNT_MNT_OPTS;
};

/// `struct statmount`. Variable length: the strings that were asked for follow
/// the fixed part, and the u32 fields naming them are byte offsets into that
/// trailing area rather than pointers.
pub const Statmount = extern struct {
    size: u32,
    mnt_opts: u32,
    mask: u64,
    sb_dev_major: u32,
    sb_dev_minor: u32,
    sb_magic: u64,
    sb_flags: u32,
    fs_type: u32,
    mnt_id: u64,
    mnt_parent_id: u64,
    mnt_id_old: u32,
    mnt_parent_id_old: u32,
    mnt_attr: u64,
    mnt_propagation: u64,
    mnt_peer_group: u64,
    mnt_master: u64,
    propagate_from: u64,
    mnt_root: u32,
    mnt_point: u32,
    mnt_ns_id: u64,
    spare2: [49]u64,

    /// The string at `offset` in the trailing area of a buffer this was read
    /// into. `buf` must be the whole buffer, not just the fixed part.
    pub fn str(buf: []const u8, offset: u32) ?[:0]const u8 {
        const start = @sizeOf(Statmount) + offset;
        if (start >= buf.len) {
            return null;
        }
        const rest = buf[start..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
        return rest[0..end :0];
    }
};

/// The ids of the mounts directly under `mnt_id`. Returns how many were
/// written into `ids`.
pub fn listmount(req: *const MountIdReq, ids: []u64, flags: u32) Error!usize {
    const rc = system.syscall4(
        .listmount,
        @intFromPtr(req),
        @intFromPtr(ids.ptr),
        ids.len,
        flags,
    );

    switch (system.errno(rc)) {
        .SUCCESS => return rc,
        .NOENT => return Error.FileNotFound,
        .NOMEM => return Error.OutOfMemory,
        .PERM => return Error.PermissionDenied,
        .INVAL => return Error.InvalidArguments,
        else => |err| return posix.unexpectedErrno(err),
    }
}

/// Fill `buf` with a `Statmount` for one mount, followed by whatever strings
/// `req.param` asked for.
pub fn statmount(req: *const MountIdReq, buf: []u8, flags: u32) Error!void {
    const rc = system.syscall4(
        .statmount,
        @intFromPtr(req),
        @intFromPtr(buf.ptr),
        buf.len,
        flags,
    );

    switch (system.errno(rc)) {
        .SUCCESS => {},
        .NOENT => return Error.FileNotFound,
        .NOMEM => return Error.OutOfMemory,
        .PERM => return Error.PermissionDenied,
        .INVAL => return Error.InvalidArguments,
        else => |err| return posix.unexpectedErrno(err),
    }
}

/// `struct mount_attr`. As with `MountIdReq`, the kernel tells versions apart
/// by the size the caller reports.
pub const MountAttr = extern struct {
    attr_set: u64 = 0,
    attr_clr: u64 = 0,
    propagation: u64 = 0,
    userns_fd: u64 = 0,
};

/// Apply mount attributes to an existing mount, which is the only way to get
/// them onto one that was cloned rather than created: a clone has no `fsmount`
/// to carry them.
pub fn mountSetattr(
    dir_fd: posix.fd_t,
    path: [*:0]const u8,
    flags: usize,
    attr: *const MountAttr,
) Error!void {
    switch (system.errno(system.syscall5(
        .mount_setattr,
        @bitCast(@as(isize, dir_fd)),
        @intFromPtr(path),
        flags,
        @intFromPtr(attr),
        @sizeOf(MountAttr),
    ))) {
        .SUCCESS => {},
        .NOENT => return Error.FileNotFound,
        .INVAL => return Error.InvalidArguments,
        .PERM => return Error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn pivotRoot(new: [:0]const u8, put_old: [:0]const u8) Error!void {
    switch (system.errno(system.pivot_root(new, put_old))) {
        .SUCCESS => {},
        .BUSY => return error.InvalidMountpoint,
        .INVAL => return Error.InvalidMountpoint,
        .NOTDIR => return Error.NotADirectory,
        .PERM => return Error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn umount(path: [:0]const u8, flags: u32) Error!void {
    switch (system.errno(system.umount2(path, flags))) {
        .SUCCESS => {},
        .BUSY => return Error.DeviceBusy,
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
            // Kernel older than 5.3.
            .NOSYS => error.OperationUnsupported,
            else => |err| posix.unexpectedErrno(err),
        };
    } else {
        return @intCast(ret);
    }
}

pub fn epollCreate1(flags: u32) !posix.fd_t {
    const ret = system.epoll_create1(flags);
    switch (system.errno(ret)) {
        .SUCCESS => return @intCast(ret),
        .INVAL => return error.InvalidArguments,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.OutOfMemory,
        // Kernel built without CONFIG_EPOLL.
        .NOSYS => return error.OperationUnsupported,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn epollCtl(epfd: posix.fd_t, op: u32, fd: posix.fd_t, event: ?*system.epoll_event) !void {
    switch (system.errno(system.epoll_ctl(epfd, op, fd, event))) {
        .SUCCESS => {},
        .BADF, .INVAL => return error.InvalidArguments,
        .EXIST => return error.FileDescriptorAlreadyPresentInSet,
        .LOOP => return error.OperationCausesCircularLoop,
        .NOENT => return error.FileDescriptorNotRegistered,
        .NOMEM => return error.OutOfMemory,
        .NOSPC => return error.UserResourceLimitReached,
        .PERM => return error.FileDescriptorIncompatibleWithEpoll,
        .NOSYS => return error.OperationUnsupported,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn epollWait(epfd: posix.fd_t, events: []system.epoll_event, timeout: i32) ![]system.epoll_event {
    while (true) {
        const ret = system.epoll_wait(epfd, events.ptr, @intCast(events.len), timeout);
        switch (system.errno(ret)) {
            .SUCCESS => return events[0..ret],
            .INTR => continue,
            .BADF, .FAULT, .INVAL => return error.InvalidArguments,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn timerfdCreate(clockid: system.timerfd_clockid_t, flags: system.TFD) !posix.fd_t {
    const ret = system.timerfd_create(clockid, flags);
    switch (system.errno(ret)) {
        .SUCCESS => return @intCast(ret),
        .INVAL => return error.InvalidArguments,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NODEV, .NOMEM => return error.SystemResources,
        // Kernel built without CONFIG_TIMERFD.
        .NOSYS => return error.OperationUnsupported,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn eventfd(initval: u32, flags: u32) !posix.fd_t {
    const ret = system.eventfd(initval, flags);
    switch (system.errno(ret)) {
        .SUCCESS => return @intCast(ret),
        .INVAL => return error.InvalidArguments,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NODEV, .NOMEM => return error.SystemResources,
        .NOSYS => return error.OperationUnsupported,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn pipe2(flags: system.O) ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    switch (system.errno(system.pipe2(&fds, flags))) {
        .SUCCESS => return fds,
        .FAULT, .INVAL => return error.InvalidArguments,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const PIDFD_SIGNAL = struct {
    /// The thread the pidfd refers to.
    pub const THREAD = pidfd_h.PIDFD_SIGNAL_THREAD;
    /// The whole process the pidfd refers to.
    pub const THREAD_GROUP = pidfd_h.PIDFD_SIGNAL_THREAD_GROUP;
    /// Every process in the process group led by the process the pidfd refers
    /// to, even once that process is gone.
    pub const PROCESS_GROUP = pidfd_h.PIDFD_SIGNAL_PROCESS_GROUP;
};

pub fn pidfdSendSignal(pidfd: posix.fd_t, signal: posix.SIG, flags: u32) !void {
    switch (std.os.linux.errno(std.os.linux.pidfd_send_signal(pidfd, signal, null, flags))) {
        .SUCCESS => {},
        .PERM => return error.PermissionDenied,
        .BADF, .INVAL => return error.InvalidArguments,
        .SRCH => return error.ProcessNotFound,
        else => |err| return posix.unexpectedErrno(err),
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

pub const LOOP_MAJOR = C.LOOP_MAJOR;

pub fn loopbackGetFree(io: std.Io) !usize {
    const loop_control = try std.Io.Dir.cwd().openFile(io, "/dev/loop-control", .{ .mode = .read_write });
    defer loop_control.close(io);

    const loop_nr = system.ioctl(loop_control.handle, C.LOOP_CTL_GET_FREE, 0);

    switch (system.errno(loop_nr)) {
        .SUCCESS => return loop_nr,
        .BADF, .NOTTY => return Error.InvalidArguments,
        // Only for a fatal signal, so there is no point in trying again.
        .INTR => return Error.Interrupted,
        .NOMEM => return Error.OutOfMemory,
        .NOSPC => return Error.NoLoopDeviceAvailable,
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

pub fn loopbackClearFD(loopback_device: posix.fd_t) Error!void {
    switch (system.errno(system.ioctl(loopback_device, C.LOOP_CLR_FD, 0))) {
        .SUCCESS => {},
        .BUSY => return Error.DeviceBusy,
        .NXIO => return Error.DeviceNotBound,
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

    /// Returns the timeout the driver actually set, which it may round.
    pub fn setTimeout(self: *@This(), seconds: u32) !u32 {
        var watchdog_timeout: c_int = @intCast(seconds);
        switch (system.errno(system.ioctl(
            self.inner.handle,
            C.WDIOC_SETTIMEOUT,
            @intFromPtr(&watchdog_timeout),
        ))) {
            .SUCCESS => {},
            .INVAL => return error.TimeoutOutOfRange,
            .OPNOTSUPP => return error.OperationUnsupported,
            else => |err| return posix.unexpectedErrno(err),
        }
        return @intCast(watchdog_timeout);
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
