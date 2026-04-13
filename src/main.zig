const log = @import("log.zig");
const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log.logFn,
};

const commands = struct {
    pub const init = @import("init.zig");
    pub const @"test-backdoor" = @import("test-backdoor.zig");
    pub const modprobe = @import("modprobe.zig");
};

pub fn main() !void {
    var args = std.process.args();
    const argv0 = args.next() orelse std.debug.panic("missing argv[0]", .{});

    var name = std.fs.path.basename(argv0);

    var i: usize = 0;
    while (i < 2) : (i += 1) {
        inline for (@typeInfo(commands).@"struct".decls) |decl| {
            if (std.mem.eql(u8, name, std.mem.trimEnd(u8, decl.name, ".zig"))) {
                const command = @field(commands, decl.name);
                return command.main(name, &args);
            }
        }

        name = args.next() orelse return error.MissingCommand;
    }

    return error.UnknownCommand;
}
