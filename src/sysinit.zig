const std = @import("std");
const system = std.posix.system;
const Kmod = @import("./kmod.zig");
const fs = @import("./fs.zig");
const MS = std.os.linux.MS;

const log = std.log.scoped(.mixos);

const KernelConfig = struct {
    CGROUPS: bool,
    CONFIGFS_FS: bool,
    DEBUG_FS_ALLOW_ALL: bool,
    FTRACE: bool,
    MODULES: bool,
    SECURITYFS: bool,
    SHMEM: bool,
    UNIX98_PTYS: bool,
    UNIX: bool,
};

const BootConfig = struct {
    kernelModules: []const []const u8,
    kernel: KernelConfig,
};

const StateConfig = struct {
    /// Path to program to run to initialize state storage
    init: ?[]const u8,

    type: []const u8,
    what: []const u8,
    where: []const u8,
    options: []const []const u8,
};

const SysinitConfig = struct {
    boot: BootConfig,
    state: StateConfig,
};

/// By the point this runs, we already have /sys, /dev, and /proc mounted.
fn mountFilesystems(kernel: *const KernelConfig) void {
    if (kernel.UNIX98_PTYS) {
        std.fs.cwd().makeDir("/dev/pts") catch {};
        fs.mount(
            "devpts",
            "/dev/pts",
            "devpts",
            MS.NOEXEC | MS.NOSUID,
            0,
        ) catch {};
    }

    if (kernel.CONFIGFS_FS) {
        fs.mount(
            "configfs",
            "/sys/kernel/config",
            "configfs",
            MS.NOEXEC | MS.NOSUID | MS.NODEV,
            0,
        ) catch {};
    }

    if (kernel.DEBUG_FS_ALLOW_ALL) {
        fs.mount(
            "debugfs",
            "/sys/kernel/debug",
            "debugfs",
            MS.NOEXEC | MS.NOSUID | MS.NODEV,
            0,
        ) catch {};
    }

    if (kernel.FTRACE) {
        fs.mount(
            "tracefs",
            "/sys/kernel/tracing",
            "tracefs",
            MS.NOSUID | MS.NODEV | MS.NOEXEC | MS.RELATIME,
            0,
        ) catch {};
    }

    if (kernel.SECURITYFS) {
        fs.mount(
            "securityfs",
            "/sys/kernel/security",
            "securityfs",
            MS.NOSUID | MS.NODEV | MS.NOEXEC | MS.RELATIME,
            0,
        ) catch {};
    }

    if (kernel.CGROUPS) {
        fs.mount(
            "cgroup2",
            "/sys/fs/cgroup",
            "cgroup2",
            MS.NOEXEC | MS.RELATIME | MS.NOSUID | MS.NODEV,
            @intFromPtr("nsdelegate,memory_recursiveprot"),
        ) catch {};
    }

    if (kernel.SHMEM) {
        std.fs.cwd().makeDir("/dev/shm") catch {};
        fs.mount("tmpfs", "/dev/shm", "tmpfs", MS.NOSUID | MS.NODEV, 0) catch {};
    }

    fs.mount("tmpfs", "/tmp", "tmpfs", MS.NOSUID | MS.NODEV, 0) catch {};
}

const mount_options = std.StaticStringMap(u32).initComptime(.{
    .{ "ro", MS.RDONLY },
    .{ "relatime", MS.RELATIME },
    .{ "nosuid", MS.NOSUID },
    .{ "nodev", MS.NODEV },
    .{ "noexec", MS.NOEXEC },
    .{ "remount", MS.REMOUNT },
    .{ "noatime", MS.NOATIME },
    .{ "bind", MS.BIND },
    .{ "rbind", MS.BIND | MS.REC },
    .{ "nodiratime", MS.NODIRATIME },
    .{ "sync", MS.SYNCHRONOUS },
    .{ "dirsync", MS.DIRSYNC },
    .{ "lazytime", MS.LAZYTIME },
    .{ "strictatime", MS.STRICTATIME },
    .{ "mand", MS.MANDLOCK },
    .{ "private", MS.PRIVATE },
    .{ "rprivate", MS.PRIVATE | MS.REC },
    .{ "slave", MS.SLAVE },
    .{ "rslave", MS.SLAVE | MS.REC },
    .{ "move", MS.MOVE },
    .{ "shared", MS.SHARED },
    .{ "rshared", MS.SHARED | MS.REC },
    .{ "unbindable", MS.UNBINDABLE },
    .{ "runbindable", MS.UNBINDABLE | MS.REC },
    .{ "defaults", 0 },
});

fn parseStringMountOptions(options: []const []const u8, data_writer: *std.Io.Writer) !u32 {
    var flags: u32 = MS.SILENT;

    for (options) |option| {
        if (mount_options.get(option)) |bitmask| {
            flags |= bitmask;
        } else {
            if (data_writer.end > 0) {
                try data_writer.writeByte(',');
            }
            try data_writer.writeAll(option);
            try data_writer.flush();
        }
    }

    return flags;
}

test "parseStringMountOptions" {
    var data_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer data_writer.deinit();

    {
        const flags = parseStringMountOptions(&.{ "noatime", "compress=zstd" }, &data_writer.writer) catch unreachable;
        try std.testing.expectEqualStrings("compress=zstd", data_writer.written());
        try std.testing.expectEqual(MS.SILENT | MS.NOATIME, flags);
    }

    data_writer.clearRetainingCapacity();

    {
        const flags = parseStringMountOptions(&.{ "ro", "noatime", "compress=zstd", "defaults" }, &data_writer.writer) catch unreachable;
        try std.testing.expectEqualStrings("compress=zstd", data_writer.written());
        try std.testing.expectEqual(MS.SILENT | MS.NOATIME | MS.RDONLY, flags);
    }
}

fn initAndSetupState(allocator: std.mem.Allocator, state: *const StateConfig) !void {
    b: {
        if (state.init) |init| {
            var child = std.process.Child.init(&.{init}, allocator);

            const term = try child.spawnAndWait();
            switch (term) {
                .Exited => |code| if (code == 0) {
                    log.debug("initialized storage backing /state", .{});
                    break :b;
                },
                else => {},
            }

            log.err("state initialization failed: {}", .{term});
            return error.StateInit;
        }
    }

    const what = try allocator.dupeZ(u8, state.what);
    defer allocator.free(what);

    const where = try allocator.dupeZ(u8, state.where);
    defer allocator.free(where);

    const @"type" = try allocator.dupeZ(u8, state.type);
    defer allocator.free(@"type");

    var data: std.Io.Writer.Allocating = .init(allocator);
    defer data.deinit();

    const flags = try parseStringMountOptions(state.options, &data.writer);

    log.debug("mounting state what={s} where={s} type={s} flags={} data={s}", .{
        what,
        where,
        @"type",
        flags,
        data.written(),
    });

    const state_mount_data = try allocator.dupeZ(u8, data.written());
    defer allocator.free(state_mount_data);

    try fs.mount(
        what,
        where,
        @"type",
        flags,
        if (data.writer.end > 0) @intFromPtr(state_mount_data.ptr) else 0,
    );

    // Ensure /var persists data back to /state
    b: {
        const var_dir = try std.fs.path.joinZ(allocator, &.{ state.where, "var" });
        defer allocator.free(var_dir);

        std.fs.cwd().makePath(var_dir) catch |err| {
            log.err("failed to create /var mount source: {}", .{err});
            break :b;
        };
        fs.mount(var_dir, "/var", "", MS.BIND, 0) catch {
            break :b;
        };

        // Create /var/empty, useful in many contexts
        std.fs.cwd().makePath("/var/empty") catch |err| {
            log.err("failed to create /var/empty: {}", .{err});
            break :b;
        };

        // Symlink /var/run to /run, which is a common symlink that is expected
        // to exist by many tools.
        var dir = std.fs.cwd().openDir("/var", .{}) catch break :b;
        defer dir.close();
        dir.symLink("../run", "run", .{ .is_directory = true }) catch |err| {
            log.err("failed to symlink /var/run to /run: {}", .{err});
            break :b;
        };
    }

    // Ensure /var persists data back to /state
    b: {
        const root_dir = try std.fs.path.joinZ(allocator, &.{ state.where, "root" });
        defer allocator.free(root_dir);

        std.fs.cwd().makePath(root_dir) catch |err| {
            log.err("failed to create /root mount source: {}", .{err});
            break :b;
        };
        fs.mount(root_dir, "/root", "", MS.BIND, 0) catch {
            break :b;
        };
    }

    // Ensure /etc is writeable, needed by various programs.
    b: {
        const upper_etc_dir = try std.fs.path.joinZ(allocator, &.{ state.where, ".etc/upper" });
        defer allocator.free(upper_etc_dir);

        const work_etc_dir = try std.fs.path.joinZ(allocator, &.{ state.where, ".etc/work" });
        defer allocator.free(work_etc_dir);

        std.fs.cwd().makePath(upper_etc_dir) catch |err| {
            log.err("failed to create etc upper dir: {}", .{err});
            break :b;
        };

        std.fs.cwd().makePath(work_etc_dir) catch |err| {
            log.err("failed to create etc work dir: {}", .{err});
            break :b;
        };

        const overlay_mount_data = try std.fmt.allocPrintSentinel(
            allocator,
            "lowerdir=/etc,upperdir={s},workdir={s}",
            .{ upper_etc_dir, work_etc_dir },
            0,
        );
        defer allocator.free(overlay_mount_data);

        fs.mount(
            "overlay",
            "/etc",
            "overlay",
            MS.RELATIME,
            @intFromPtr(overlay_mount_data.ptr),
        ) catch {
            break :b;
        };
    }

    // Ensure basic state directories exist
    {
        std.fs.cwd().makePath("/var/log") catch |err| {
            log.err("failed to create /var/log: {}", .{err});
        };

        std.fs.cwd().makePath("/var/spool/cron/crontabs") catch |err| {
            log.err("failed to create /var/spool/cron/crontabs: {}", .{err});
        };
    }
}

fn sethostname(hostname: []const u8) usize {
    return std.os.linux.syscall2(.sethostname, @intFromPtr(hostname.ptr), hostname.len);
}

fn extractHostname(etc_hostname_contents: []const u8) ?[]const u8 {
    var split = std.mem.splitScalar(u8, etc_hostname_contents, '\n');
    while (split.next()) |line| {
        const hostname = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (std.mem.startsWith(u8, hostname, "#")) {
            continue;
        }

        if (hostname.len == 0) {
            continue;
        }

        return hostname;
    }

    return null;
}

test "extractHostname" {
    try std.testing.expectEqual(null, extractHostname("# foo"));
    try std.testing.expectEqual(null, extractHostname(" # foo"));
    try std.testing.expectEqual(null, extractHostname(""));
    try std.testing.expectEqualStrings("foo", extractHostname(" foo ") orelse unreachable);
    try std.testing.expectEqualStrings("foo", extractHostname("foo") orelse unreachable);
    try std.testing.expectEqualStrings("foo", extractHostname("# some comment\nfoo") orelse unreachable);
}

// /etc/hostname is described as a single-line, newline-terminated file
// containing the hostname of the system, see hostname(5).
fn setupHostname(allocator: std.mem.Allocator) !void {
    const hostname_file = std.fs.cwd().openFile("/etc/hostname", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer hostname_file.close();

    const hostname_contents = try hostname_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(hostname_contents);

    if (extractHostname(hostname_contents)) |hostname| {
        switch (system.E.init(sethostname(hostname))) {
            .SUCCESS => return,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn setupNetworking(kernel: *const KernelConfig) !void {
    if (!kernel.UNIX) {
        return;
    }

    // TODO(jared): netlink is nicer
    const fd = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        std.posix.IPPROTO.IP,
    );
    defer std.posix.close(fd);

    {
        var ifr = std.mem.zeroes(std.posix.system.ifreq);
        std.mem.copyForwards(u8, &ifr.ifrn.name, "lo");
        switch (system.E.init(std.os.linux.ioctl(
            fd,
            std.os.linux.SIOCGIFFLAGS,
            @intFromPtr(&ifr),
        ))) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }

        ifr.ifru.flags.UP = true;

        switch (system.E.init(std.os.linux.ioctl(
            fd,
            std.os.linux.SIOCSIFFLAGS,
            @intFromPtr(&ifr),
        ))) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn done(mode: enum { check, mark }) !void {
    const done_filepath = "done";

    var run_mixos_dir = std.fs.cwd().makeOpenPath("/run/mixos", .{}) catch |err| if (mode == .mark) {
        return err;
    } else {
        return;
    };
    defer run_mixos_dir.close();

    switch (mode) {
        .check => {
            run_mixos_dir.access(done_filepath, .{}) catch return;
            return error.SysinitDone;
        },
        .mark => {
            const done_file = try run_mixos_dir.createFile(done_filepath, .{ .truncate = true, .mode = 0o400 });
            defer done_file.close();
        },
    }
}

fn setupModprobeAndLoadModules(
    allocator: std.mem.Allocator,
    kernel: *const KernelConfig,
    modules: []const []const u8,
) !void {
    if (!kernel.MODULES) {
        return;
    }

    var kmod = try Kmod.init(allocator);
    defer kmod.deinit();

    for (modules) |module| {
        kmod.modprobe(module) catch |err| {
            log.err("failed to load module {s}: {}", .{ module, err });
        };
    }
}

fn mdevScan(allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(&.{ "mdev", "-s", "-f" }, allocator);
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }

    log.err("mdev failed with exit: {}", .{term});
}

pub fn main(args: *std.process.ArgIterator) !void {
    done(.check) catch {
        log.err("sysinit already ran, skipping", .{});
        return;
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const sysinit_json_filepath = args.next() orelse return error.MissingArg;

    var sysinit_json_file = try std.fs.cwd().openFile(sysinit_json_filepath, .{});
    defer sysinit_json_file.close();

    const sysinit_json_contents = try sysinit_json_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    const sysinit_config = try std.json.parseFromSlice(SysinitConfig, allocator, sysinit_json_contents, .{});

    mountFilesystems(&sysinit_config.value.boot.kernel);

    try setupModprobeAndLoadModules(allocator, &sysinit_config.value.boot.kernel, sysinit_config.value.boot.kernelModules);

    mdevScan(allocator) catch |err| {
        log.err("failed to run mdev: {}", .{err});
    };

    initAndSetupState(allocator, &sysinit_config.value.state) catch |err| {
        log.err("failed to mount /state: {}", .{err});

        // If we failed to mount /state, not much else will work. Prevent the
        // boot from continuing by blocking here.
        var futex = std.atomic.Value(u32).init(0);
        while (true) std.Thread.Futex.wait(&futex, 0);
    };

    setupHostname(allocator) catch |err| {
        log.err("failed to set hostname: {}", .{err});
    };

    setupNetworking(&sysinit_config.value.boot.kernel) catch |err| {
        log.err("failed to setup networking: {}", .{err});
    };

    done(.mark) catch |err| {
        log.err("failed to mark sysinit as done: {}", .{err});
    };
}
