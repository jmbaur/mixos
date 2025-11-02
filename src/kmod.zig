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

/// Module aliases built from iterating through $MODULES_DIR/modules.alias and
/// /etc/modules.conf.
aliases: []const u8,

/// Module parameters built from iterating through /etc/modules.conf. Can be
/// overridden manually by specifying extra arguments on the command-line to
/// modprobe/insmod.
params: ParamIndex,

/// Index into `modules_dep` based on module name
module_index: ModuleIndex,

const MODULES_CONF = "/etc/modules.conf";
const MODULES_DIR = "/lib/modules";
const MODULES_DEP = "modules.dep";
const MODULES_ALIAS = "modules.alias";

const ModuleIndex = std.StringArrayHashMap(usize);
const ParamIndex = std.BufMap;

fn buildParamIndex(allocator: std.mem.Allocator, reader: *std.Io.Reader) !ParamIndex {
    var params: ParamIndex = .init(allocator);
    errdefer params.deinit();

    while (true) {
        const line = (reader.takeDelimiter('\n') catch break) orelse break;

        var words = std.mem.tokenizeScalar(u8, line, ' ');

        const first_word = words.next() orelse continue;
        if (!std.mem.eql(u8, first_word, "options")) {
            continue;
        }

        const module_name = words.next() orelse continue;

        const first_param = words.next() orelse continue;
        var module_params: std.Io.Writer.Allocating = .init(allocator);
        defer module_params.deinit();

        try module_params.writer.writeAll(first_param);
        try module_params.writer.writeByte(' ');
        while (words.next()) |other_param| {
            try module_params.writer.writeAll(other_param);
            try module_params.writer.writeByte(' ');
        }
        module_params.writer.undo(1);

        try params.put(module_name, module_params.written());
    }

    return params;
}

test "buildParamIndex" {
    const modules_conf =
        \\options foo bar
        \\options asdf
        \\
        \\# this is a comment
        \\options nvme-tcp wq_unbound=Y
    ;

    var reader: std.Io.Reader = .fixed(modules_conf);
    var index = try buildParamIndex(std.testing.allocator, &reader);
    defer index.deinit();

    try std.testing.expectEqual(2, index.count());
    try std.testing.expectEqual(null, index.get("asdf"));
    try std.testing.expectEqualStrings("bar", index.get("foo") orelse unreachable);
    try std.testing.expectEqualStrings("wq_unbound=Y", index.get("nvme-tcp") orelse unreachable);
}

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

const ModuleOffsets = std.AutoArrayHashMap(usize, void);

fn findModuleOffsets(
    allocator: std.mem.Allocator,
    module_index: *ModuleIndex,
    aliases: []const u8,
    module_query: []const u8,
) !ModuleOffsets {
    var offsets: ModuleOffsets = .init(allocator);
    errdefer offsets.deinit();

    // If we find the module by the exact name, then we are done.
    if (module_index.get(module_query)) |offset| {
        try offsets.put(offset, void{});
        return offsets;
    }

    // Otherwise, we need to look the module up by alias
    var alias_reader: std.Io.Reader = .fixed(aliases);
    while (true) {
        const line = (alias_reader.takeDelimiter('\n') catch break) orelse break;

        var words = std.mem.tokenizeScalar(u8, line, ' ');

        const pattern = words.next() orelse continue;
        const module_name = words.next() orelse continue;
        if (words.next() != null) {
            continue;
        }

        const patternZ = try allocator.dupeZ(u8, pattern);
        defer allocator.free(patternZ);

        const moduleZ = try allocator.dupeZ(u8, module_query);
        defer allocator.free(moduleZ);

        if (c.fnmatch(patternZ, moduleZ, 0) != 0) {
            continue;
        }

        if (module_index.get(module_name)) |offset| {
            try offsets.put(offset, void{});
        }
    }

    return offsets;
}

test "findModuleOffsets" {
    const aliases =
        \\pci:v00008086d00000953sv*sd*bc*sc*i* nvme
        \\pci:v00008086d00000A53sv*sd*bc*sc*i* nvme
        \\pci:v00008086d00000A54sv*sd*bc*sc*i* nvme
        \\pci:v00008086d00000A55sv*sd*bc*sc*i* nvme
        \\pci:v00008086d0000F1A5sv*sd*bc*sc*i* nvme
        \\pci:v00008086d0000F1A6sv*sd*bc*sc*i* nvme
        \\pci:v00008086d00005845sv*sd*bc*sc*i* nvme
        \\pci:v00001B36d00000010sv*sd*bc*sc*i* nvme
        \\pci:v00001217d00008760sv*sd*bc*sc*i* nvme
        \\pci:v0000126Fd00001001sv*sd*bc*sc*i* nvme
        \\pci:v0000126Fd00002262sv*sd*bc*sc*i* nvme
        \\pci:v0000126Fd00002263sv*sd*bc*sc*i* nvme
        \\pci:v00001BB1d00000100sv*sd*bc*sc*i* nvme
        \\pci:v00001C58d00000003sv*sd*bc*sc*i* nvme
        \\pci:v00001C58d00000023sv*sd*bc*sc*i* nvme
        \\pci:v00001C5Fd00000540sv*sd*bc*sc*i* nvme
        \\pci:v0000144Dd0000A821sv*sd*bc*sc*i* nvme
        \\pci:v0000144Dd0000A822sv*sd*bc*sc*i* nvme
        \\pci:v000015B7d00005008sv*sd*bc*sc*i* nvme
        \\pci:v000015B7d00005009sv*sd*bc*sc*i* nvme
        \\pci:v00001987d00005012sv*sd*bc*sc*i* nvme
        \\pci:v00001987d00005016sv*sd*bc*sc*i* nvme
        \\pci:v00001987d00005019sv*sd*bc*sc*i* nvme
        \\pci:v00001987d00005021sv*sd*bc*sc*i* nvme
        \\pci:v00001B4Bd00001092sv*sd*bc*sc*i* nvme
        \\pci:v00001CC1d000033F8sv*sd*bc*sc*i* nvme
        \\pci:v000010ECd00005762sv*sd*bc*sc*i* nvme
        \\pci:v000010ECd00005763sv*sd*bc*sc*i* nvme
        \\pci:v00001CC1d00008201sv*sd*bc*sc*i* nvme
        \\pci:v00001344d00005407sv*sd*bc*sc*i* nvme
        \\pci:v00001344d00006001sv*sd*bc*sc*i* nvme
        \\pci:v00001C5Cd00001504sv*sd*bc*sc*i* nvme
        \\pci:v00001C5Cd0000174Asv*sd*bc*sc*i* nvme
        \\pci:v00001C5Cd00001D59sv*sd*bc*sc*i* nvme
        \\pci:v000015B7d00002001sv*sd*bc*sc*i* nvme
        \\pci:v00001D97d00002263sv*sd*bc*sc*i* nvme
        \\pci:v0000144Dd0000A80Bsv*sd*bc*sc*i* nvme
        \\pci:v0000144Dd0000A809sv*sd*bc*sc*i* nvme
        \\pci:v0000144Dd0000A802sv*sd*bc*sc*i* nvme
        \\pci:v00001CC4d00006303sv*sd*bc*sc*i* nvme
        \\pci:v00001CC4d00006302sv*sd*bc*sc*i* nvme
        \\pci:v00002646d00002262sv*sd*bc*sc*i* nvme
        \\pci:v00002646d00002263sv*sd*bc*sc*i* nvme
        \\pci:v00002646d00005013sv*sd*bc*sc*i* nvme
        \\pci:v00002646d00005018sv*sd*bc*sc*i* nvme
        \\pci:v00002646d00005016sv*sd*bc*sc*i* nvme
        \\pci:v00002646d0000501Asv*sd*bc*sc*i* nvme
        \\pci:v00002646d0000501Bsv*sd*bc*sc*i* nvme
        \\pci:v00002646d0000501Esv*sd*bc*sc*i* nvme
        \\pci:v00001F40d00001202sv*sd*bc*sc*i* nvme
        \\pci:v00001F40d00005236sv*sd*bc*sc*i* nvme
        \\pci:v00001E4Bd00001001sv*sd*bc*sc*i* nvme
        \\pci:v00001E4Bd00001002sv*sd*bc*sc*i* nvme
        \\pci:v00001E4Bd00001202sv*sd*bc*sc*i* nvme
        \\pci:v00001E4Bd00001602sv*sd*bc*sc*i* nvme
        \\pci:v00001CC1d00005350sv*sd*bc*sc*i* nvme
        \\pci:v00001DBEd00005216sv*sd*bc*sc*i* nvme
        \\pci:v00001DBEd00005236sv*sd*bc*sc*i* nvme
        \\pci:v00001E49d00000021sv*sd*bc*sc*i* nvme
        \\pci:v00001E49d00000041sv*sd*bc*sc*i* nvme
        \\pci:v0000025Ed0000F1ACsv*sd*bc*sc*i* nvme
        \\pci:v0000C0A9d0000540Asv*sd*bc*sc*i* nvme
        \\pci:v00001D97d00001D97sv*sd*bc*sc*i* nvme
        \\pci:v00001D97d00002269sv*sd*bc*sc*i* nvme
        \\pci:v000010ECd00005765sv*sd*bc*sc*i* nvme
        \\pci:v00001D0Fd00000061sv*sd*bc*sc*i* nvme
        \\pci:v00001D0Fd00000065sv*sd*bc*sc*i* nvme
        \\pci:v00001D0Fd00008061sv*sd*bc*sc*i* nvme
        \\pci:v00001D0Fd0000CD00sv*sd*bc*sc*i* nvme
        \\pci:v00001D0Fd0000CD01sv*sd*bc*sc*i* nvme
        \\pci:v00001D0Fd0000CD02sv*sd*bc*sc*i* nvme
        \\pci:v0000106Bd00002001sv*sd*bc*sc*i* nvme
        \\pci:v0000106Bd00002003sv*sd*bc*sc*i* nvme
        \\pci:v0000106Bd00002005sv*sd*bc*sc*i* nvme
        \\pci:v*d*sv*sd*bc01sc08i02* nvme
        \\ipt_addrtype xt_addrtype
        \\ip6t_addrtype xt_addrtype
        \\ipt_mark xt_mark
        \\ip6t_mark xt_mark
        \\ipt_MARK xt_mark
        \\ip6t_MARK xt_mark
        \\arpt_MARK xt_mark
        \\fs-efivarfs efivarfs
        \\ip6t_MASQUERADE xt_MASQUERADE
        \\ipt_MASQUERADE xt_MASQUERADE
        \\ipt_LOG xt_LOG
        \\ip6t_LOG xt_LOG
        \\nf_log_arp nf_log_syslog
        \\nf_log_bridge nf_log_syslog
        \\nf_log_ipv4 nf_log_syslog
        \\nf_log_ipv6 nf_log_syslog
        \\nf_log_netdev nf_log_syslog
        \\nf-logger-7-0 nf_log_syslog
        \\nf-logger-2-0 nf_log_syslog
        \\nf-logger-3-0 nf_log_syslog
        \\nf-logger-5-0 nf_log_syslog
        \\nf-logger-10-0 nf_log_syslog
        \\cpu:type:x86,ven0000fam*mod*:feature:*01C6* x86_pkg_temp_thermal
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

        {
            var offsets = try findModuleOffsets(
                std.testing.allocator,
                &module_index,
                aliases,
                "nvme",
            );
            defer offsets.deinit();
            try std.testing.expectEqualSlices(usize, &.{0}, offsets.keys());
        }

        {
            var offsets = try findModuleOffsets(
                std.testing.allocator,
                &module_index,
                aliases,
                "xt_addrtype",
            );
            defer offsets.deinit();
            try std.testing.expectEqualSlices(usize, &.{72}, offsets.keys());
        }

        {
            var offsets = try findModuleOffsets(
                std.testing.allocator,
                &module_index,
                aliases,
                "xt_mark",
            );
            defer offsets.deinit();
            try std.testing.expectEqualSlices(usize, &.{109}, offsets.keys());
        }

        {
            var offsets = try findModuleOffsets(
                std.testing.allocator,
                &module_index,
                aliases,
                "nvme-fabrics",
            );
            defer offsets.deinit();
            try std.testing.expectEqualSlices(usize, &.{584}, offsets.keys());
        }

        {
            var offsets = try findModuleOffsets(
                std.testing.allocator,
                &module_index,
                aliases,
                "fs-efivarfs",
            );
            defer offsets.deinit();
            try std.testing.expectEqualSlices(usize, &.{142}, offsets.keys());
        }

        {
            var offsets = try findModuleOffsets(
                std.testing.allocator,
                &module_index,
                aliases,
                "cpu:type:x86,ven0000fam0mod0:feature:,01C6,",
            );
            defer offsets.deinit();
            try std.testing.expectEqualSlices(usize, &.{530}, offsets.keys());
        }
    }

    const increase = std.mem.replacementSize(u8, uncompressed_modules_dep, ".ko", ".ko.xz");
    const compressed_modules_dep = try std.testing.allocator.alloc(u8, uncompressed_modules_dep.len + increase);
    defer std.testing.allocator.free(compressed_modules_dep);

    _ = std.mem.replace(u8, uncompressed_modules_dep, ".ko", ".ko.xz", compressed_modules_dep);

    {
        var module_index = try buildModuleIndex(std.testing.allocator, compressed_modules_dep);
        defer module_index.deinit();

        {
            var offsets = try findModuleOffsets(
                std.testing.allocator,
                &module_index,
                aliases,
                "nvme",
            );
            defer offsets.deinit();
            try std.testing.expectEqualSlices(usize, &.{0}, offsets.keys());
        }

        {
            var offsets = try findModuleOffsets(
                std.testing.allocator,
                &module_index,
                aliases,
                "cpu:type:x86,ven0000fam0mod0:feature:,01C6,",
            );
            defer offsets.deinit();
            try std.testing.expectEqualSlices(usize, &.{572}, offsets.keys());
        }
    }
}

fn appendAliases(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    while (true) {
        const line = (reader.takeDelimiter('\n') catch break) orelse break;

        var words = std.mem.tokenizeScalar(u8, line, ' ');

        const first_word = words.next() orelse continue;
        if (!std.mem.eql(u8, first_word, "alias")) {
            continue;
        }

        const pattern = words.next() orelse continue;
        const module_name = words.next() orelse continue;
        if (words.next() != null) {
            log.debug("invalid alias line: '{s}'", .{line});
            continue;
        }

        try writer.writeAll(pattern);
        try writer.writeByte(' ');
        try writer.writeAll(module_name);
        try writer.writeByte('\n');
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

    var aliases: std.Io.Writer.Allocating = .init(allocator);
    errdefer aliases.deinit();

    const modules_alias_file = try modules_dir.openFile(MODULES_ALIAS, .{});
    defer modules_alias_file.close();

    var reader_buf = [_]u8{0} ** 1024;
    var modules_alias_file_reader = modules_alias_file.reader(&reader_buf);
    try appendAliases(&modules_alias_file_reader.interface, &aliases.writer);

    const modules_alias = try modules_alias_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    errdefer allocator.free(modules_alias);

    const params: ParamIndex = b: {
        if (std.fs.cwd().openFile(MODULES_CONF, .{})) |modules_conf_file| {
            defer modules_conf_file.close();

            {
                var reader = modules_conf_file.reader(&reader_buf);
                try appendAliases(&reader.interface, &aliases.writer);
            }

            {
                try modules_conf_file.seekTo(0); // reset position to zero so we can read again.
                var reader = modules_conf_file.reader(&reader_buf);
                break :b try buildParamIndex(allocator, &reader.interface);
            }
        } else |_| {
            break :b .init(allocator);
        }
    };

    const module_index = try buildModuleIndex(allocator, modules_dep);

    return .{
        .allocator = allocator,
        .modules_dir = modules_dir,
        .modules_dep = modules_dep,
        .aliases = try aliases.toOwnedSlice(),
        .params = params,
        .module_index = module_index,
    };
}

pub fn deinit(self: *Kmod) void {
    self.modules_dir.close();
    self.module_index.deinit();
    self.allocator.free(self.modules_dep);
    self.allocator.free(self.aliases);
    self.params.deinit();
}

fn finit_module(
    fd: std.posix.fd_t,
    module_display: []const u8,
    params: [:0]const u8,
    flags: usize,
) !void {
    switch (system.E.init(std.os.linux.syscall3(
        .finit_module,
        @intCast(fd),
        @intFromPtr(params.ptr),
        flags,
    ))) {
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

pub fn insmod(
    self: *Kmod,
    module_filepath: []const u8,
    override_params: ?[]const u8,
) !void {
    const module_basename = std.fs.path.basename(module_filepath);
    const module_stem = std.fs.path.stem(module_basename);
    const module_display = std.fs.path.stem(module_stem);

    log.debug("loading module {s} from /lib/modules/$(uname -r)/{s}", .{ module_display, module_filepath });

    var module_file = try self.modules_dir.openFile(module_filepath, .{});
    defer module_file.close();

    var flags: usize = 0;

    var module_buf = [_]u8{0} ** @max(
        @sizeOf(std.elf.Elf64_Ehdr),
        @sizeOf(std.elf.Elf32_Ehdr),
    );
    var reader = module_file.reader(&module_buf);
    if (std.elf.Header.read(&reader.interface)) |_| {} else |_| {
        // If the module is not a valid ELF file, we assume it is compressed.
        flags |= c.MODULE_INIT_COMPRESSED_FILE;
    }

    var params_buf = [_]u8{0} ** std.fs.max_name_bytes;
    var fpa = std.heap.FixedBufferAllocator.init(&params_buf);
    const allocator = fpa.allocator();

    const params = b: {
        if (override_params) |params| {
            break :b try allocator.dupeZ(u8, params);
        } else if (self.params.get(module_display)) |params| {
            break :b try allocator.dupeZ(u8, params);
        } else {
            // finit_module() accepts an empty string for no params
            break :b "";
        }
    };

    try finit_module(
        module_file.handle,
        module_display,
        params,
        flags,
    );
}

/// Load a kernel module given a module name (or alias) as well as optional
/// module parameters. If override_params is non-null, the module is
/// initialized with those params, otherwise params from /etc/modules.conf are
/// used. This allows for customizing module parameters for all modules, not
/// just the top-level module being loaded, but all transitive modules as well.
pub fn modprobe(
    self: *Kmod,
    module_query: []const u8,
    override_params: ?[]const u8,
) !void {
    var offsets = try findModuleOffsets(
        self.allocator,
        &self.module_index,
        self.aliases,
        module_query,
    );
    defer offsets.deinit();

    if (offsets.count() == 0) {
        return error.UnknownModule;
    }

    for (offsets.keys()) |offset| {
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
            try self.insmod(module_filepath, params);
        } else {
            try self.insmod(module_filepath, null);
        }
    }
}
