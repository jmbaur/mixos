//! Do the things that need doing before a system stops running.
//!
//! This is deliberately not `umount -a`. BusyBox runs the shutdown actions
//! before exec'ing a restart action, so a shutdown that unmounts everything
//! takes the store with it, and whatever was meant to run next is no longer
//! there to be exec'd -- including BusyBox's own init, which lives on /usr.
//!
//! Nothing is lost by leaving those mounted. They are read-only, so there is
//! nothing on them to flush; the mounts worth taking down are the writable ones
//! a system may have added.

const std = @import("std");
const system = std.os.linux;

const init_mod = @import("init.zig");
const linux = @import("linux.zig");
const syslog = @import("syslog.zig");

const log = std.log.scoped(.mixos);

/// Mountpoints whatever runs next cannot do without: the root itself, the
/// hierarchy its programs live in, and the pseudo-filesystems init expects to
/// find already mounted.
///
/// The staging directory is here because of what a restart action may be: a
/// system staged there is the one `switch-root` is about to move into, and it
/// is staged before the signal that gets us here, so taking it down leaves that
/// command with nothing to switch into. Keeping it costs a system that is
/// merely stopping nothing, since it is bare unless someone put a system in it.
const keep = [_][]const u8{
    "/",
    "/dev",
    "/proc",
    "/sys",
    init_mod.sysroot,
    "/usr",
};

const Mount = struct {
    id: u64,
    mountpoint: []const u8,
};

fn isKept(mountpoint: []const u8) bool {
    inline for (keep) |k| {
        if (std.mem.eql(u8, mountpoint, k)) {
            return true;
        }

        // If the path matches anything we explicitly keep, we don't unmount it
        // or anything underneath it.
        if (k.len > 1 and std.mem.startsWith(u8, mountpoint, k) and
            mountpoint.len > k.len and mountpoint[k.len] == '/')
        {
            return true;
        }
    }

    return false;
}

/// Every mount in our namespace. listmount only reports the children of the
/// mount it is asked about, so the tree has to be walked.
fn allMounts(allocator: std.mem.Allocator) ![]Mount {
    var found: std.ArrayList(Mount) = .empty;

    var pending: std.ArrayList(u64) = .empty;
    try pending.append(allocator, linux.MountIdReq.LSMT_ROOT);

    var ids: [256]u64 = undefined;
    var buf: [4096]u8 align(@alignOf(linux.Statmount)) = undefined;

    while (pending.pop()) |parent| {
        const req: linux.MountIdReq = .{ .mnt_id = parent };
        const n = linux.listmount(&req, &ids, 0) catch |err| {
            log.warn("cannot list the mounts under {d}: {}", .{ parent, err });
            continue;
        };

        for (ids[0..n]) |id| {
            const stat_req: linux.MountIdReq = .{
                .mnt_id = id,
                .param = linux.STATMOUNT.MNT_POINT,
            };

            linux.statmount(&stat_req, &buf, 0) catch |err| {
                log.warn("cannot stat mount {d}: {}", .{ id, err });
                continue;
            };

            const stat: *const linux.Statmount = @ptrCast(&buf);
            const mountpoint = linux.Statmount.str(buf[0..stat.size], stat.mnt_point) orelse continue;

            try found.append(allocator, .{
                .id = id,
                .mountpoint = try allocator.dupe(u8, mountpoint),
            });

            // Children of this one are mounts too, and are not reported above.
            try pending.append(allocator, id);
        }
    }

    return found.toOwnedSlice(allocator);
}

/// The mount a path resolves through, by id rather than by comparing strings.
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
    _ = init;
    _ = args;

    syslog.init(name);
    defer syslog.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const own_mount = mountOf("/proc/self/exe");

    const mounts = allMounts(allocator) catch |err| {
        log.err("cannot enumerate mounts, leaving them alone: {}", .{err});
        return;
    };

    // Deepest first, so a mount is never held by one beneath it.
    std.mem.sort(Mount, mounts, {}, struct {
        fn deeperFirst(_: void, a: Mount, b: Mount) bool {
            return a.mountpoint.len > b.mountpoint.len;
        }
    }.deeperFirst);

    for (mounts) |mount| {
        if (isKept(mount.mountpoint)) {
            continue;
        }

        // We don't unmount the filesystem we are mounted on since we might not
        // be the only program that needs to run during shutdown (likely on the
        // same filesystem).
        if (own_mount) |own| {
            if (mount.id == own) {
                continue;
            }
        }

        const point = try allocator.dupeZ(u8, mount.mountpoint);

        // A lazy unmount still detaches one that something is holding onto, and
        // the writes worth caring about have been flushed by the attempt.
        linux.umount(point, 0) catch {
            linux.umount(point, system.MNT.DETACH) catch |err| {
                log.warn("could not unmount {s}: {}", .{ mount.mountpoint, err });
            };
        };
    }
}
