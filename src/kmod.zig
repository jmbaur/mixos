const builtin = @import("builtin");
const std = @import("std");
const system = std.posix.system;

const c = @cImport({
    @cInclude("libkmod/libkmod.h");
});

const log = std.log.scoped(.mixos);

const Kmod = @This();

ctx: *c.kmod_ctx,

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !Kmod {
    const kmod_ctx = c.kmod_new(null, null) orelse return error.KmodNew;
    if (c.kmod_load_resources(kmod_ctx) != 0) {
        return error.KmodLoadResources;
    }

    return .{
        .ctx = kmod_ctx,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Kmod) void {
    c.kmod_unload_resources(self.ctx);
    _ = c.kmod_unref(self.ctx);
}

/// Load a kernel module given a module name or alias. All kernel module
/// loading is handled by libkmod.
pub fn modprobe(
    self: *Kmod,
    module_query: []const u8,
) !void {
    var module_query_buf = std.mem.zeroes([std.fs.max_path_bytes:0]u8);
    std.mem.copyForwards(u8, &module_query_buf, module_query);
    const module_queryz = std.mem.sliceTo(&module_query_buf, 0);

    var list: ?*c.kmod_list = null;
    if (std.enums.fromInt(std.posix.E, @abs(c.kmod_module_new_from_lookup(self.ctx, module_queryz, &list)))) |err| switch (err) {
        .SUCCESS => {},
        .NOENT, .NOSYS => return error.InvalidModuleLookup,
        .INVAL => return error.InvalidModuleAlias,
        else => return std.posix.unexpectedErrno(err),
    } else {
        log.err("unknown error loading module '{s}'", .{module_query});
    }

    const module_list = list orelse return error.ModuleNotFound;
    defer {
        _ = c.kmod_module_unref_list(module_list);
    }

    var current_module_list: ?*c.kmod_list = module_list;
    while (current_module_list != null) : (current_module_list = c.kmod_list_next(module_list, current_module_list)) {
        const module = c.kmod_module_get_module(current_module_list);
        defer {
            _ = c.kmod_module_unref(module);
        }

        const name = std.mem.span(c.kmod_module_get_name(module));

        if (std.enums.fromInt(std.posix.E, @abs(c.kmod_module_probe_insert_module(
            module,
            c.KMOD_PROBE_APPLY_BLACKLIST_ALIAS_ONLY,
            null,
            null,
            null,
            null,
        )))) |err| switch (err) {
            .SUCCESS => {},
            else => {
                log.err("failed to load module {s}: {}", .{ name, err });
            },
        } else {
            log.err("unknown error loading module {s}", .{name});
        }
    }
}
