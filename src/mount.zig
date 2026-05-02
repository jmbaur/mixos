const std = @import("std");
const posix = std.posix;
const system = std.os.linux;

const C = @cImport({
    @cInclude("fcntl.h");
    @cInclude("linux/mount.h");
});

const log = std.log.scoped(.mixos);

/// Close the file on execve()
const OPEN_TREE_CLOEXEC = C.O_CLOEXEC;

const Mount = @This();

const FD = enum { fs, mnt };

handle: union(FD) { fs: posix.fd_t, mnt: posix.fd_t },
attrs: usize = 0,

pub const Error = error{
    FileNotFound,
    FilesystemFdUsed,
    InvalidArguments,
    OutOfMemory,
    PermissionDenied,
    UnsupportedFilesystem,
} || posix.UnexpectedError;

fn fsopen(fsname: [*:0]const u8) Error!posix.fd_t {
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

fn fsconfig(fd: posix.fd_t, cmd: usize, key: ?[*:0]const u8, value: ?[*:0]const u8, aux: usize) Error!void {
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

fn fsmount(
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

fn open_tree(fd: posix.fd_t, path: [*:0]const u8, flags: usize) Error!posix.fd_t {
    const ret = system.syscall3(.open_tree, @bitCast(@as(isize, fd)), @intFromPtr(path), flags);
    switch (system.errno(ret)) {
        .SUCCESS => return @intCast(ret),
        .NOENT => return Error.FileNotFound,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn fspick(fd: posix.fd_t, path: [*:0]const u8, flags: usize) Error!posix.fd_t {
    const ret = system.syscall3(.fspick, @bitCast(@as(isize, fd)), @intFromPtr(path), flags);
    switch (system.errno(ret)) {
        .SUCCESS => return @intCast(ret),
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn move_mount(
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

pub fn init(fstype: [*:0]const u8) Error!Mount {
    return .{ .handle = .{ .fs = try fsopen(fstype) } };
}

pub fn initTree(dir: std.Io.Dir, path: []const u8) Error!Mount {
    var path_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
    std.mem.copyForwards(u8, &path_buf, path);
    const pathZ: [*:0]const u8 = path_buf[0..path.len :0];

    return .{ .handle = .{ .mnt = try open_tree(dir.handle, pathZ, C.OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC) } };
}

pub fn initPick(dir: std.Io.Dir, path: []const u8) Error!Mount {
    var path_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
    std.mem.copyForwards(u8, &path_buf, path);
    const pathZ: [*:0]const u8 = path_buf[0..path.len :0];

    return .{ .handle = .{ .fs = try fspick(dir.fd, pathZ, 0) } };
}

pub fn setSource(self: *Mount, source: []const u8) Error!void {
    const fsfd = switch (self.handle) {
        .mnt => {
            log.warn("{s} not available for mntfd", .{@src().fn_name});
            return;
        },
        .fs => |fsfd| fsfd,
    };

    var source_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
    std.mem.copyForwards(u8, &source_buf, source);
    const sourceZ: [*:0]const u8 = source_buf[0..source.len :0];

    try fsconfig(fsfd, C.FSCONFIG_SET_STRING, "source", sourceZ, 0);
}

pub fn setFD(self: *Mount, name: []const u8, fd: posix.fd_t) Error!void {
    const fsfd = switch (self.handle) {
        .mnt => {
            log.warn("{s} not available for mntfd", .{@src().fn_name});
            return;
        },
        .fs => |fsfd| fsfd,
    };

    var name_buf = std.mem.zeroes([std.fs.max_name_bytes]u8);
    std.mem.copyForwards(u8, &name_buf, name);
    const nameZ: [*:0]const u8 = name_buf[0..name.len :0];

    try fsconfig(fsfd, C.FSCONFIG_SET_FD, nameZ, null, @bitCast(@as(isize, fd)));
}

pub fn setOption(self: *Mount, key: []const u8, value: ?[]const u8) Error!void {
    const fsfd = switch (self.handle) {
        .mnt => {
            log.warn("{s} not available for mntfd", .{@src().fn_name});
            return;
        },
        .fs => |fsfd| fsfd,
    };

    if (mount_attrs.get(key)) |flag| {
        self.attrs |= flag;
        return;
    }

    var key_buf = std.mem.zeroes([std.fs.max_name_bytes]u8);
    std.mem.copyForwards(u8, &key_buf, key);
    const keyZ: [*:0]const u8 = key_buf[0..key.len :0];

    if (value) |v| {
        var value_buf = std.mem.zeroes([std.fs.max_name_bytes]u8);
        std.mem.copyForwards(u8, &value_buf, v);
        const valueZ: [*:0]const u8 = value_buf[0..v.len :0];
        try fsconfig(fsfd, C.FSCONFIG_SET_STRING, keyZ, valueZ, 0);
    } else {
        try fsconfig(fsfd, C.FSCONFIG_SET_FLAG, keyZ, null, 0);
    }
}

pub fn finish(self: *Mount, dest_dir: std.Io.Dir, dest: [*:0]const u8, attrs: usize) Error!void {
    const mntfd = switch (self.handle) {
        .fs => |fsfd| b: {
            try fsconfig(fsfd, C.FSCONFIG_CMD_CREATE_EXCL, null, null, 0);
            const mntfd = try fsmount(fsfd, C.FSMOUNT_CLOEXEC, self.attrs | attrs);
            _ = system.close(fsfd);
            break :b mntfd;
        },
        .mnt => |mntfd| mntfd,
    };
    defer _ = system.close(mntfd);

    try move_mount(mntfd, "", dest_dir.handle, dest, C.MOVE_MOUNT_F_EMPTY_PATH);

    self.* = undefined;
}

pub fn reconfigure(self: *Mount) Error!void {
    const fsfd = switch (self.handle) {
        .mnt => {
            log.warn("{s} not available for mntfd", .{@src().fn_name});
            return;
        },
        .fs => |fsfd| fsfd,
    };
    defer _ = system.close(fsfd);

    try fsconfig(fsfd, C.FSCONFIG_CMD_RECONFIGURE, null, null, 0);

    self.* = undefined;
}

pub const Options = struct {
    pub const RDONLY = C.MOUNT_ATTR_RDONLY;
    pub const NOSUID = C.MOUNT_ATTR_NOSUID;
    pub const NODEV = C.MOUNT_ATTR_NODEV;
    pub const NOEXEC = C.MOUNT_ATTR_NOEXEC;
    pub const RELATIME = C.MOUNT_ATTR_RELATIME;
    pub const NOATIME = C.MOUNT_ATTR_NOATIME;
    pub const STRICTATIME = C.MOUNT_ATTR_STRICTATIME;
    pub const NODIRATIME = C.MOUNT_ATTR_NODIRATIME;
    pub const IDMAP = C.MOUNT_ATTR_IDMAP;
    pub const NOSYMFOLLOW = C.MOUNT_ATTR_NOSYMFOLLOW;
};

const mount_attrs = std.StaticStringMap(u32).initComptime(.{
    .{ "rdonly", C.MOUNT_ATTR_RDONLY },
    .{ "relatime", C.MOUNT_ATTR_RELATIME },
    .{ "nosuid", C.MOUNT_ATTR_NOSUID },
    .{ "nodev", C.MOUNT_ATTR_NODEV },
    .{ "noexec", C.MOUNT_ATTR_NOEXEC },
    .{ "noatime", C.MOUNT_ATTR_NOATIME },
    .{ "nodiratime", C.MOUNT_ATTR_NODIRATIME },
    .{ "strictatime", C.MOUNT_ATTR_STRICTATIME },
    .{ "defaults", 0 },
});

pub fn mount(
    special: [*:0]const u8,
    dir: [*:0]const u8,
    fstype: ?[*:0]const u8,
    flags: u32,
    data: usize,
) !void {
    // TODO(jared): enumerate all possible errors
    switch (system.errno(system.mount(special, dir, fstype, flags, data))) {
        .SUCCESS => {},
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
