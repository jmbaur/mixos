const std = @import("std");

const C = @cImport({
    @cInclude("syslog.h");
    @cInclude("libkmod/libkmod.h");
    @cInclude("kmod-log-wrapper.h");
});

const log = std.log.scoped(.mixos);
const kmod_log = std.log.scoped(.kmod);

const Kmod = @This();

ctx: *C.kmod_ctx,

// Since zig does not have a great story for va_args with C interoperability
// (yet), we provide this function as the userdata to kmod's logging
// infrastructure to a C function that does the processing of va_args.
fn kmodLogUnwrapped(priority: c_int, content: [*c]const u8) callconv(.c) void {
    const log_content = std.mem.trim(u8, std.mem.span(content), &std.ascii.whitespace);

    switch (priority) {
        C.LOG_EMERG, C.LOG_ALERT, C.LOG_CRIT, C.LOG_ERR => kmod_log.err("{s}", .{log_content}),
        C.LOG_WARNING => kmod_log.warn("{s}", .{log_content}),
        C.LOG_NOTICE, C.LOG_INFO => kmod_log.info("{s}", .{log_content}),
        else => kmod_log.debug("{s}", .{log_content}),
    }
}

pub fn init(opts: struct { root: ?[]const u8 = null }) !Kmod {
    const kmod_ctx = (if (opts.root) |path| b: {
        var root = std.mem.zeroes([std.fs.max_path_bytes]u8);
        std.mem.copyForwards(u8, &root, path);
        break :b C.kmod_new(root[0..path.len :0], null);
    } else C.kmod_new(null, null)) orelse return error.KmodNew;

    C.kmod_set_log_fn(kmod_ctx, C.kmod_log_wrapper, &kmodLogUnwrapped);

    // Set the maximum log level so we can do all the filtering on the zig side
    C.kmod_set_log_priority(kmod_ctx, C.LOG_DEBUG);

    if (C.kmod_load_resources(kmod_ctx) != 0) {
        return error.KmodLoadResources;
    }

    return .{
        .ctx = kmod_ctx,
    };
}

pub fn deinit(self: *Kmod) void {
    C.kmod_unload_resources(self.ctx);
    _ = C.kmod_unref(self.ctx);
}

const ModuleClosure = std.StringArrayHashMapUnmanaged(void);

/// Returns the closure kernel module paths given a module query (i.e. the path
/// to a kernel module and the path of all modules it depends on).
pub fn moduleClosure(
    self: *Kmod,
    allocator: std.mem.Allocator,
    module_query: []const u8,
) !ModuleClosure {
    var module_query_buf = std.mem.zeroes([std.fs.max_path_bytes:0]u8);
    std.mem.copyForwards(u8, &module_query_buf, module_query);
    const module_queryz = std.mem.sliceTo(&module_query_buf, 0);

    var closure: ModuleClosure = .empty;

    var list: ?*C.kmod_list = null;
    if (std.enums.fromInt(std.posix.E, @abs(C.kmod_module_new_from_lookup(
        self.ctx,
        module_queryz,
        &list,
    )))) |err| switch (err) {
        .SUCCESS => {},
        .NOENT, .NOSYS => return error.InvalidModuleLookup,
        .INVAL => return error.InvalidModuleAlias,
        else => return std.posix.unexpectedErrno(err),
    } else {
        log.err("unknown error loading module '{s}'", .{module_query});
    }

    const module_list = list orelse return error.ModuleNotFound;
    defer _ = C.kmod_module_unref_list(module_list);

    // NOTE: We skip modules whose module path returns NULL, since that means
    // the module is builtin to the kernel.
    var current_module_list: ?*C.kmod_list = module_list;
    while (current_module_list != null) : (current_module_list = C.kmod_list_next(
        module_list,
        current_module_list,
    )) {
        const module = C.kmod_module_get_module(current_module_list);
        defer _ = C.kmod_module_unref(module);

        const module_path = C.kmod_module_get_path(module);
        if (module_path == null) {
            continue;
        }

        const deps_list = C.kmod_module_get_dependencies(module);
        defer _ = C.kmod_module_unref_list(deps_list);

        var current_deps_list: ?*C.kmod_list = deps_list;
        while (current_deps_list != null) : (current_deps_list = C.kmod_list_next(deps_list, current_deps_list)) {
            const module_dep = C.kmod_module_get_module(current_deps_list);
            defer _ = C.kmod_module_unref(module_dep);

            const dep_module_path = C.kmod_module_get_path(module_dep);
            if (dep_module_path == null) {
                continue;
            }

            try closure.put(allocator, try allocator.dupe(u8, std.mem.span(dep_module_path)), void{});
        }

        try closure.put(allocator, try allocator.dupe(u8, std.mem.span(module_path)), void{});
    }

    return closure;
}

/// Load a kernel module given a module name or alias. All kernel module
/// loading is handled by libkmod.
pub fn modprobe(self: *Kmod, module_query: []const u8) !void {
    var module_query_buf = std.mem.zeroes([std.fs.max_path_bytes:0]u8);
    std.mem.copyForwards(u8, &module_query_buf, module_query);
    const module_queryz = std.mem.sliceTo(&module_query_buf, 0);

    var list: ?*C.kmod_list = null;
    if (std.enums.fromInt(std.posix.E, @abs(C.kmod_module_new_from_lookup(
        self.ctx,
        module_queryz,
        &list,
    )))) |err| switch (err) {
        .SUCCESS => {},
        .NOENT, .NOSYS => return error.InvalidModuleLookup,
        .INVAL => return error.InvalidModuleAlias,
        else => return std.posix.unexpectedErrno(err),
    } else {
        log.err("unknown error loading module '{s}'", .{module_query});
    }

    const module_list = list orelse return error.ModuleNotFound;
    defer _ = C.kmod_module_unref_list(module_list);

    var current_module_list: ?*C.kmod_list = module_list;
    var has_error = false;
    while (current_module_list != null) : (current_module_list = C.kmod_list_next(
        module_list,
        current_module_list,
    )) {
        const module = C.kmod_module_get_module(current_module_list);
        defer _ = C.kmod_module_unref(module);

        const name = std.mem.span(C.kmod_module_get_name(module));

        const module_state = C.kmod_module_get_initstate(module);

        switch (module_state) {
            C.KMOD_MODULE_BUILTIN => {
                log.debug("module is builtin: {s}", .{name});
                continue;
            },
            C.KMOD_MODULE_LIVE => {
                log.debug("module is already loaded: {s}", .{name});
                continue;
            },
            else => {},
        }

        if (std.enums.fromInt(std.posix.E, @abs(C.kmod_module_probe_insert_module(
            module,
            C.KMOD_PROBE_APPLY_BLACKLIST,
            null,
            null,
            null,
            null,
        )))) |err| switch (err) {
            .SUCCESS => {},
            .NOSYS => return error.ModulesNotAvailable,
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
