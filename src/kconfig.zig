const std = @import("std");

const KconfigSelection = union(enum) {
    unset,
    yes,
    no,
    module,
};

const KconfigEntry = struct {
    name: []const u8,
    selection: KconfigSelection,

    pub fn format(self: *const KconfigEntry, writer: *std.Io.Writer) !void {
        switch (self.selection) {
            .unset => {
                try writer.print("# CONFIG_{s} is not set", .{self.name});
            },
            .yes => {
                try writer.print("CONFIG_{s}=y", .{self.name});
            },
            .no => {
                try writer.print("CONFIG_{s}=n", .{self.name});
            },
            .module => {
                try writer.print("CONFIG_{s}=m", .{self.name});
            },
        }
    }
};

fn parseKconfigLine(line: []const u8) !?KconfigEntry {
    var config_split = std.mem.splitSequence(u8, line, "CONFIG_");
    const first = config_split.next() orelse return null;
    if (std.mem.startsWith(u8, first, "#")) {
        // determine if the config entry is unset
        var whitespace_split = std.mem.splitSequence(u8, config_split.rest(), " ");
        const name = whitespace_split.next() orelse return null;
        if (!std.mem.eql(u8, whitespace_split.rest(), "is not set")) {
            return null;
        }
        return .{
            .name = name,
            .selection = .unset,
        };
    }

    var eq_split = std.mem.splitScalar(u8, config_split.rest(), '=');
    const name = eq_split.next() orelse return null;
    const val = eq_split.next() orelse return null;
    if (std.mem.eql(u8, val, "y")) {
        return .{
            .name = name,
            .selection = .yes,
        };
    }

    if (std.mem.eql(u8, val, "n")) {
        return .{
            .name = name,
            .selection = .no,
        };
    }

    if (std.mem.eql(u8, val, "m")) {
        return .{
            .name = name,
            .selection = .module,
        };
    }

    // TODO(jared): capture non-tristate values (e.g. strings, numbers, etc)
    return null;
}

const Kconfig = std.StringHashMapUnmanaged(KconfigSelection);

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var args = init.minimal.args.iterate();
    defer args.deinit();

    _ = args.next(); // skip argv[0]

    const kconfig_filepath = args.next() orelse return error.MissingArgument;

    var kconfig_file = try std.Io.Dir.cwd().openFile(init.io, kconfig_filepath, .{});
    defer kconfig_file.close(init.io);

    var buf: [1024]u8 = undefined;
    var kconfig_file_reader = kconfig_file.reader(init.io, &buf);
    var reader = &kconfig_file_reader.interface;

    var kconfig: Kconfig = .empty;

    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        reader.toss(1);
        if (std.mem.eql(u8, line, "")) {
            continue;
        }
        if (try parseKconfigLine(line)) |entry| {
            try kconfig.put(allocator, try allocator.dupe(u8, entry.name), entry.selection);
        }
    }

    var assertion_failed = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--assert-yes")) {
            const name = args.next() orelse return error.InvalidArgument;
            const selection = kconfig.get(name) orelse return error.MissingKconfigEntry;
            if (selection != .yes) {
                std.log.err("CONFIG_{s} is not yes", .{name});
                assertion_failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--assert-yes-or-module")) {
            const name = args.next() orelse return error.InvalidArgument;
            const selection = kconfig.get(name) orelse return error.MissingKconfigEntry;
            if (selection != .yes and selection != .module) {
                std.log.err("CONFIG_{s} is not yes or module", .{name});
                assertion_failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--assert-no")) {
            const name = args.next() orelse return error.InvalidArgument;
            const selection = kconfig.get(name) orelse return error.MissingKconfigEntry;
            if (selection != .no) {
                std.log.err("CONFIG_{s} is not no", .{name});
                assertion_failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--assert-unset")) {
            const name = args.next() orelse return error.InvalidArgument;
            const selection = kconfig.get(name) orelse continue; // consider entries not present to be unset
            if (selection != .unset) {
                std.log.err("CONFIG_{s} is not unset", .{name});
                assertion_failed = true;
            }
        } else {
            return error.InvalidArgument;
        }
    }

    if (assertion_failed) {
        return error.KconfigAssertionFailed;
    }
}
