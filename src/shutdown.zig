//! Tears down any stateful mounts mounted in <mixos/src/init.zig>

const std = @import("std");
const system = std.os.linux;

const init_mod = @import("init.zig");
const linux = @import("linux.zig");
const kmsg = @import("kmsg.zig");

const log = std.log.scoped(.mixos);

fn mountOf(path: [*:0]const u8) ?u64 {
    var stx: system.Statx = undefined;
    const rc = system.statx(
        system.AT.FDCWD,
        path,
        0,
        .{ .MNT_ID_UNIQUE = true },
        &stx,
    );

    if (system.errno(rc) != .SUCCESS) {
        return null;
    }

    return stx.mnt_id;
}

pub fn main(
    init: std.process.Init,
    name: []const u8,
    args: *std.process.Args.Iterator,
) anyerror!void {
    _ = name;
    _ = args;

    kmsg.init(init.io);
    defer kmsg.deinit();

    defer system.sync();

    const root_mount_id = mountOf("/") orelse return;

    inline for (init_mod.state_bind_mounts) |clone| {
        unmount(root_mount_id, "/" ++ clone);
    }

    unmount(root_mount_id, "/etc");
    unmount(root_mount_id, init_mod.state_path);
}

fn unmount(root_mount_id: u64, path: [:0]const u8) void {
    const mount_id = mountOf(path) orelse return;

    if (mount_id == root_mount_id) {
        return;
    }

    linux.umount(path, system.MNT.DETACH) catch |err| {
        log.warn("failed to unmount {s}: {}", .{ path, err });
    };
}
