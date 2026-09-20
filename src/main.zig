const build_options = @import("build_options");
const clap = @import("clap");
const log = @import("log.zig");
const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log.logFn,
};

const commands = struct {
    pub const @"switch-root" = @import("switch-root.zig");
    pub const @"test-backdoor" = @import("test-backdoor.zig");
    pub const @"test-network" = @import("test-network.zig");
    pub const init = @import("init.zig");
    pub const modprobe = @import("modprobe.zig");
    pub const shutdown = @import("shutdown.zig");
};

const command_decls = @typeInfo(commands).@"struct".decls;

/// The commands above, as something clap can parse an argument into. Built
/// from the same declarations that are dispatched to, so there is no second
/// list to keep in step.
const Command = std.meta.DeclEnum(commands);

const command_names = b: {
    var names: []const u8 = "";

    for (command_decls, 0..) |decl, i| {
        names = names ++ (if (i == 0) "" else ", ") ++ decl.name;
    }

    break :b names;
};

const params = clap.parseParamsComptime(
    \\-h, --help     Display this help and exit.
    \\-V, --version  Output version information and exit.
    \\<command>      The command to run, and then its own arguments.
    \\
);

const parsers = .{ .command = clap.parsers.enumeration(Command) };

fn run(
    command: Command,
    init: std.process.Init,
    args: *std.process.Args.Iterator,
) anyerror!void {
    inline for (command_decls) |decl| {
        if (command == @field(Command, decl.name)) {
            return @field(commands, decl.name).main(init, decl.name, args);
        }
    }

    unreachable;
}

fn printVersion(io: std.Io, file: std.Io.File) !void {
    var buf: [256]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.print("mixos {s}\n", .{build_options.version});
    try writer.interface.flush();
}

fn listCommands(io: std.Io, file: std.Io.File) !void {
    try clap.helpToFile(io, file, clap.Help, &params, .{});

    var buf: [256]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.print("\ncommands: {s}\n", .{command_names});
    try writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    const argv0 = args.next() orelse std.debug.panic("missing argv[0]", .{});

    if (std.meta.stringToEnum(Command, std.fs.path.basename(argv0))) |command| {
        return run(command, init, &args);
    }

    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &params, parsers, &args, .{
        .diagnostic = &diag,
        .allocator = init.arena.allocator(),
        // Stop at the command, leaving the rest of the arguments in the
        // iterator for the command itself to make sense of.
        .terminating_positional = 0,
    }) catch |err| {
        diag.reportToFile(init.io, .stderr(), err) catch {};
        listCommands(init.io, .stderr()) catch {};
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return listCommands(init.io, .stdout());
    }

    if (res.args.version != 0) {
        return printVersion(init.io, .stdout());
    }

    const command = res.positionals[0] orelse {
        listCommands(init.io, .stderr()) catch {};
        std.process.exit(1);
    };

    return run(command, init, &args);
}
