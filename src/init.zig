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

inline fn firstAvailableLoopDevice(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const loop_control = try std.Io.Dir.cwd().openFile(io, "/dev/loop-control", .{ .mode = .read_write });
    defer loop_control.close(io);

    const loop_nr = system.ioctl(loop_control.handle, LOOP_CTL_GET_FREE, 0);

    // TODO(jared): enumerate all possible errors
    switch (system.errno(loop_nr)) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to get next free loopback number: {s}", .{@tagName(err)});
            return posix.unexpectedErrno(err);
        },
    }

    return try std.fmt.allocPrintSentinel(allocator, "/dev/loop{}", .{@as(usize, loop_nr)}, 0);
}

fn ftruncate(fd: posix.fd_t, length: i64) !void {
    switch (system.errno(system.ftruncate(fd, length))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn sendfile(outfd: posix.fd_t, infd: posix.fd_t, offset: ?*i64, count: u64) !usize {
    const ret = system.sendfile(outfd, infd, offset, @intCast(count));
    switch (system.errno(ret)) {
        .SUCCESS => return ret,
        else => |err| return posix.unexpectedErrno(err),
    }
}

inline fn createStoreLoopback(io: std.Io, allocator: std.mem.Allocator, store_fd: posix.fd_t, store_fs_source: []const u8) ![]const u8 {
    const store_fs = try std.Io.Dir.cwd().openFile(io, store_fs_source, .{});
    defer store_fs.close(io);
    const store_stat = try store_fs.stat(io);

    try ftruncate(store_fd, @intCast(store_stat.size));
    _ = try sendfile(store_fd, store_fs.handle, null, store_stat.size);
    if (system.fcntl(
        store_fd,
        C.F_ADD_SEALS,
        C.F_SEAL_SEAL | C.F_SEAL_SHRINK | C.F_SEAL_GROW | C.F_SEAL_WRITE,
    ) != 0) {
        log.warn("failed to add seals to store", .{});
    }

    const loop_device_path = try firstAvailableLoopDevice(io, allocator);
    log.debug("using loopback device {s}", .{loop_device_path});

    const loop_device = try std.Io.Dir.cwd().openFile(io, loop_device_path, .{ .mode = .read_write });
    defer loop_device.close(io);

    // We cannot use the fancy erofs feature that allows for skipping loopback device creation, since our erofs
    // https://github.com/gregkh/linux/blob/f2b09e8b594ce61b8ff508ea1fb594b3b24ec6d3/fs/erofs/super.c#L798-L799
    // TODO(jared): enumerate all possible errors
    switch (system.errno(system.ioctl(loop_device.handle, LOOP_SET_FD, @intCast(store_fd)))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to set backing file on loopback device: {s}", .{@tagName(err)});
            return posix.unexpectedErrno(err);
        },
    }

    return loop_device_path;
}

fn mountStore(
    io: std.Io,
    allocator: std.mem.Allocator,
    store_blockdev: []const u8,
    mount_dir: std.Io.Dir,
    store_dir: []const u8,
) !void {
    const store_dir_relative = std.mem.trimStart(u8, store_dir, std.fs.path.sep_str);
    try mount_dir.createDirPath(io, store_dir_relative);

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
fn removeAllContent(io: std.Io, dir: std.Io.Dir, directory: []const u8, new_root: std.Io.Dir) void {
    var old_root = dir.openDir(io, directory, .{ .iterate = true }) catch return;
    defer old_root.close(io);

    var new_root_statx = std.mem.zeroes(system.Statx);
    switch (system.errno(system.statx(
        new_root.handle,
        ".",
        0,
        std.Io.Threaded.linux_statx_request,
        &new_root_statx,
    ))) {
        .SUCCESS => {},
        else => |err| {
            log.err("stat on new root failed: {}", .{err});
            return;
        },
    }

    var iter = old_root.iterate();
    while (iter.next(io) catch return) |entry| {
        var entry_statx = std.mem.zeroes(system.Statx);
        switch (system.errno(system.statx(
            old_root.handle,
            entry.name[0..entry.name.len :0],
            0,
            std.Io.Threaded.linux_statx_request,
            &entry_statx,
        ))) {
            .SUCCESS => {},
            else => |err| {
                log.warn("failed to stat entry {s}: {}", .{ entry.name, err });
                continue;
            },
        }

        // If the entry is on the new root filesystem, skip it.
        if (entry_statx.dev_major == new_root_statx.dev_major and
            entry_statx.dev_minor == new_root_statx.dev_minor)
        {
            continue;
        }

        old_root.deleteTree(io, entry.name) catch |err| {
            log.warn("failed to delete {s}: {}", .{ entry.name, err });
            continue;
        };
    }
}

/// Returns a handle to the new root directory.
inline fn switchRoot(io: std.Io, root_dir: std.Io.Dir) !void {
    try root_dir.createDirPath(io, "sysroot");

    var tmpfs = try Mount.init("tmpfs");
    try tmpfs.finish(root_dir, "sysroot", Mount.Options.NODEV | Mount.Options.NOSUID);

    var sysroot_dir = try root_dir.openDir(io, "sysroot", .{});
    defer sysroot_dir.close(io);

    // TODO(jared): enumerate all possible errors
    switch (system.errno(system.fchdir(sysroot_dir.handle))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to change directory to /sysroot: {s}", .{@tagName(err)});
            return posix.unexpectedErrno(err);
        },
    }

    // Create directories that do not yet exist
    inline for (&.{ "dev", "sys", "proc" }) |path| {
        try sysroot_dir.createDirPath(io, path);
    }

    // move pseudofilesystems into final root filesystem
    try Mount.move_mount(root_dir.handle, "dev", sysroot_dir.handle, "dev", 0);
    try Mount.move_mount(root_dir.handle, "sys", sysroot_dir.handle, "sys", 0);
    try Mount.move_mount(root_dir.handle, "proc", sysroot_dir.handle, "proc", 0);

    log.debug("removing remnants of initramfs", .{});
    removeAllContent(io, std.Io.Dir.cwd(), "/", sysroot_dir);

    // overmount current root
    try Mount.move_mount(sysroot_dir.handle, ".", root_dir.handle, "/", 0);

    // TODO(jared): enumerate all possible errors
    switch (system.errno(system.chroot("."))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to chroot: {s}", .{@tagName(err)});
            return posix.unexpectedErrno(err);
        },
    }

    // TODO(jared): enumerate all possible errors
    switch (system.errno(system.chdir("/"))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to change directory to /: {s}", .{@tagName(err)});
            return posix.unexpectedErrno(err);
        },
    }
}

inline fn setupRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    manifest: *const Manifest,
    store_blockdev: []const u8,
) !void {
    // Create directories that do not yet exist
    inline for (&.{ "usr", "etc", "run", "tmp", "var", "root", "home" }) |path| {
        try root_dir.createDirPath(io, path);
    }

    try mountStore(io, allocator, store_blockdev, std.Io.Dir.cwd(), manifest.storeDir);

    var usr = try Mount.initTree(std.Io.Dir.cwd(), manifest.usr);
    try usr.finish(root_dir, "usr", 0);

    // setup usr-merge
    root_dir.symLink(io, "usr/bin", "/bin", .{ .is_directory = true }) catch {};
    root_dir.symLink(io, "usr/sbin", "/sbin", .{ .is_directory = true }) catch {};
    root_dir.symLink(io, "usr/lib", "/lib", .{ .is_directory = true }) catch {};
}

/// By the point this runs, we already have /sys, /dev, and /proc mounted.
fn mountPseudoFilesystems(io: std.Io, kernel: *const KernelConfig) void {
    if (kernel.UNIX98_PTYS) b: {
        std.Io.Dir.cwd().createDirPath(io, "/dev/pts") catch break :b;
        var mnt = Mount.init("devpts") catch break :b;
        mnt.finish(
            std.Io.Dir.cwd(),
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
            std.Io.Dir.cwd(),
            "/sys/fs/cgroup",
            Mount.Options.NOEXEC | Mount.Options.NOSUID | Mount.Options.NODEV,
        ) catch break :b;
    }

    if (kernel.SHMEM) b: {
        std.Io.Dir.cwd().createDirPath(io, "/dev/shm") catch break :b;
        var mnt = Mount.init("tmpfs") catch break :b;
        mnt.finish(std.Io.Dir.cwd(), "/dev/shm", Mount.Options.NOSUID | Mount.Options.NODEV) catch break :b;
    }
}

/// We need to have certain files exposed prior to loading kernel modules and
/// running mdev (since kmod and mdev have optional configuration files), so we
/// mount our etc hierarchy ahead of time here.
inline fn premountEtc(lower_etc: []const u8) !void {
    var etc = try Mount.initTree(std.Io.Dir.cwd(), lower_etc);
    try etc.finish(std.Io.Dir.cwd(), "/etc", 0);
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

inline fn mdevScan(io: std.Io, allocator: std.mem.Allocator) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "mdev", "-s", "-f" },
    });
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }

    log.err("mdev failed with exit: {}", .{result.term});
}

const IndentedWriter = struct {
    start: bool = true,
    indentation: usize,
    inner: std.Io.Writer.Allocating,
    writer: std.Io.Writer,

    fn init(allocator: std.mem.Allocator, opts: struct { indentation: usize }) @This() {
        return .{
            .indentation = opts.indentation,
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
                try self.inner.writer.splatByteAll(' ', self.indentation);
                n += self.indentation;
                self.start = false;
            }

            if (std.mem.indexOfScalar(u8, bytes, '\n')) |_| {
                var split = std.mem.splitScalar(u8, bytes, '\n');
                while (split.next()) |line| {
                    try self.inner.writer.writeAll(line);
                    n += line.len;
                    try self.inner.writer.writeByte('\n');
                    n += 1;
                    try self.inner.writer.splatByteAll(' ', self.indentation);
                    n += self.indentation;
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

inline fn initState(io: std.Io, allocator: std.mem.Allocator, state: *const StateConfig) !void {
    b: {
        if (state.init) |init| {
            var output: IndentedWriter = .init(allocator, .{ .indentation = 2 });
            defer output.deinit();

            const term = process.run(
                io,
                allocator,
                &.{init},
                .{
                    .stdout_writer = &output.writer,
                    .stderr_writer = &output.writer,
                },
            ) catch |err| {
                log.err("failed to run state initialization: {}", .{err});
                return error.StateInit;
            };

            log.info("state initialization:\n{s}", .{std.mem.trimEnd(
                u8,
                output.written(),
                &std.ascii.whitespace,
            )});

            switch (term) {
                .exited => |exit_code| switch (exit_code) {
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

    try std.Io.Dir.cwd().createDirPath(io, "/state");
    try state_mount.finish(std.Io.Dir.cwd(), "/state", 0);
}

inline fn setupState(io: std.Io, root_dir: std.Io.Dir, lower_etc: []const u8) !void {
    var state_dir = try root_dir.createDirPathOpen(io, "state", .{});
    defer state_dir.close(io);

    // Ensure /var, /root, and /home persists data back to /state
    inline for ([_][]const u8{ "var", "root", "home" }) |dir_name| {
        b: {
            state_dir.createDirPath(io, dir_name) catch |err| {
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

    var var_dir = root_dir.openDir(io, "var", .{});
    if (var_dir) |*dir| {
        defer dir.close(io);

        // Create /var/empty, useful in many contexts
        dir.createDirPath(io, "empty") catch |err| {
            log.err("failed to create /var/empty: {}", .{err});
        };

        // Symlink /var/run to /run, which is a common symlink that is expected to
        // exist by many tools. We cannot do this at build time since var is tied
        // to /state, which is mounted at runtime.
        dir.symLink(io, "../run", "run", .{ .is_directory = true }) catch |err| {
            log.err("failed to symlink /var/run to /run: {}", .{err});
        };

        // Ensure basic state directories exist
        {
            dir.createDirPath(io, "log") catch |err| {
                log.err("failed to create /var/log: {}", .{err});
            };

            dir.createDirPath(io, "spool/cron/crontabs") catch |err| {
                log.err("failed to create /var/spool/cron/crontabs: {}", .{err});
            };
        }
    } else |err| {
        log.err("failed to open /var: {}", .{err});
    }

    // Ensure /etc is writeable, needed by various programs.
    try std.Io.Dir.cwd().createDirPath(io, "/state/etc/upper");
    try std.Io.Dir.cwd().createDirPath(io, "/state/etc/work");

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

    var etc_dir = try root_dir.openDir(io, "etc", .{});
    defer etc_dir.close(io);

    // Many pieces of software want to consume /etc/mtab. Systemd (via
    // tmpfiles) symlinks it to /proc/self/mounts
    etc_dir.symLink(io, "../proc/self/mounts", "mtab", .{}) catch |err| switch (err) {
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
inline fn setupHostname(io: std.Io, allocator: std.mem.Allocator) !void {
    const hostname_file = std.Io.Dir.cwd().openFile(io, "/etc/hostname", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer hostname_file.close(io);

    var hostname_reader = hostname_file.reader(io, &.{});
    const hostname_contents = try hostname_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(hostname_contents);

    if (extractHostname(hostname_contents)) |hostname| {
        switch (system.errno(sethostname(hostname))) {
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
    const fd: posix.fd_t = @intCast(system.socket(
        system.AF.INET,
        system.SOCK.DGRAM,
        system.IPPROTO.IP,
    ));
    defer _ = system.close(fd);

    {
        var ifr = std.mem.zeroes(system.ifreq);
        std.mem.copyForwards(u8, &ifr.ifrn.name, "lo");
        switch (system.errno(system.ioctl(
            fd,
            system.SIOCGIFFLAGS,
            @intFromPtr(&ifr),
        ))) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }

        ifr.ifru.flags.UP = true;

        switch (system.errno(system.ioctl(
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
    switch (system.errno(ret)) {
        .SUCCESS => return @intCast(ret),
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn setupWatchdog(io: std.Io, watchdog: *const WatchdogConfig) !?Watchdog {
    _ = watchdog;

    return Watchdog.init(io) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

fn setupSystem(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    stage2_init_allocator: std.mem.Allocator,
) ![*:0]const u8 {
    // We create this memfd object as early as possible, mostly so we get the
    // vanity of having a low file descriptor number.
    //
    // NOTE: We don't close the store_fd, since that would deallocate the memfd
    const store_fd = try memfd_create("store", system.MFD.ALLOW_SEALING);

    const allocator = arena.allocator();

    var manifest: Manifest = undefined;
    var store_blockdev: []const u8 = undefined;

    // pre switch-root
    {
        var root_dir = try std.Io.Dir.cwd().openDir(io, "/", .{});
        defer root_dir.close(io);

        inline for (&.{ "dev", "sys", "proc" }) |path| {
            try root_dir.createDirPath(io, path);
        }
        var devtmpfs = try Mount.init("devtmpfs");
        try devtmpfs.finish(root_dir, "dev", Mount.Options.NOEXEC | Mount.Options.NOSUID);
        var sysfs = try Mount.init("sysfs");
        try sysfs.finish(root_dir, "sys", Mount.Options.NOEXEC | Mount.Options.NOSUID);
        var proc = try Mount.init("proc");
        try proc.finish(root_dir, "proc", Mount.Options.NOEXEC | Mount.Options.NOSUID | Mount.Options.NODEV);

        // We must wait until now to setup the /dev/kmsg logger, since /dev is not
        // mounted until right before this.
        kmsg.init(io);

        const manifest_json = try root_dir.openFile(io, "manifest.json", .{});
        defer manifest_json.close(io);

        var manifest_json_reader = manifest_json.reader(io, &.{});
        const manifest_json_contents = try manifest_json_reader.interface.allocRemaining(allocator, .unlimited);
        const manifest_ = try std.json.parseFromSlice(Manifest, allocator, manifest_json_contents, .{});

        manifest = manifest_.value;

        store_blockdev = try createStoreLoopback(io, allocator, store_fd, manifest.storeFS);

        try switchRoot(io, root_dir);
    }

    var root_dir = try std.Io.Dir.cwd().openDir(io, "/", .{});
    defer root_dir.close(io);

    defer kmsg.deinit(io);

    var watchdog = if (manifest.boot.watchdog) |*w| try setupWatchdog(io, w) else null;
    errdefer if (watchdog) |*w| w.deinit();

    try setupRoot(io, allocator, root_dir, &manifest, store_blockdev);

    mountPseudoFilesystems(io, &manifest.boot.kernel);

    premountEtc(manifest.etc) catch |err| {
        log.err("failed to pre-mount /etc: {}", .{err});
    };

    loadModules(allocator, &manifest.boot) catch |err| {
        log.err("failed to load modules: {}", .{err});
    };

    mdevScan(io, allocator) catch |err| {
        log.err("failed to run mdev: {}", .{err});
    };

    if (manifest.state) |state| try initState(io, allocator, &state);

    try setupState(io, root_dir, manifest.etc);

    setupHostname(io, allocator) catch |err| {
        log.err("failed to set hostname: {}", .{err});
    };

    setupNetworking(&manifest.boot.kernel) catch |err| {
        log.err("failed to setup networking: {}", .{err});
    };

    log.debug("executing init {s}", .{manifest.init});

    if (watchdog) |*w| w.disarm(io);

    return try stage2_init_allocator.dupeZ(u8, manifest.init);
}

pub fn main(init: std.process.Init, name: []const u8, args: *std.process.Args.Iterator) anyerror!void {
    _ = name;
    _ = args;

    if (system.getpid() != 1) {
        log.err("not running as PID1, refusing to continue", .{});
        @panic("PANIC");
    }

    var fba_buffer = std.mem.zeroes([std.fs.max_path_bytes]u8);
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

    const stage2_init = setupSystem(
        init.io,
        init.arena,
        fba.allocator(),
    ) catch |err| {
        std.log.err("system setup failed: {}\n", .{err});

        var futex: u32 = 0;
        while (true) std.Options.debug_io.futexWaitUncancelable(u32, &futex, 0);
        unreachable;
    };
    init.arena.deinit();

    const argv_buf = try fba.allocator().allocSentinel(?[*:0]const u8, 1, null);
    argv_buf[0] = stage2_init;

    comptime std.debug.assert(builtin.link_libc);
    const err = system.errno(system.execve(
        argv_buf.ptr[0].?,
        argv_buf.ptr,
        std.process.Environ.empty.block.slice,
    ));
    log.err("execv PID1 failed: {}", .{err});
    @panic("PANIC");
}
