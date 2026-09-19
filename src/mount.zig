const linux = @import("linux.zig");
const posix = std.posix;
const std = @import("std");
const system = std.os.linux;

const C = @cImport({
    @cInclude("linux/fcntl.h");
    @cInclude("linux/mount.h");
});

/// A mount, not necessarily attached anywhere yet. Comes either from a
/// `Context` or from cloning an existing tree.
const Mount = @This();

fd: posix.fd_t,

const Error = linux.Error;

pub const Context = struct {
    fd: posix.fd_t,
    attrs: usize = 0,

    pub fn setSource(self: *Context, source: []const u8) Error!void {
        var source_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
        std.mem.copyForwards(u8, &source_buf, source);
        const sourceZ: [*:0]const u8 = source_buf[0..source.len :0];

        try linux.fsconfig(self.fd, C.FSCONFIG_SET_STRING, "source", sourceZ, 0);
    }

    pub fn setFD(self: *Context, name: []const u8, fd: posix.fd_t) Error!void {
        var name_buf = std.mem.zeroes([std.fs.max_name_bytes]u8);
        std.mem.copyForwards(u8, &name_buf, name);
        const nameZ: [*:0]const u8 = name_buf[0..name.len :0];

        try linux.fsconfig(self.fd, C.FSCONFIG_SET_FD, nameZ, null, @bitCast(@as(isize, fd)));
    }

    pub fn setOption(self: *Context, key: []const u8, value: ?[]const u8) Error!void {
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
            try linux.fsconfig(self.fd, C.FSCONFIG_SET_STRING, keyZ, valueZ, 0);
        } else {
            try linux.fsconfig(self.fd, C.FSCONFIG_SET_FLAG, keyZ, null, 0);
        }
    }

    /// Create the mount without attaching it anywhere yet, so that what it
    /// holds can be looked at through `Mount.root()` before `Mount.finish()`
    /// puts it in place. Consumes the context.
    pub fn detach(self: *Context, attrs: usize) Error!Mount {
        defer {
            _ = system.close(self.fd);
            self.* = undefined;
        }

        try linux.fsconfig(self.fd, C.FSCONFIG_CMD_CREATE_EXCL, null, null, 0);
        return .{ .fd = try linux.fsmount(self.fd, C.FSMOUNT_CLOEXEC, self.attrs | attrs) };
    }

    /// Create the mount and attach it at `dest`. Consumes the context.
    pub fn finish(self: *Context, dest_dir: std.Io.Dir, dest: [*:0]const u8, attrs: usize) Error!void {
        var mount = try self.detach(attrs);
        try mount.finish(dest_dir, dest, 0);
    }

    /// Apply the configuration to the superblock the context was picked from.
    /// Consumes the context.
    pub fn reconfigure(self: *Context) Error!void {
        defer {
            _ = system.close(self.fd);
            self.* = undefined;
        }

        try linux.fsconfig(self.fd, C.FSCONFIG_CMD_RECONFIGURE, null, null, 0);
    }
};

/// A new filesystem of type `fstype`, to be configured.
pub fn init(fstype: [*:0]const u8) !Context {
    return .{ .fd = try linux.fsopen(fstype) };
}

/// A detached clone of the mount tree at `path`.
pub fn initTree(dir: std.Io.Dir, path: []const u8) Error!Mount {
    var path_buf = std.mem.zeroes([std.fs.max_path_bytes]u8);
    std.mem.copyForwards(u8, &path_buf, path);
    const pathZ: [*:0]const u8 = path_buf[0..path.len :0];

    return .{ .fd = try linux.openTree(dir.handle, pathZ, C.OPEN_TREE_CLONE | C.O_CLOEXEC) };
}

/// The root dir of the mount, not to be closed.
pub fn root(self: *const Mount) std.Io.Dir {
    return .{ .handle = self.fd };
}

/// Attach the mount at `dest`, with `attrs` set on it and everything below it.
/// Consumes the mount.
pub fn finish(self: *Mount, dest_dir: std.Io.Dir, dest: [*:0]const u8, attrs: usize) Error!void {
    defer {
        _ = system.close(self.fd);
        self.* = undefined;
    }

    if (attrs != 0) {
        const mount_attr: linux.MountAttr = .{ .attr_set = attrs };
        try linux.mountSetattr(self.fd, "", C.AT_EMPTY_PATH | C.AT_RECURSIVE, &mount_attr);
    }

    try linux.moveMount(self.fd, "", dest_dir.handle, dest, C.MOVE_MOUNT_F_EMPTY_PATH);
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
