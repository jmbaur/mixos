const linux = @import("linux.zig");
const posix = std.posix;
const std = @import("std");
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

pub fn init(fstype: [*:0]const u8) !Mount {
    return .{ .handle = .{ .fs = try linux.fsopen(fstype) } };
}

const Error = linux.Error;

pub fn initTree(dir: std.Io.Dir, path: []const u8) Error!Mount {
    var path_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
    std.mem.copyForwards(u8, &path_buf, path);
    const pathZ: [*:0]const u8 = path_buf[0..path.len :0];

    return .{ .handle = .{ .mnt = try linux.openTree(dir.handle, pathZ, C.OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC) } };
}

pub fn initPick(dir: std.Io.Dir, path: []const u8) Error!Mount {
    var path_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
    std.mem.copyForwards(u8, &path_buf, path);
    const pathZ: [*:0]const u8 = path_buf[0..path.len :0];

    return .{ .handle = .{ .fs = try linux.fspick(dir.fd, pathZ, 0) } };
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

    try linux.fsconfig(fsfd, C.FSCONFIG_SET_STRING, "source", sourceZ, 0);
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

    try linux.fsconfig(fsfd, C.FSCONFIG_SET_FD, nameZ, null, @bitCast(@as(isize, fd)));
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
        try linux.fsconfig(fsfd, C.FSCONFIG_SET_STRING, keyZ, valueZ, 0);
    } else {
        try linux.fsconfig(fsfd, C.FSCONFIG_SET_FLAG, keyZ, null, 0);
    }
}

pub fn finish(self: *Mount, dest_dir: std.Io.Dir, dest: [*:0]const u8, attrs: usize) Error!void {
    const mntfd = switch (self.handle) {
        .fs => |fsfd| b: {
            try linux.fsconfig(fsfd, C.FSCONFIG_CMD_CREATE_EXCL, null, null, 0);
            const mntfd = try linux.fsmount(fsfd, C.FSMOUNT_CLOEXEC, self.attrs | attrs);
            _ = system.close(fsfd);
            break :b mntfd;
        },
        .mnt => |mntfd| mntfd,
    };
    defer _ = system.close(mntfd);

    try linux.moveMount(mntfd, "", dest_dir.handle, dest, C.MOVE_MOUNT_F_EMPTY_PATH);

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

    try linux.fsconfig(fsfd, C.FSCONFIG_CMD_RECONFIGURE, null, null, 0);

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
