const builtin = @import("builtin");
const std = @import("std");
const system = std.posix.system;

const C = @cImport({
    @cInclude("syslog.h");
    @cInclude("libkmod/libkmod.h");
});

const log = std.log.scoped(.mixos);
const kmod_log = std.log.scoped(.kmod);

const Kmod = @This();

ctx: *C.kmod_ctx,

allocator: std.mem.Allocator,

extern fn kmod_log_wrapper(
    ?*anyopaque,
    c_int,
    [*c]const u8,
    c_int,
    [*c]const u8,
    [*c]const u8,
    [*c]C.struct___va_list_tag_1,
) callconv(.c) void;

// Since zig does not have a great story for va_args with C interoperability,
// we provide this function as the userdata to kmod's logging infrastructure to
// a C function that does the processing of va_args.
fn kmod_log_unwrapped(priority: c_int, content: [*c]const u8) callconv(.c) void {
    const log_content = std.mem.trim(u8, std.mem.span(content), &std.ascii.whitespace);

    switch (priority) {
        C.LOG_EMERG, C.LOG_ALERT, C.LOG_CRIT, C.LOG_ERR => kmod_log.err("{s}", .{log_content}),
        C.LOG_WARNING => kmod_log.warn("{s}", .{log_content}),
        C.LOG_NOTICE, C.LOG_INFO => kmod_log.info("{s}", .{log_content}),
        else => kmod_log.debug("{s}", .{log_content}),
    }
}

pub fn init(allocator: std.mem.Allocator) !Kmod {
    const kmod_ctx = C.kmod_new(null, null) orelse return error.KmodNew;

    C.kmod_set_log_fn(kmod_ctx, kmod_log_wrapper, &kmod_log_unwrapped);

    // Set the maximum log level so we can do all the filtering on the zig side
    C.kmod_set_log_priority(kmod_ctx, C.LOG_DEBUG);

    if (C.kmod_load_resources(kmod_ctx) != 0) {
        return error.KmodLoadResources;
    }

    return .{
        .ctx = kmod_ctx,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Kmod) void {
    C.kmod_unload_resources(self.ctx);
    _ = C.kmod_unref(self.ctx);
}

/// Load a kernel module given a module name or alias. All kernel module
/// loading is handled by libkmod.
pub fn modprobe(self: *Kmod, module_query: []const u8) !void {
    var module_query_buf = std.mem.zeroes([std.fs.max_path_bytes:0]u8);
    std.mem.copyForwards(u8, &module_query_buf, module_query);
    const module_queryz = std.mem.sliceTo(&module_query_buf, 0);

    var list: ?*C.kmod_list = null;
    if (std.enums.fromInt(std.posix.E, @abs(C.kmod_module_new_from_lookup(self.ctx, module_queryz, &list)))) |err| switch (err) {
        .SUCCESS => {},
        .NOENT, .NOSYS => return error.InvalidModuleLookup,
        .INVAL => return error.InvalidModuleAlias,
        else => return std.posix.unexpectedErrno(err),
    } else {
        log.err("unknown error loading module '{s}'", .{module_query});
    }

    const module_list = list orelse return error.ModuleNotFound;
    defer {
        _ = C.kmod_module_unref_list(module_list);
    }

    var current_module_list: ?*C.kmod_list = module_list;
    var has_error = false;
    while (current_module_list != null) : (current_module_list = C.kmod_list_next(module_list, current_module_list)) {
        const module = C.kmod_module_get_module(current_module_list);
        defer {
            _ = C.kmod_module_unref(module);
        }

        const name = std.mem.span(C.kmod_module_get_name(module));

        if (std.enums.fromInt(std.posix.E, @abs(C.kmod_module_probe_insert_module(
            module,
            C.KMOD_PROBE_APPLY_BLACKLIST_ALIAS_ONLY,
            null,
            null,
            null,
            null,
        )))) |err| switch (err) {
            .SUCCESS => {},
            else => {
                log.err("failed to load module {s}: {}", .{ name, err });
                has_error = true;
            },
        } else {
            log.err("unknown error loading module {s}", .{name});
            has_error = true;
        }
    }

    if (has_error) {
        return error.LoadModuleFailed;
    }
}
