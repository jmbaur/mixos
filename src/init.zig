const Kmod = @import("kmod.zig");
const Mount = @import("mount.zig");
const Watchdog = @import("watchdog.zig");
const builtin = @import("builtin");
const kmsg = @import("kmsg.zig");
const linux = @import("linux.zig");
const netlink = @import("netlink.zig");
const posix = std.posix;
const process = @import("process.zig");
const std = @import("std");
const system = std.os.linux;
const C = @cImport({
    @cInclude("linux/fcntl.h");
});

const log = std.log.scoped(.mixos);

const WatchdogConfig = struct {};

const BootConfig = struct {
    kernelModules: []const []const u8,
    watchdog: ?WatchdogConfig,
};

const GraphicsConfig = struct {
    /// The store path holding the graphics drivers.
    drivers: []const u8,
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

pub const Manifest = struct {
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

    graphics: ?GraphicsConfig,

    state: ?StateConfig,

    services: std.json.Value,
};

fn firstAvailableLoopDevice(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrintSentinel(
        allocator,
        "/dev/loop{}",
        .{try linux.loopbackGetFree(io)},
        0,
    );
}

fn createStoreLoopback(io: std.Io, allocator: std.mem.Allocator, store_fd: posix.fd_t, store_fs_source: []const u8) ![]const u8 {
    const store_fs = try std.Io.Dir.cwd().openFile(io, store_fs_source, .{});
    defer store_fs.close(io);
    const store_stat = try store_fs.stat(io);

    try linux.ftruncate(store_fd, store_stat.size);
    const bytes_copied = try linux.sendfile(store_fd, store_fs.handle, null, store_stat.size);
    if (bytes_copied != @as(usize, @intCast(store_stat.size))) {
        log.err("Failed to copy store image (size {Bi}), copied {Bi}", .{ store_stat.size, bytes_copied });
        return error.PartialStoreCopy;
    }

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

    // We cannot use the fancy erofs feature that allows for skipping loopback
    // device creation, since our erofs image is not placed on a true block
    // device. See https://github.com/gregkh/linux/blob/f2b09e8b594ce61b8ff508ea1fb594b3b24ec6d3/fs/erofs/super.c#L798-L799
    linux.loopbackSetFD(loop_device.handle, store_fd) catch |err| {
        log.err("failed to set backing file on loopback device: {}", .{err});
        return err;
    };

    return loop_device_path;
}

/// Where the nix store for a system comes from.
pub const StoreSource = union(enum) {
    /// A block device holding an erofs image, which is what the initrd carries.
    erofs: []const u8,

    /// An already-mounted tree, opened before a pivot so that it survives one.
    /// This is how a store that lives on another machine arrives.
    tree: *Mount,
};

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

// Fixed path for new systems to switch to with pivot_root().
pub const sysroot = "/sysroot";

const sysroot_relative = sysroot[1..];

// Fixed path where a system keeps the manifest it was brought up from, so that
// it can be brought up from the same one again. In the root, since that is what
// "mixos shutdown" leaves standing for the restart action that reads it.
pub const manifest_path = "/.manifest.json";

// Where persistent state lives.
pub const state_path = "/state";
pub const state_bind_mounts = [_][:0]const u8{ "var", "root", "home" };

/// Returns a handle to the new root directory.
pub fn switchRoot(io: std.Io, root_dir: std.Io.Dir) !void {
    try root_dir.createDirPath(io, sysroot_relative);

    var tmpfs = try Mount.init("tmpfs");
    try tmpfs.finish(root_dir, sysroot_relative, Mount.Options.NODEV | Mount.Options.NOSUID);

    var sysroot_dir = try root_dir.openDir(io, sysroot_relative, .{});
    defer sysroot_dir.close(io);

    // Create directories that do not yet exist
    inline for (&.{ "dev", "sys", "proc" }) |path| {
        try sysroot_dir.createDirPath(io, path);
    }

    // move pseudofilesystems into final root filesystem
    try linux.moveMount(root_dir.handle, "dev", sysroot_dir.handle, "dev", 0);
    try linux.moveMount(root_dir.handle, "sys", sysroot_dir.handle, "sys", 0);
    try linux.moveMount(root_dir.handle, "proc", sysroot_dir.handle, "proc", 0);

    try linux.fchdir(sysroot_dir);
    try linux.pivotRoot(".", ".");
    try linux.umount(".", system.MNT.DETACH);
}

pub fn setupRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_dir: std.Io.Dir,
    manifest: *const Manifest,
    store: StoreSource,
) !void {
    // Create directories that do not yet exist
    inline for (&.{ "usr", "etc", "run", "tmp", "var", "root", "home" }) |path| {
        try root_dir.createDirPath(io, path);
    }

    switch (store) {
        .erofs => |blockdev| try mountStore(io, allocator, blockdev, std.Io.Dir.cwd(), manifest.storeDir),
        .tree => |tree| {
            const store_dir_relative = std.mem.trimStart(u8, manifest.storeDir, std.fs.path.sep_str);
            try std.Io.Dir.cwd().createDirPath(io, store_dir_relative);
            try tree.finish(
                std.Io.Dir.cwd(),
                try allocator.dupeZ(u8, store_dir_relative),
                Mount.Options.RDONLY | Mount.Options.NODEV | Mount.Options.NOSUID,
            );
        },
    }

    var usr = try Mount.initTree(std.Io.Dir.cwd(), manifest.usr);
    try usr.finish(root_dir, "usr", 0);

    // setup usr-merge
    root_dir.symLink(io, "usr/bin", "/bin", .{ .is_directory = true }) catch {};
    root_dir.symLink(io, "usr/sbin", "/sbin", .{ .is_directory = true }) catch {};
    root_dir.symLink(io, "usr/lib", "/lib", .{ .is_directory = true }) catch {};

    // For compatibility with graphics-related packages from nixpkgs, we
    // symlink to /run/opengl-driver.
    if (manifest.graphics) |graphics| {
        root_dir.symLink(io, graphics.drivers, "/run/opengl-driver", .{ .is_directory = true }) catch |err| {
            log.err("failed to setup /run/opengl-driver: {}", .{err});
        };
    }
}

/// Kernel parameter asking for the running mixos to stand in for the one in the
/// store, mostly helpful for debugging.
const self_override_param = "mixos.self_override";

fn selfOverrideRequested(io: std.Io) bool {
    var buf: [4096]u8 = undefined;

    const cmdline = std.Io.Dir.cwd().openFile(io, "/proc/cmdline", .{}) catch return false;
    defer cmdline.close(io);

    var cmdline_reader = cmdline.reader(io, &buf);

    while (cmdline_reader.interface.takeDelimiter(' ') catch return false) |entry| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, entry, "\n"), self_override_param)) {
            return true;
        }
    }

    return false;
}

fn overrideStoreMixos(io: std.Io, arena_alloc: std.mem.Allocator, root_dir: std.Io.Dir) !void {
    const target = try root_dir.realPathFileAlloc(io, "usr/bin/mixos", arena_alloc);

    // We must copy first rather than a bind of /proc/self/exe, since that may
    // live in the initrd's rootfs.
    const copy_name = ".mixos-self-override";
    try std.Io.Dir.cwd().copyFile("/proc/self/exe", root_dir, copy_name, io, .{
        .permissions = .fromMode(0o555),
        .replace = true,
    });
    defer root_dir.deleteFile(io, copy_name) catch {};

    var self_mount = try Mount.initTree(root_dir, copy_name);
    try self_mount.finish(std.Io.Dir.cwd(), try arena_alloc.dupeZ(u8, target), Mount.Options.RDONLY);

    log.info("swapped {s} with current mixos executable", .{target});
}

/// By the point this runs, we already have /sys, /dev, and /proc mounted.
fn mountPseudoFilesystems(io: std.Io) void {
    b: {
        var mnt = Mount.init("devpts") catch break :b;
        std.Io.Dir.cwd().createDirPath(io, "/dev/pts") catch break :b;
        mnt.finish(
            std.Io.Dir.cwd(),
            "/dev/pts",
            Mount.Options.NOSUID | Mount.Options.NOEXEC,
        ) catch break :b;
    }

    b: {
        linux.mount(
            "pstore",
            "/sys/fs/pstore",
            "pstore",
            system.MS.NOEXEC | system.MS.NOSUID | system.MS.NODEV,
            0,
        ) catch break :b;
    }

    b: {
        linux.mount(
            "configfs",
            "/sys/kernel/config",
            "configfs",
            system.MS.NOEXEC | system.MS.NOSUID | system.MS.NODEV,
            0,
        ) catch break :b;
    }

    b: {
        linux.mount(
            "debugfs",
            "/sys/kernel/debug",
            "debugfs",
            system.MS.NOEXEC | system.MS.NOSUID | system.MS.NODEV,
            0,
        ) catch break :b;
    }

    b: {
        linux.mount(
            "tracefs",
            "/sys/kernel/tracing",
            "tracefs",
            system.MS.NOSUID | system.MS.NODEV | system.MS.NOEXEC | system.MS.RELATIME,
            0,
        ) catch break :b;
    }

    b: {
        linux.mount(
            "securityfs",
            "/sys/kernel/security",
            "securityfs",
            system.MS.NOSUID | system.MS.NODEV | system.MS.NOEXEC | system.MS.RELATIME,
            0,
        ) catch break :b;
    }

    b: {
        var mnt = Mount.init("cgroup2") catch break :b;
        mnt.finish(
            std.Io.Dir.cwd(),
            "/sys/fs/cgroup",
            Mount.Options.NOEXEC | Mount.Options.NOSUID | Mount.Options.NODEV,
        ) catch break :b;
    }

    b: {
        var mnt = Mount.init("tmpfs") catch break :b;
        std.Io.Dir.cwd().createDirPath(io, "/dev/shm") catch break :b;
        mnt.finish(std.Io.Dir.cwd(), "/dev/shm", Mount.Options.NOSUID | Mount.Options.NODEV) catch break :b;
    }
}

/// We need to have certain files exposed prior to loading kernel modules and
/// running mdev (since kmod and mdev have optional configuration files), so we
/// mount our etc hierarchy ahead of time here.
fn premountEtc(lower_etc: []const u8) !void {
    var etc = try Mount.initTree(std.Io.Dir.cwd(), lower_etc);
    try etc.finish(std.Io.Dir.cwd(), "/etc", 0);
}

/// Load all kernel modules declared in the MixOS configuration.
fn loadModules(io: std.Io, boot: *const BootConfig) !void {
    if (std.Io.Dir.cwd().access(io, "/proc/modules", .{})) {} else |_| {
        // kernel not built with modules support
        return;
    }

    if (std.Io.Dir.cwd().openFile(
        io,
        "/proc/sys/kernel/modprobe",
        .{ .mode = .write_only },
    )) |modprobe| {
        defer modprobe.close(io);
        const modprobe_path = "/sbin/modprobe\n";
        var writer = modprobe.writer(io, &.{});
        writer.interface.writeAll(modprobe_path) catch {};
        writer.interface.flush() catch {};
    } else |err| {
        log.err("failed to set modprobe path: {}", .{err});
    }

    if (boot.kernelModules.len == 0) {
        return;
    }

    var kmod = try Kmod.init(.{});
    defer kmod.deinit();

    for (boot.kernelModules) |module| {
        kmod.modprobe(module) catch |err| switch (err) {
            error.ModulesNotAvailable => break,
            else => log.err("failed to load module {s}: {}", .{ module, err }),
        };
    }
}

/// The longest a sysfs attribute can be.
const modalias_max_len = 4096;

/// A pass that turns up no new modalias ends the loop, so this is only here to
/// keep a device tree that somehow keeps growing from hanging the boot.
const max_device_module_passes = 8;

/// Load the modules for the devices the kernel has already found.
///
/// Every device the kernel registers before mdev is listening would go without
/// its driver, so ask the devices themselves what they need. Devices that turn
/// up later are covered by the $MODALIAS rule in mdev.conf.
fn loadDeviceModules(io: std.Io, allocator: std.mem.Allocator) !void {
    if (std.Io.Dir.cwd().access(io, "/proc/modules", .{})) {} else |_| {
        // kernel not built with modules support
        return;
    }

    var devices = try std.Io.Dir.cwd().openDir(io, "/sys/devices", .{ .iterate = true });
    defer devices.close(io);

    var kmod = try Kmod.init(.{});
    defer kmod.deinit();

    // Loading a module registers new devices, since a controller brings up the
    // bus below it, and those come with modaliases of their own. Keep going
    // until a pass turns up nothing new.
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (0..max_device_module_passes) |_| {
        var found_new = false;

        var walker = try devices.walk(allocator);
        defer walker.deinit();

        while (true) {
            // A device can be unregistered while we walk over it, which is not
            // a reason to give up on the rest of them: the next pass picks up
            // wherever this one left off.
            const next = walker.next(io) catch |err| {
                log.debug("walking /sys/devices failed: {}", .{err});
                break;
            };

            const entry = next orelse break;

            if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "modalias")) {
                continue;
            }

            var buf: [modalias_max_len]u8 = undefined;
            const contents = entry.dir.readFile(io, entry.basename, &buf) catch |err| {
                log.debug("failed to read {s}: {}", .{ entry.path, err });
                continue;
            };

            const modalias = std.mem.trim(u8, contents, &std.ascii.whitespace);
            if (modalias.len == 0 or seen.contains(modalias)) {
                continue;
            }

            try seen.put(allocator, try allocator.dupe(u8, modalias), void{});
            found_new = true;

            // Plenty of devices have no module to go with them, discard error.
            kmod.modprobe(modalias) catch {};
        }

        if (!found_new) {
            return;
        }
    }
}

fn mdevScan(io: std.Io, allocator: std.mem.Allocator) !void {
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

fn initState(
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    allocator: std.mem.Allocator,
    state: *const StateConfig,
) !void {
    b: {
        if (state.init) |init| {
            var output: IndentedWriter = .init(allocator, .{ .indentation = 2 });
            defer output.deinit();

            var env = try environ_map.clone(allocator);
            defer env.deinit();

            // This runs before busybox is involved, so PATH is not
            // set yet. We initialize it to a sane value here.
            try env.put("PATH", "/sbin:/bin:/usr/sbin:/usr/bin");

            const term = process.run(
                io,
                .{
                    .argv = &.{init},
                    .environ_map = &env,
                },
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

    log.debug("mounting state with fstype {s}", .{state.fsType});

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

    try std.Io.Dir.cwd().createDirPath(io, state_path);
    state_mount.finish(std.Io.Dir.cwd(), state_path, 0) catch |err| {
        log.err("failed to mount state from {s}: {}", .{ state.source, err });
        return err;
    };
}

fn setupState(io: std.Io, root_dir: std.Io.Dir, lower_etc: []const u8) !void {
    var state_dir = try root_dir.createDirPathOpen(
        io,
        std.mem.trimStart(u8, state_path, std.fs.path.sep_str),
        .{},
    );
    defer state_dir.close(io);

    // Ensure /var, /root, and /home persists data back to /state
    inline for (state_bind_mounts) |dir_name| {
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
        dir.symLink(io, "../run", "run", .{ .is_directory = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => log.err("failed to symlink /var/run to /run: {}", .{err}),
        };

        // Ensure basic state directories exist
        {
            dir.createDirPath(io, "lib/misc") catch |err| {
                log.err("failed to create /var/lib/misc: {}", .{err});
            };

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

    try linux.umount("/etc", system.MNT.FORCE);
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

fn setupServices(io: std.Io, allocator: std.mem.Allocator, services_value: std.json.Value) !void {
    var root_service_dir = try std.Io.Dir.cwd().createDirPathOpen(
        io,
        "/var/service",
        .{ .open_options = .{ .iterate = true } },
    );
    defer root_service_dir.close(io);

    const services = b: switch (services_value) {
        .object => |o| break :b o,
        else => {
            log.warn("services is not a JSON object, skipping!", .{});
            return;
        },
    };

    var managed_services: std.StringHashMapUnmanaged(void) = .empty;

    // Create mixos managed services.
    var iter = services.iterator();
    while (iter.next()) |service| {
        const service_name = service.key_ptr.*;
        const service_config = b: switch (service.value_ptr.*) {
            .object => |o| break :b o,
            else => {
                log.warn("skipping service '{s}' since service config is not a JSON object", .{service_name});
                continue;
            },
        };
        const run_value = service_config.get("run") orelse {
            log.warn("skipping service '{s}' since service config does not contain 'run' field", .{service_name});
            continue;
        };

        const run = b: switch (run_value) {
            .string => |s| break :b s,
            else => {
                log.warn("skipping service '{s}' since service config's 'run' is not a string", .{service_name});
                continue;
            },
        };

        setupService(io, root_service_dir, service_name, run) catch |err| {
            log.err("failed to setup service '{s}': {}", .{ service_name, err });
        };

        try managed_services.put(allocator, try allocator.dupe(u8, service_name), void{});
    }

    // Cleanup mixos managed services that no longer exist.
    var services_iter = root_service_dir.iterate();
    outer: while (try services_iter.next(io)) |dir_entry| {
        if (managed_services.get(dir_entry.name) != null) {
            // This service is managed, we cannot remove it.
            continue :outer;
        }

        var service_dir = root_service_dir.openDir(io, dir_entry.name, .{}) catch |err| {
            log.err("failed to access service directory for '{s}': {}", .{ dir_entry.name, err });
            continue;
        };
        defer service_dir.close(io);

        if (service_dir.access(
            io,
            "mixos",
            .{},
        )) {} else |_| {
            // Skip non-mixos managed services.
            continue;
        }

        log.debug("removing old service '{s}'", .{dir_entry.name});
        root_service_dir.deleteTree(io, dir_entry.name) catch |err| {
            log.err("failed to remove service '{s}': {}", .{ dir_entry.name, err });
        };
    }
}

fn setupService(io: std.Io, root_service_dir: std.Io.Dir, service_name: []const u8, run: []const u8) !void {
    var service_dir = try root_service_dir.createDirPathOpen(io, service_name, .{});
    defer service_dir.close(io);

    // Create an empty "mixos" directory within the service directory.
    // This is kept empty as of now, but we may want to place
    // information in here in the future. It also marks this service
    // as being managed by mixos, not a service created by the
    // end-user.
    try service_dir.createDirPath(io, "mixos");

    // The entire point of a declarative config is that we declare
    // what the state of the running system is, so we unapologetically
    // replace any runtime changes of the "run" executable with the one
    // the user declares it should be.
    service_dir.deleteFile(io, "run") catch {};
    try service_dir.symLink(io, run, "run", .{});
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
fn setupHostname(io: std.Io, allocator: std.mem.Allocator) !void {
    const hostname_file = std.Io.Dir.cwd().openFile(io, "/etc/hostname", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer hostname_file.close(io);

    var hostname_reader = hostname_file.reader(io, &.{});
    const hostname_contents = try hostname_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(hostname_contents);

    if (extractHostname(hostname_contents)) |hostname| {
        try linux.setHostname(hostname);
    }
}

fn setupNetworking() !void {
    netlink.setInterfaceState(.{ .name = "lo" }, .up) catch |err| switch (err) {
        error.MnlSocketOpen => {},
        else => return err,
    };
}

fn setupWatchdog(io: std.Io, watchdog: *const WatchdogConfig) !?Watchdog {
    _ = watchdog;

    return Watchdog.init(io) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

fn setupSystem(
    init: std.process.Init,
    stage2_init_allocator: std.mem.Allocator,
) ![*:0]const u8 {
    // We create this memfd object as early as possible, mostly so we get the
    // vanity of having a low file descriptor number.
    //
    // CLOEXEC because this descriptor is ours and no one else's: PID1 exec's
    // the real init at the end of all this, and anything holding the store open
    // across that would keep the whole image in memory and show up in every
    // /proc/<pid>/fd in the system.
    const store_fd = try linux.memfdCreate("store", system.MFD.ALLOW_SEALING | system.MFD.CLOEXEC);

    const allocator = init.arena.allocator();

    var manifest: Manifest = undefined;
    var manifest_contents: []const u8 = undefined;
    var store: StoreSource = undefined;

    // pre switch-root
    {
        var root_dir = try std.Io.Dir.cwd().openDir(init.io, "/", .{});
        defer root_dir.close(init.io);

        inline for (&.{ "dev", "sys", "proc" }) |path| {
            try root_dir.createDirPath(init.io, path);
        }
        var devtmpfs = try Mount.init("devtmpfs");
        try devtmpfs.finish(root_dir, "dev", Mount.Options.NOEXEC | Mount.Options.NOSUID);
        var sysfs = try Mount.init("sysfs");
        try sysfs.finish(root_dir, "sys", Mount.Options.NOEXEC | Mount.Options.NOSUID);
        var proc = try Mount.init("proc");
        try proc.finish(root_dir, "proc", Mount.Options.NOEXEC | Mount.Options.NOSUID | Mount.Options.NODEV);

        // We must wait until now to setup the /dev/kmsg logger, since /dev is not
        // mounted until right before this.
        kmsg.init(init.io);

        const manifest_json = try root_dir.openFile(init.io, ".manifest.json", .{});
        defer manifest_json.close(init.io);

        var manifest_json_reader = manifest_json.reader(init.io, &.{});
        manifest_contents = try manifest_json_reader.interface.allocRemaining(allocator, .unlimited);
        const manifest_ = try std.json.parseFromSlice(Manifest, allocator, manifest_contents, .{});

        manifest = manifest_.value;

        var kmod = try Kmod.init(.{});
        defer kmod.deinit();

        for ([_][]const u8{ "loop", "overlay", "erofs" }) |module_query| {
            kmod.modprobe(module_query) catch |err| switch (err) {
                error.ModulesNotAvailable => break,
                else => return err,
            };
        }

        store = .{ .erofs = try createStoreLoopback(init.io, allocator, store_fd, manifest.storeFS) };

        // The loopback device took its own reference to the memfd, so ours has
        // done its job. Letting it go now means the image is held by exactly
        // one thing, which is what makes it possible to ever give it back.
        _ = system.close(store_fd);

        try switchRoot(init.io, root_dir);
    }

    return try bringUp(
        init,
        allocator,
        stage2_init_allocator,
        &manifest,
        manifest_contents,
        store,
    );
}

/// Bring up the system described by `manifest` inside the root we have just
/// pivoted into, and return the init to hand control to.
pub fn bringUp(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    stage2_init_allocator: std.mem.Allocator,
    manifest: *const Manifest,
    manifest_json: []const u8,
    store: StoreSource,
) ![:0]const u8 {
    const override_self = selfOverrideRequested(init.io);

    var root_dir = try std.Io.Dir.cwd().openDir(init.io, "/", .{});
    defer root_dir.close(init.io);

    // Left where whatever brings this system up next can find it, and left
    // immutable rather than merely read-only, since everything here runs as
    // root and root is exactly who a mode does not stop. Reading it back is
    // unaffected, which is all anything wants it for. Not fatal: all that is
    // lost is the ability to restart without being told again what this system
    // is.
    if (root_dir.createFile(init.io, manifest_path[1..], .{
        .permissions = .fromMode(0o444),
    })) |manifest_file| {
        defer manifest_file.close(init.io);

        if (manifest_file.writeStreamingAll(init.io, manifest_json)) {
            // Through the descriptor we just wrote with: there is nothing to
            // reopen, and nothing in between for the file to be anything else.
            linux.setImmutable(manifest_file.handle) catch |err| {
                log.warn("could not make {s} immutable: {}", .{ manifest_path, err });
            };
        } else |err| {
            log.err("failed to record the manifest at {s}: {}", .{ manifest_path, err });
        }
    } else |err| {
        log.err("failed to record the manifest at {s}: {}", .{ manifest_path, err });
    }

    try setupRoot(init.io, allocator, root_dir, manifest, store);

    if (override_self) {
        overrideStoreMixos(init.io, allocator, root_dir) catch |err| {
            log.err("failed to override store mixos executable: {}", .{err});
        };
    }

    mountPseudoFilesystems(init.io);

    premountEtc(manifest.etc) catch |err| {
        log.err("failed to pre-mount /etc: {}", .{err});
    };

    loadModules(init.io, &manifest.boot) catch |err| {
        log.err("failed to load modules: {}", .{err});
    };

    // We prepare the watchdog right after loading modules, just in
    // case the list of modules the user wants to load includes any
    // module(s) for the watchdog.
    //
    // TODO(jared): We should just spawn off a thread that continually tries
    // for the duration of the setup.
    var watchdog = if (manifest.boot.watchdog) |*w| try setupWatchdog(init.io, w) else null;
    errdefer if (watchdog) |*w| w.deinit(init.io, .{ .disarm = false });

    // Runs after the watchdog is armed, since walking every device the kernel
    // found and loading what it asks for can take a while.
    loadDeviceModules(init.io, allocator) catch |err| {
        log.err("failed to load device modules: {}", .{err});
    };

    mdevScan(init.io, allocator) catch |err| {
        log.err("failed to run mdev: {}", .{err});
    };

    if (manifest.state) |state| try initState(init.io, init.environ_map, allocator, &state);

    try setupState(init.io, root_dir, manifest.etc);

    try setupServices(init.io, allocator, manifest.services);

    setupHostname(init.io, allocator) catch |err| {
        log.err("failed to set hostname: {}", .{err});
    };

    setupNetworking() catch |err| {
        log.err("failed to setup networking: {}", .{err});
    };

    log.debug("executing init {s}", .{manifest.init});

    if (watchdog) |*w| w.deinit(init.io, .{ .disarm = true });

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
        init,
        fba.allocator(),
    ) catch |err| {
        log.err("system setup failed: {}", .{err});

        // TODO(jared): If we don't have the watchdog enabled, we
        // should probably not hang indefinitely. If we panic
        // instead, at least the end user has the chance to pass
        // panic= to the kernel.
        var futex: u32 = 0;
        while (true) std.Options.debug_io.futexWaitUncancelable(u32, &futex, 0);
        unreachable;
    };
    kmsg.deinit();
    init.arena.deinit();

    const argv_buf = try fba.allocator().allocSentinel(?[*:0]const u8, 1, null);
    argv_buf[0] = stage2_init;

    comptime std.debug.assert(builtin.link_libc);
    const err = system.errno(system.execve(
        argv_buf.ptr[0].?,
        argv_buf.ptr,
        std.process.Environ.empty.block.slice,
    ));
    log.err("execve '{s}' failed: {}", .{ stage2_init, err });
    @panic("PANIC");
}
