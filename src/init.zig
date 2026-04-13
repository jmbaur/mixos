const Kmod = @import("kmod.zig");
const Mount = @import("mount.zig");
const Watchdog = @import("watchdog.zig");
const builtin = @import("builtin");
const kmsg = @import("kmsg.zig");
const posix = std.posix;
const process = @import("process.zig");
const std = @import("std");
const system = std.os.linux;
const C = @cImport({
    @cInclude("linux/fcntl.h");
});

const log = std.log.scoped(.mixos);

const LOOP_SET_FD = 0x4C00;
const LOOP_CTL_GET_FREE = 0x4C82;

fn findCmdline(cmdline: []const u8, want_key: []const u8) ?[]const u8 {
    var entry_split = std.mem.tokenizeSequence(u8, cmdline, &std.ascii.whitespace);
    while (entry_split.next()) |entry| {
        var split = std.mem.splitScalar(u8, entry, '=');
        const key = split.next() orelse continue;
        const value = split.next() orelse continue;

        if (std.mem.eql(u8, key, want_key)) {
            return std.mem.trim(u8, value, &std.ascii.whitespace);
        }
    }

    return null;
}

test findCmdline {
    try std.testing.expectEqual(null, findCmdline("foo", ""));
    try std.testing.expectEqualStrings("1", findCmdline("foo=1", "foo") orelse unreachable);
    try std.testing.expectEqualStrings("1", findCmdline("foo=1 \t\n", "foo") orelse unreachable);
}

// TODO(jared): Make this a hashmap of kconfig to bool to allow for easier
// additions.
const KernelConfig = struct {
    CGROUPS: bool,
    CONFIGFS_FS: bool,
    DEBUG_FS_ALLOW_ALL: bool,
    FTRACE: bool,
    MODULES: bool,
    SECURITY: bool,
    SECURITYFS: bool,
    SHMEM: bool,
    UNIX98_PTYS: bool,
    UNIX: bool,
};

const WatchdogConfig = struct {};

const BootConfig = struct {
    kernelModules: []const []const u8,
    kernel: KernelConfig,
    watchdog: ?WatchdogConfig,
};

const StateConfig = struct {
    /// Path to program to run to initialize state storage
    init: ?[]const u8,

    /// The filesystem type
    fsType: []const u8,

    /// The source to mount (e.g. block device)
    source: []const u8,

    /// Mount options
    options: []const []const u8,
};

const Manifest = struct {
    /// The PID1 of the post-initrd system.
    init: []const u8,

    /// The nix store dir (most likely /nix/store).
    storeDir: []const u8,

    /// The location of the store filesystem (must be erofs).
    storeFS: []const u8,

    /// The path to the /usr hierarchy in the store.
    usr: []const u8,

    /// The path to the /etc hierarchy in the store.
    etc: []const u8,

    boot: BootConfig,

    state: ?StateConfig,
};

inline fn firstAvailableLoopDevice(allocator: std.mem.Allocator) ![]const u8 {
    const loop_control = try std.fs.cwd().openFile("/dev/loop-control", .{ .mode = .read_write });
    defer loop_control.close();

    const loop_nr = system.ioctl(loop_control.handle, LOOP_CTL_GET_FREE, 0);

    // TODO(jared): enumerate all possible errors
    switch (system.E.init(loop_nr)) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to get next free loopback number: {s}", .{@tagName(err)});
            return posix.unexpectedErrno(err);
        },
    }

    return try std.fmt.allocPrintSentinel(allocator, "/dev/loop{}", .{@as(usize, loop_nr)}, 0);
}

fn ftruncate(fd: posix.fd_t, length: i64) !void {
    switch (system.E.init(system.ftruncate(fd, length))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn sendfile(outfd: posix.fd_t, infd: posix.fd_t, offset: ?*i64, count: u64) !usize {
    const ret = system.sendfile(outfd, infd, offset, @intCast(count));
    switch (system.E.init(ret)) {
        .SUCCESS => return ret,
        else => |err| return posix.unexpectedErrno(err),
    }
}

inline fn createStoreLoopback(allocator: std.mem.Allocator, store_fd: posix.fd_t, store_fs_source: []const u8) ![]const u8 {
    const store_fs = try std.fs.cwd().openFile(store_fs_source, .{});
    defer store_fs.close();
    const store_stat = try store_fs.stat();

    try ftruncate(store_fd, @intCast(store_stat.size));
    _ = try sendfile(store_fd, store_fs.handle, null, store_stat.size);
    if (system.fcntl(
        store_fd,
        C.F_ADD_SEALS,
        C.F_SEAL_SEAL | C.F_SEAL_SHRINK | C.F_SEAL_GROW | C.F_SEAL_WRITE,
    ) != 0) {
        log.warn("failed to add seals to store", .{});
    }

    const loop_device_path = try firstAvailableLoopDevice(allocator);
    log.debug("using loopback device {s}", .{loop_device_path});

    const loop_device = try std.fs.cwd().openFile(loop_device_path, .{ .mode = .read_write });
    defer loop_device.close();

    // We cannot use the fancy erofs feature that allows for skipping loopback device creation, since our erofs
    // https://github.com/gregkh/linux/blob/f2b09e8b594ce61b8ff508ea1fb594b3b24ec6d3/fs/erofs/super.c#L798-L799
    // TODO(jared): enumerate all possible errors
    switch (system.E.init(system.ioctl(loop_device.handle, LOOP_SET_FD, @intCast(store_fd)))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to set backing file on loopback device: {s}", .{@tagName(err)});
            return posix.unexpectedErrno(err);
        },
    }

    return loop_device_path;
}

fn mountStore(
    allocator: std.mem.Allocator,
    store_blockdev: []const u8,
    mount_dir: std.fs.Dir,
    store_dir: []const u8,
) !void {
    const store_dir_relative = std.mem.trimStart(u8, store_dir, std.fs.path.sep_str);
    try mount_dir.makePath(store_dir_relative);

    var store = try Mount.init("erofs");
    try store.setSource(store_blockdev);
    try store.setOption("ro", null);
    try store.finish(
        mount_dir,
        try allocator.dupeZ(u8, store_dir_relative),
        Mount.Options.RDONLY | Mount.Options.NODEV | Mount.Options.NOSUID,
    );
}

/// Save memory by removing all initramfs content, excluding sysroot, which we
/// will switch to eventually.
fn removeAllContent(dir: std.fs.Dir, directory: []const u8, new_root: std.fs.Dir) void {
    var old_root = dir.openDir(directory, .{ .iterate = true }) catch return;
    defer old_root.close();

    var old_root_stat: system.Stat = undefined;
    switch (system.E.init(system.fstat(old_root.fd, &old_root_stat))) {
        .SUCCESS => {},
        else => return,
    }

    var new_root_stat: system.Stat = undefined;
    switch (system.E.init(system.fstat(new_root.fd, &new_root_stat))) {
        .SUCCESS => {},
        else => return,
    }

    var iter = old_root.iterate();
    while (iter.next() catch return) |entry| {
        var entry_stat: system.Stat = undefined;
        switch (system.E.init(system.fstatat(
            old_root.fd,
            entry.name[0..entry.name.len :0],
            &entry_stat,
            0,
        ))) {
            .SUCCESS => {},
            else => |err| {
                log.warn("failed to stat entry {s}: {}", .{ entry.name, err });
                continue;
            },
        }

        // If the entry is on the new root filesystem, skip it.
        if (entry_stat.dev == new_root_stat.dev) {
            continue;
        }

        old_root.deleteTree(entry.name) catch |err| {
            log.warn("failed to delete {s}: {}", .{ entry.name, err });
            continue;
        };
    }
}

/// Returns a handle to the new root directory.
inline fn switchRoot(root_dir: std.fs.Dir) !void {
    try root_dir.makePath("sysroot");

    var tmpfs = try Mount.init("tmpfs");
    try tmpfs.finish(root_dir, "sysroot", Mount.Options.NODEV | Mount.Options.NOSUID);

    var sysroot_dir = try root_dir.openDir("sysroot", .{});
    defer sysroot_dir.close();

    // TODO(jared): enumerate all possible errors
    switch (system.E.init(system.fchdir(sysroot_dir.fd))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to change directory to /sysroot: {s}", .{@tagName(err)});
            return posix.unexpectedErrno(err);
        },
    }

    // Create directories that do not yet exist
    inline for (&.{ "dev", "sys", "proc" }) |path| {
        try sysroot_dir.makePath(path);
    }

    // move pseudofilesystems into final root filesystem
    try Mount.move_mount(root_dir.fd, "dev", sysroot_dir.fd, "dev", 0);
    try Mount.move_mount(root_dir.fd, "sys", sysroot_dir.fd, "sys", 0);
    try Mount.move_mount(root_dir.fd, "proc", sysroot_dir.fd, "proc", 0);

    log.debug("removing remnants of initramfs", .{});
    removeAllContent(std.fs.cwd(), "/", sysroot_dir);

    // overmount current root
    try Mount.move_mount(sysroot_dir.fd, ".", root_dir.fd, "/", 0);

    // TODO(jared): enumerate all possible errors
    switch (system.E.init(system.chroot("."))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to chroot: {s}", .{@tagName(err)});
            return posix.unexpectedErrno(err);
        },
    }

    // TODO(jared): enumerate all possible errors
    switch (system.E.init(system.chdir("/"))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to change directory to /: {s}", .{@tagName(err)});
            return posix.unexpectedErrno(err);
        },
    }
}

inline fn setupRoot(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    manifest: *const Manifest,
    store_blockdev: []const u8,
) !void {
    // Create directories that do not yet exist
    inline for (&.{ "usr", "etc", "run", "tmp", "var", "root", "home" }) |path| {
        try root_dir.makePath(path);
    }

    try mountStore(allocator, store_blockdev, std.fs.cwd(), manifest.storeDir);

    var usr = try Mount.initTree(std.fs.cwd(), manifest.usr);
    try usr.finish(root_dir, "usr", 0);

    // setup usr-merge
    root_dir.symLink("usr/bin", "/bin", .{ .is_directory = true }) catch {};
    root_dir.symLink("usr/sbin", "/sbin", .{ .is_directory = true }) catch {};
    root_dir.symLink("usr/lib", "/lib", .{ .is_directory = true }) catch {};
}

/// By the point this runs, we already have /sys, /dev, and /proc mounted.
fn mountPseudoFilesystems(kernel: *const KernelConfig) void {
    if (kernel.UNIX98_PTYS) b: {
        std.fs.cwd().makeDir("/dev/pts") catch break :b;
        var mnt = Mount.init("devpts") catch break :b;
        mnt.finish(
            std.fs.cwd(),
            "/dev/pts",
            Mount.Options.NOSUID | Mount.Options.NOEXEC,
        ) catch break :b;
    }

    if (kernel.CONFIGFS_FS) b: {
        Mount.mount(
            "configfs",
            "/sys/kernel/config",
            "configfs",
            system.MS.NOEXEC | system.MS.NOSUID | system.MS.NODEV,
            0,
        ) catch break :b;
    }

    if (kernel.DEBUG_FS_ALLOW_ALL) b: {
        Mount.mount(
            "debugfs",
            "/sys/kernel/debug",
            "debugfs",
            system.MS.NOEXEC | system.MS.NOSUID | system.MS.NODEV,
            0,
        ) catch break :b;
    }

    if (kernel.FTRACE) b: {
        Mount.mount(
            "tracefs",
            "/sys/kernel/tracing",
            "tracefs",
            system.MS.NOSUID | system.MS.NODEV | system.MS.NOEXEC | system.MS.RELATIME,
            0,
        ) catch break :b;
    }

    // /sys/kernel/security directory only exists if both these KConfig options are enabled, see https://github.com/torvalds/linux/blob/c612261bedd6bbab7109f798715e449c9d20ff2f/security/inode.c#L366
    if (kernel.SECURITY and kernel.SECURITYFS) b: {
        Mount.mount(
            "securityfs",
            "/sys/kernel/security",
            "securityfs",
            system.MS.NOSUID | system.MS.NODEV | system.MS.NOEXEC | system.MS.RELATIME,
            0,
        ) catch break :b;
    }

    if (kernel.CGROUPS) b: {
        var mnt = Mount.init("cgroup2") catch break :b;
        mnt.finish(
            std.fs.cwd(),
            "/sys/fs/cgroup",
            Mount.Options.NOEXEC | Mount.Options.NOSUID | Mount.Options.NODEV,
        ) catch break :b;
    }

    if (kernel.SHMEM) b: {
        std.fs.cwd().makeDir("/dev/shm") catch break :b;
        var mnt = Mount.init("tmpfs") catch break :b;
        mnt.finish(std.fs.cwd(), "/dev/shm", Mount.Options.NOSUID | Mount.Options.NODEV) catch break :b;
    }
}

/// We need to have certain files exposed prior to loading kernel modules and
/// running mdev (since kmod and mdev have optional configuration files), so we
/// mount our etc hierarchy ahead of time here.
inline fn premountEtc(lower_etc: []const u8) !void {
    var etc = try Mount.initTree(std.fs.cwd(), lower_etc);
    try etc.finish(std.fs.cwd(), "/etc", 0);
}

/// Load all kernel modules declared in the MixOS configuration.
inline fn loadModules(allocator: std.mem.Allocator, boot: *const BootConfig) !void {
    if (!boot.kernel.MODULES) {
        return;
    }

    var kmod = try Kmod.init(allocator);
    defer kmod.deinit();

    for (boot.kernelModules) |module| {
        kmod.modprobe(module) catch |err| {
            log.err("failed to load module {s}: {}", .{ module, err });
        };
    }
}

inline fn mdevScan(allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(&.{ "mdev", "-s", "-f" }, allocator);
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }

    log.err("mdev failed with exit: {}", .{term});
}

const IndentedWriter = struct {
    start: bool = true,
    indent_size: usize,
    inner: std.Io.Writer.Allocating,
    writer: std.Io.Writer,

    fn init(allocator: std.mem.Allocator, indent_size: usize) @This() {
        return .{
            .indent_size = indent_size,
            .inner = .init(allocator),
            .writer = .{
                .buffer = &.{},
                .vtable = &vtable,
            },
        };
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = &drain,
        .flush = std.Io.Writer.noopFlush,
        .rebase = &rebase,
    };

    fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        const self: *@This() = @fieldParentPtr("writer", w);
        return self.inner.writer.rebase(preserve, capacity);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, len: usize) std.Io.Writer.Error!usize {
        _ = len;

        const self: *@This() = @fieldParentPtr("writer", w);

        var n: usize = 0;
        for (data) |bytes| {
            if (self.start) {
                try self.inner.writer.splatByteAll(' ', self.indent_size);
                n += self.indent_size;
                self.start = false;
            }

            if (std.mem.indexOfScalar(u8, bytes, '\n')) |_| {
                var split = std.mem.splitScalar(u8, bytes, '\n');
                while (split.next()) |line| {
                    try self.inner.writer.writeAll(line);
                    n += line.len;
                    try self.inner.writer.writeByte('\n');
                    n += 1;
                    try self.inner.writer.splatByteAll(' ', self.indent_size);
                    n += self.indent_size;
                }
            } else {
                try self.inner.writer.writeAll(bytes);
                n += bytes.len;
            }
        }

        return n;
    }

    fn deinit(self: *@This()) void {
        self.inner.deinit();
    }

    fn written(self: *@This()) []u8 {
        return self.inner.written();
    }
};

inline fn initState(allocator: std.mem.Allocator, state: *const StateConfig) !void {
    b: {
        if (state.init) |init| {
            var output: IndentedWriter = .init(allocator, 2);
            defer output.deinit();

            const term = process.run(allocator, &.{init}, .{
                .stdout_writer = &output.writer,
                .stderr_writer = &output.writer,
            }) catch |err| {
                log.err("failed to run state initialization: {}", .{err});
                return error.StateInit;
            };

            log.info("state initialization:\n{s}", .{std.mem.trimEnd(
                u8,
                output.written(),
                &std.ascii.whitespace,
            )});

            switch (term) {
                .Exited => |exit_code| switch (exit_code) {
                    0 => break :b,
                    else => {},
                },
                else => {},
            }

            log.err("state initialization failed: {}", .{term});
            return error.StateInit;
        }
    }

    const fstype = try allocator.dupeZ(u8, state.fsType);
    defer allocator.free(fstype);

    log.debug("mounting state of fstype {s}", .{state.fsType});

    var state_mount = try Mount.init(fstype);
    try state_mount.setSource(state.source);

    for (state.options) |option| {
        var split = std.mem.splitScalar(u8, option, '=');
        const key = split.next() orelse continue;
        const value = split.next();
        state_mount.setOption(key, value) catch |err| {
            log.warn("failed to set mount option '{s}' for state: {}", .{ option, err });
        };
    }

    try std.fs.cwd().makePath("/state");
    try state_mount.finish(std.fs.cwd(), "/state", 0);
}

inline fn setupState(root_dir: std.fs.Dir, lower_etc: []const u8) !void {
    var state_dir = try root_dir.makeOpenPath("state", .{});
    defer state_dir.close();

    // Ensure /var, /root, and /home persists data back to /state
    inline for ([_][]const u8{ "var", "root", "home" }) |dir_name| {
        b: {
            state_dir.makePath(dir_name) catch |err| {
                log.err("failed to create /state/{s} mount source: {}", .{ dir_name, err });
                break :b;
            };
            var mount = Mount.initTree(state_dir, dir_name) catch |err| {
                log.err("failed to open mount tree from /state/{s}: {}", .{ dir_name, err });
                break :b;
            };
            mount.finish(root_dir, dir_name[0..dir_name.len :0], 0) catch |err| {
                log.err("failed to move mount for /{s}: {}", .{ dir_name, err });
                break :b;
            };
        }
    }

    var var_dir = root_dir.openDir("var", .{});
    if (var_dir) |*dir| {
        defer dir.close();

        // Create /var/empty, useful in many contexts
        dir.makePath("empty") catch |err| {
            log.err("failed to create /var/empty: {}", .{err});
        };

        // Symlink /var/run to /run, which is a common symlink that is expected to
        // exist by many tools. We cannot do this at build time since var is tied
        // to /state, which is mounted at runtime.
        dir.symLink("../run", "run", .{ .is_directory = true }) catch |err| {
            log.err("failed to symlink /var/run to /run: {}", .{err});
        };

        // Ensure basic state directories exist
        {
            dir.makePath("log") catch |err| {
                log.err("failed to create /var/log: {}", .{err});
            };

            dir.makePath("spool/cron/crontabs") catch |err| {
                log.err("failed to create /var/spool/cron/crontabs: {}", .{err});
            };
        }
    } else |err| {
        log.err("failed to open /var: {}", .{err});
    }

    // Ensure /etc is writeable, needed by various programs.
    try std.fs.cwd().makePath("/state/etc/upper");
    try std.fs.cwd().makePath("/state/etc/work");

    try Mount.umount("/etc");
    var etc_overlay = try Mount.init("overlay");
    try etc_overlay.setOption("lowerdir", lower_etc);
    try etc_overlay.setOption("upperdir", "/state/etc/upper");
    try etc_overlay.setOption("workdir", "/state/etc/work");
    try etc_overlay.finish(
        root_dir,
        "etc",
        Mount.Options.NODEV | Mount.Options.NOSUID | Mount.Options.NOEXEC,
    );

    var etc_dir = try root_dir.openDir("etc", .{});
    defer etc_dir.close();

    // Many pieces of software want to consume /etc/mtab. Systemd (via
    // tmpfiles) symlinks it to /proc/self/mounts
    etc_dir.symLink("../proc/self/mounts", "mtab", .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => log.warn("failed to setup /etc/mtab: {}", .{err}),
    };
}

fn sethostname(hostname: []const u8) usize {
    return system.syscall2(.sethostname, @intFromPtr(hostname.ptr), hostname.len);
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

test extractHostname {
    try std.testing.expectEqual(null, extractHostname("# foo"));
    try std.testing.expectEqual(null, extractHostname(" # foo"));
    try std.testing.expectEqual(null, extractHostname(""));
    try std.testing.expectEqualStrings("foo", extractHostname(" foo ") orelse unreachable);
    try std.testing.expectEqualStrings("foo", extractHostname("foo") orelse unreachable);
    try std.testing.expectEqualStrings("foo", extractHostname("# some comment\nfoo") orelse unreachable);
}

// /etc/hostname is described as a single-line, newline-terminated file
// containing the hostname of the system, see hostname(5).
inline fn setupHostname(allocator: std.mem.Allocator) !void {
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
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

inline fn setupNetworking(kernel: *const KernelConfig) !void {
    if (!kernel.UNIX) {
        return;
    }

    // TODO(jared): netlink is nicer
    const fd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.IP,
    );
    defer posix.close(fd);

    {
        var ifr = std.mem.zeroes(system.ifreq);
        std.mem.copyForwards(u8, &ifr.ifrn.name, "lo");
        switch (system.E.init(system.ioctl(
            fd,
            system.SIOCGIFFLAGS,
            @intFromPtr(&ifr),
        ))) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }

        ifr.ifru.flags.UP = true;

        switch (system.E.init(system.ioctl(
            fd,
            system.SIOCSIFFLAGS,
            @intFromPtr(&ifr),
        ))) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

// TODO(jared): enumerate all possible errors
fn memfd_create(name: [*:0]const u8, flags: u32) !posix.fd_t {
    const ret = system.memfd_create(name, flags);
    switch (system.E.init(ret)) {
        .SUCCESS => return @intCast(ret),
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn setupWatchdog(watchdog: *const WatchdogConfig) !?Watchdog {
    _ = watchdog;

    return Watchdog.init() catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

fn setupSystem(init_allocator: std.mem.Allocator) ![*:0]const u8 {
    // We create this memfd object as early as possible, mostly so we get the
    // vanity of having a low file descriptor number.
    //
    // NOTE: We don't close the store_fd, since that would deallocate the memfd
    const store_fd = try memfd_create("store", system.MFD.ALLOW_SEALING);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var manifest: Manifest = undefined;
    var store_blockdev: []const u8 = undefined;

    // pre switch-root
    {
        var root_dir = try std.fs.cwd().openDir("/", .{});
        defer root_dir.close();

        inline for (&.{ "dev", "sys", "proc" }) |path| {
            try root_dir.makePath(path);
        }
        var devtmpfs = try Mount.init("devtmpfs");
        try devtmpfs.finish(root_dir, "dev", Mount.Options.NOEXEC | Mount.Options.NOSUID);
        var sysfs = try Mount.init("sysfs");
        try sysfs.finish(root_dir, "sys", Mount.Options.NOEXEC | Mount.Options.NOSUID);
        var proc = try Mount.init("proc");
        try proc.finish(root_dir, "proc", Mount.Options.NOEXEC | Mount.Options.NOSUID | Mount.Options.NODEV);

        // We must wait until now to setup the /dev/kmsg logger, since /dev is not
        // mounted until right before this.
        kmsg.init();

        const manifest_json = try root_dir.openFile("manifest.json", .{});
        defer manifest_json.close();

        const manifest_json_contents = try manifest_json.readToEndAlloc(allocator, std.math.maxInt(usize));
        const manifest_ = try std.json.parseFromSlice(Manifest, allocator, manifest_json_contents, .{});

        manifest = manifest_.value;

        store_blockdev = try createStoreLoopback(allocator, store_fd, manifest.storeFS);

        try switchRoot(root_dir);
    }

    var root_dir = try std.fs.cwd().openDir("/", .{});
    defer root_dir.close();

    defer kmsg.deinit();

    var watchdog = if (manifest.boot.watchdog) |*w| try setupWatchdog(w) else null;
    errdefer if (watchdog) |*w| w.deinit();

    try setupRoot(allocator, root_dir, &manifest, store_blockdev);

    mountPseudoFilesystems(&manifest.boot.kernel);

    premountEtc(manifest.etc) catch |err| {
        log.err("failed to pre-mount /etc: {}", .{err});
    };

    loadModules(allocator, &manifest.boot) catch |err| {
        log.err("failed to load modules: {}", .{err});
    };

    mdevScan(allocator) catch |err| {
        log.err("failed to run mdev: {}", .{err});
    };

    if (manifest.state) |state| try initState(allocator, &state);

    try setupState(root_dir, manifest.etc);

    setupHostname(allocator) catch |err| {
        log.err("failed to set hostname: {}", .{err});
    };

    setupNetworking(&manifest.boot.kernel) catch |err| {
        log.err("failed to setup networking: {}", .{err});
    };

    log.debug("executing init {s}", .{manifest.init});

    if (watchdog) |*w| w.disarm();

    return try init_allocator.dupeZ(u8, manifest.init);
}

pub fn main(name: []const u8, args: *std.process.ArgIterator) anyerror!void {
    _ = name;
    _ = args;

    if (system.getpid() != 1) {
        log.err("not running as PID1, refusing to continue", .{});
        @panic("PANIC");
    }

    var fba_buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

    const init = setupSystem(fba.allocator()) catch |err| {
        std.log.err("system setup failed: {}\n", .{err});

        var futex = std.atomic.Value(u32).init(0);
        while (true) std.Thread.Futex.wait(&futex, 0);
    };

    const argv_buf = try fba.allocator().allocSentinel(?[*:0]const u8, 1, null);
    argv_buf[0] = init;

    comptime std.debug.assert(builtin.link_libc);
    const err = posix.execvpeZ_expandArg0(
        .no_expand,
        argv_buf.ptr[0].?,
        argv_buf.ptr,
        std.c.environ,
    );
    log.err("execv PID1 failed: {}", .{err});
    @panic("PANIC");
}
