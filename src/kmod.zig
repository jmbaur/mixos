const std = @import("std");
const system = std.posix.system;

const c = @cImport({
    @cInclude("fnmatch.h");
    @cInclude("linux/module.h");
});

const log = std.log.scoped(.mixos);

const Kmod = @This();

allocator: std.mem.Allocator,

/// /lib/modules/$(uname -r)
modules_dir: std.fs.Dir,

/// modules.dep file contents
modules_dep: []const u8,

/// modules.alias file contents
modules_alias: []const u8,

/// Index into `modules_dep` based on module name
module_index: ModuleIndex,

const MODULES_DIR = "/lib/modules";
const MODULES_DEP = "modules.dep";
const MODULES_ALIAS = "modules.alias";

const ModuleIndex = std.StringArrayHashMap(usize);

fn buildModuleIndex(allocator: std.mem.Allocator, modules_dep: []const u8) !ModuleIndex {
    var reader: std.Io.Reader = .fixed(modules_dep);

    var module_index = ModuleIndex.init(allocator);
    errdefer module_index.deinit();

    while (true) {
        const offset = reader.seek;
        const module = std.mem.trim(u8, try reader.takeDelimiter(':') orelse break, &std.ascii.whitespace);

        _ = try reader.takeDelimiter('\n') orelse return error.InvalidModuleDep;
        const module_filename_full = std.fs.path.basename(module);
        const module_filename_without_compress = std.fs.path.stem(module_filename_full);
        const module_name_without_any = std.fs.path.stem(module_filename_without_compress);

        try module_index.put(module_name_without_any, offset);
    }

    return module_index;
}

fn findModuleOffset(
    allocator: std.mem.Allocator,
    module_index: *ModuleIndex,
    modules_alias: []const u8,
    module_query: []const u8,
) !?usize {
    // If we find the module by the exact name, then we are done.
    if (module_index.get(module_query)) |offset| {
        return offset;
    }

    // Otherwise, we need to look the module up by alias
    var reader: std.Io.Reader = .fixed(modules_alias);
    while (true) {
        const line = (reader.takeDelimiter('\n') catch return null) orelse return null;

        var words = std.mem.splitScalar(u8, line, ' ');

        const first_word = words.next() orelse return null;
        if (!std.mem.eql(u8, first_word, "alias")) {
            continue;
        }

        const pattern = words.next() orelse return null;
        const module_name = words.next() orelse return null;

        const patternZ = try allocator.dupeZ(u8, pattern);
        defer allocator.free(patternZ);

        const moduleZ = try allocator.dupeZ(u8, module_query);
        defer allocator.free(moduleZ);

        if (c.fnmatch(patternZ, moduleZ, 0) != 0) {
            continue;
        }

        return module_index.get(module_name);
    }

    return null;
}

test "findModuleOffset" {
    const modules_alias =
        \\alias pci:v00008086d00000953sv*sd*bc*sc*i* nvme
        \\alias pci:v00008086d00000A53sv*sd*bc*sc*i* nvme
        \\alias pci:v00008086d00000A54sv*sd*bc*sc*i* nvme
        \\alias pci:v00008086d00000A55sv*sd*bc*sc*i* nvme
        \\alias pci:v00008086d0000F1A5sv*sd*bc*sc*i* nvme
        \\alias pci:v00008086d0000F1A6sv*sd*bc*sc*i* nvme
        \\alias pci:v00008086d00005845sv*sd*bc*sc*i* nvme
        \\alias pci:v00001B36d00000010sv*sd*bc*sc*i* nvme
        \\alias pci:v00001217d00008760sv*sd*bc*sc*i* nvme
        \\alias pci:v0000126Fd00001001sv*sd*bc*sc*i* nvme
        \\alias pci:v0000126Fd00002262sv*sd*bc*sc*i* nvme
        \\alias pci:v0000126Fd00002263sv*sd*bc*sc*i* nvme
        \\alias pci:v00001BB1d00000100sv*sd*bc*sc*i* nvme
        \\alias pci:v00001C58d00000003sv*sd*bc*sc*i* nvme
        \\alias pci:v00001C58d00000023sv*sd*bc*sc*i* nvme
        \\alias pci:v00001C5Fd00000540sv*sd*bc*sc*i* nvme
        \\alias pci:v0000144Dd0000A821sv*sd*bc*sc*i* nvme
        \\alias pci:v0000144Dd0000A822sv*sd*bc*sc*i* nvme
        \\alias pci:v000015B7d00005008sv*sd*bc*sc*i* nvme
        \\alias pci:v000015B7d00005009sv*sd*bc*sc*i* nvme
        \\alias pci:v00001987d00005012sv*sd*bc*sc*i* nvme
        \\alias pci:v00001987d00005016sv*sd*bc*sc*i* nvme
        \\alias pci:v00001987d00005019sv*sd*bc*sc*i* nvme
        \\alias pci:v00001987d00005021sv*sd*bc*sc*i* nvme
        \\alias pci:v00001B4Bd00001092sv*sd*bc*sc*i* nvme
        \\alias pci:v00001CC1d000033F8sv*sd*bc*sc*i* nvme
        \\alias pci:v000010ECd00005762sv*sd*bc*sc*i* nvme
        \\alias pci:v000010ECd00005763sv*sd*bc*sc*i* nvme
        \\alias pci:v00001CC1d00008201sv*sd*bc*sc*i* nvme
        \\alias pci:v00001344d00005407sv*sd*bc*sc*i* nvme
        \\alias pci:v00001344d00006001sv*sd*bc*sc*i* nvme
        \\alias pci:v00001C5Cd00001504sv*sd*bc*sc*i* nvme
        \\alias pci:v00001C5Cd0000174Asv*sd*bc*sc*i* nvme
        \\alias pci:v00001C5Cd00001D59sv*sd*bc*sc*i* nvme
        \\alias pci:v000015B7d00002001sv*sd*bc*sc*i* nvme
        \\alias pci:v00001D97d00002263sv*sd*bc*sc*i* nvme
        \\alias pci:v0000144Dd0000A80Bsv*sd*bc*sc*i* nvme
        \\alias pci:v0000144Dd0000A809sv*sd*bc*sc*i* nvme
        \\alias pci:v0000144Dd0000A802sv*sd*bc*sc*i* nvme
        \\alias pci:v00001CC4d00006303sv*sd*bc*sc*i* nvme
        \\alias pci:v00001CC4d00006302sv*sd*bc*sc*i* nvme
        \\alias pci:v00002646d00002262sv*sd*bc*sc*i* nvme
        \\alias pci:v00002646d00002263sv*sd*bc*sc*i* nvme
        \\alias pci:v00002646d00005013sv*sd*bc*sc*i* nvme
        \\alias pci:v00002646d00005018sv*sd*bc*sc*i* nvme
        \\alias pci:v00002646d00005016sv*sd*bc*sc*i* nvme
        \\alias pci:v00002646d0000501Asv*sd*bc*sc*i* nvme
        \\alias pci:v00002646d0000501Bsv*sd*bc*sc*i* nvme
        \\alias pci:v00002646d0000501Esv*sd*bc*sc*i* nvme
        \\alias pci:v00001F40d00001202sv*sd*bc*sc*i* nvme
        \\alias pci:v00001F40d00005236sv*sd*bc*sc*i* nvme
        \\alias pci:v00001E4Bd00001001sv*sd*bc*sc*i* nvme
        \\alias pci:v00001E4Bd00001002sv*sd*bc*sc*i* nvme
        \\alias pci:v00001E4Bd00001202sv*sd*bc*sc*i* nvme
        \\alias pci:v00001E4Bd00001602sv*sd*bc*sc*i* nvme
        \\alias pci:v00001CC1d00005350sv*sd*bc*sc*i* nvme
        \\alias pci:v00001DBEd00005216sv*sd*bc*sc*i* nvme
        \\alias pci:v00001DBEd00005236sv*sd*bc*sc*i* nvme
        \\alias pci:v00001E49d00000021sv*sd*bc*sc*i* nvme
        \\alias pci:v00001E49d00000041sv*sd*bc*sc*i* nvme
        \\alias pci:v0000025Ed0000F1ACsv*sd*bc*sc*i* nvme
        \\alias pci:v0000C0A9d0000540Asv*sd*bc*sc*i* nvme
        \\alias pci:v00001D97d00001D97sv*sd*bc*sc*i* nvme
        \\alias pci:v00001D97d00002269sv*sd*bc*sc*i* nvme
        \\alias pci:v000010ECd00005765sv*sd*bc*sc*i* nvme
        \\alias pci:v00001D0Fd00000061sv*sd*bc*sc*i* nvme
        \\alias pci:v00001D0Fd00000065sv*sd*bc*sc*i* nvme
        \\alias pci:v00001D0Fd00008061sv*sd*bc*sc*i* nvme
        \\alias pci:v00001D0Fd0000CD00sv*sd*bc*sc*i* nvme
        \\alias pci:v00001D0Fd0000CD01sv*sd*bc*sc*i* nvme
        \\alias pci:v00001D0Fd0000CD02sv*sd*bc*sc*i* nvme
        \\alias pci:v0000106Bd00002001sv*sd*bc*sc*i* nvme
        \\alias pci:v0000106Bd00002003sv*sd*bc*sc*i* nvme
        \\alias pci:v0000106Bd00002005sv*sd*bc*sc*i* nvme
        \\alias pci:v*d*sv*sd*bc01sc08i02* nvme
        \\alias ipt_addrtype xt_addrtype
        \\alias ip6t_addrtype xt_addrtype
        \\alias ipt_mark xt_mark
        \\alias ip6t_mark xt_mark
        \\alias ipt_MARK xt_mark
        \\alias ip6t_MARK xt_mark
        \\alias arpt_MARK xt_mark
        \\alias fs-efivarfs efivarfs
        \\alias ip6t_MASQUERADE xt_MASQUERADE
        \\alias ipt_MASQUERADE xt_MASQUERADE
        \\alias ipt_LOG xt_LOG
        \\alias ip6t_LOG xt_LOG
        \\alias nf_log_arp nf_log_syslog
        \\alias nf_log_bridge nf_log_syslog
        \\alias nf_log_ipv4 nf_log_syslog
        \\alias nf_log_ipv6 nf_log_syslog
        \\alias nf_log_netdev nf_log_syslog
        \\alias nf-logger-7-0 nf_log_syslog
        \\alias nf-logger-2-0 nf_log_syslog
        \\alias nf-logger-3-0 nf_log_syslog
        \\alias nf-logger-5-0 nf_log_syslog
        \\alias nf-logger-10-0 nf_log_syslog
        \\alias cpu:type:x86,ven0000fam*mod*:feature:*01C6* x86_pkg_temp_thermal
    ;

    const uncompressed_modules_dep =
        \\kernel/drivers/nvme/host/nvme.ko: kernel/drivers/nvme/host/nvme-core.ko
        \\kernel/net/netfilter/xt_addrtype.ko:
        \\kernel/net/netfilter/xt_mark.ko:
        \\kernel/fs/efivarfs/efivarfs.ko:
        \\kernel/drivers/nvme/host/nvme-core.ko:
        \\kernel/net/netfilter/xt_MASQUERADE.ko:
        \\kernel/net/netfilter/xt_LOG.ko:
        \\kernel/net/netfilter/nf_log_syslog.ko:
        \\kernel/drivers/nvme/host/nvme-tcp.ko: kernel/drivers/nvme/host/nvme-fabrics.ko kernel/drivers/nvme/host/nvme-core.ko
        \\kernel/net/ipv4/netfilter/nf_reject_ipv4.ko:
        \\kernel/net/ipv6/netfilter/nf_reject_ipv6.ko:
        \\kernel/drivers/thermal/intel/x86_pkg_temp_thermal.ko:
        \\kernel/drivers/nvme/host/nvme-fabrics.ko: kernel/drivers/nvme/host/nvme-core.ko
    ;

    {
        var module_index = try buildModuleIndex(std.testing.allocator, uncompressed_modules_dep);
        defer module_index.deinit();

        try std.testing.expectEqual(0, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "nvme",
        ) orelse unreachable);

        try std.testing.expectEqual(72, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "xt_addrtype",
        ) orelse unreachable);

        try std.testing.expectEqual(109, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "xt_mark",
        ) orelse unreachable);

        try std.testing.expectEqual(584, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "nvme-fabrics",
        ) orelse unreachable);

        try std.testing.expectEqual(142, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "fs-efivarfs",
        ) orelse unreachable);

        try std.testing.expectEqual(530, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "cpu:type:x86,ven0000fam0mod0:feature:,01C6,",
        ) orelse unreachable);
    }

    const increase = std.mem.replacementSize(u8, uncompressed_modules_dep, ".ko", ".ko.xz");
    const compressed_modules_dep = try std.testing.allocator.alloc(u8, uncompressed_modules_dep.len + increase);
    defer std.testing.allocator.free(compressed_modules_dep);

    _ = std.mem.replace(u8, uncompressed_modules_dep, ".ko", ".ko.xz", compressed_modules_dep);

    {
        var module_index = try buildModuleIndex(std.testing.allocator, compressed_modules_dep);
        defer module_index.deinit();

        try std.testing.expectEqual(0, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "nvme",
        ) orelse unreachable);

        try std.testing.expectEqual(78, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "xt_addrtype",
        ) orelse unreachable);

        try std.testing.expectEqual(118, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "xt_mark",
        ) orelse unreachable);

        try std.testing.expectEqual(629, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "nvme-fabrics",
        ) orelse unreachable);

        try std.testing.expectEqual(154, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "fs-efivarfs",
        ) orelse unreachable);

        try std.testing.expectEqual(572, try findModuleOffset(
            std.testing.allocator,
            &module_index,
            modules_alias,
            "cpu:type:x86,ven0000fam0mod0:feature:,01C6,",
        ) orelse unreachable);
    }
}

pub fn init(allocator: std.mem.Allocator) !Kmod {
    const utsname = std.posix.uname();
    const modules_dir_filepath = try std.fs.path.join(allocator, &.{
        MODULES_DIR,
        std.mem.sliceTo(&utsname.release, 0),
    });

    var modules_dir = std.fs.cwd().openDir(modules_dir_filepath, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NoModules,
        else => return err,
    };
    errdefer modules_dir.close();

    const modules_dep_file = try modules_dir.openFile(MODULES_DEP, .{});
    defer modules_dep_file.close();
    const modules_dep = try modules_dep_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    errdefer allocator.free(modules_dep);

    const modules_alias_file = try modules_dir.openFile(MODULES_ALIAS, .{});
    defer modules_alias_file.close();
    const modules_alias = try modules_alias_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    errdefer allocator.free(modules_alias);

    const module_index = try buildModuleIndex(allocator, modules_dep);

    return .{
        .allocator = allocator,
        .modules_dir = modules_dir,
        .modules_dep = modules_dep,
        .modules_alias = modules_alias,
        .module_index = module_index,
    };
}

pub fn deinit(self: *Kmod) void {
    self.modules_dir.close();
    self.module_index.deinit();
    self.allocator.free(self.modules_dep);
    self.allocator.free(self.modules_alias);
}

fn finit_module(
    fd: std.posix.fd_t,
    module_display: []const u8,
    params: ?[:0]const u8,
    flags: usize,
) !void {
    switch (system.E.init(std.os.linux.syscall3(.finit_module, @intCast(fd), @intFromPtr(&params), flags))) {
        .SUCCESS, .EXIST => {},
        else => |err| {
            log.err(
                "failed to load module '{s}': {s}",
                .{ module_display, @tagName(err) },
            );

            return switch (err) {
                .BUSY => error.DeviceBusy,
                .PERM => error.PermissionDenied,
                .BADMSG => error.MisformattedModSig,
                .NOKEY => error.InvalidModSig,
                else => std.posix.unexpectedErrno(err),
            };
        },
    }
}

fn insmod(
    self: *Kmod,
    module_filepath: []const u8,
    params: ?[:0]const u8,
) !void {
    const module_basename = std.fs.path.basename(module_filepath);
    const module_stem = std.fs.path.stem(module_basename);
    const module_display = std.fs.path.stem(module_stem);

    log.debug("loading module {s} from {s}", .{ module_stem, module_filepath });

    var module_file = try self.modules_dir.openFile(module_filepath, .{});
    defer module_file.close();

    var flags: usize = 0;

    var buf = [_]u8{0} ** @max(
        @sizeOf(std.elf.Elf64_Ehdr),
        @sizeOf(std.elf.Elf32_Ehdr),
    );
    var reader = module_file.reader(&buf);
    if (std.elf.Header.read(&reader.interface)) |_| {} else |_| {
        // If the module is not a valid ELF file, we assume it is compressed.
        flags |= c.MODULE_INIT_COMPRESSED_FILE;
    }

    try finit_module(module_file.handle, module_display, params, flags);
}

/// Load a kernel module given a module name (or alias) as well as optional
/// module parameters.
///
/// TODO(jared): Consume /etc/modules.conf (documented as working in busybox,
/// though never implemented anywhere). This will allow for customizing module
/// parameters for all modules, not just the top-level module being loaded, but
/// all transitive modules as well.
pub fn modprobe(self: *Kmod, module_query: []const u8, override_params: ?[]const u8) !void {
    const offset = try findModuleOffset(
        self.allocator,
        &self.module_index,
        self.modules_alias,
        module_query,
    ) orelse return error.UnknownModule;

    var reader: std.Io.Reader = .fixed(self.modules_dep[offset..]);

    const module_filepath = std.mem.trim(
        u8,
        try reader.takeDelimiter(':') orelse return error.InvalidModuleDep,
        &std.ascii.whitespace,
    );

    const dependencies = std.mem.trim(
        u8,
        try reader.takeDelimiter('\n') orelse return error.InvalidModuleDep,
        &std.ascii.whitespace,
    );

    if (dependencies.len > 0) {
        // Module dependencies should be loaded in reverse order, so we iterate
        // over the dependencies starting from the end.
        var dep_split = std.mem.splitBackwardsScalar(u8, dependencies, ' ');
        while (dep_split.next()) |dep| {
            try self.insmod(dep, null);
        }
    }

    if (override_params) |params| {
        const paramsZ = try self.allocator.dupeZ(u8, params);
        defer self.allocator.free(paramsZ);

        try self.insmod(module_filepath, paramsZ);
    } else {
        try self.insmod(module_filepath, null);
    }
}
