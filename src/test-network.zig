const std = @import("std");
const clap = @import("clap");

const params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<config>    The network configuration to apply, as a path to a JSON file.
    \\
);

const parsers = .{ .config = clap.parsers.string };

const netlink = @import("netlink.zig");
const syslog = @import("syslog.zig");

const log = std.log.scoped(.mixos);

/// An interface of a machine taking part in a NixOS VM test, as described by
/// <testing/module.nix>.
const Interface = struct {
    /// The MAC address the interface is found by, since the name the kernel
    /// gives it depends on probe order.
    mac: []const u8,

    /// The name the interface is given.
    name: []const u8,

    /// The addresses assigned to the interface, in CIDR notation.
    addresses: []const []const u8,
};

fn parseAddress(text: []const u8) !struct { std.Io.net.IpAddress, u8 } {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return error.InvalidAddress;

    return .{
        try std.Io.net.IpAddress.parse(text[0..slash], 0),
        try std.fmt.parseInt(u8, text[slash + 1 ..], 10),
    };
}

pub fn main(init: std.process.Init, name: []const u8, args: *std.process.Args.Iterator) anyerror!void {
    syslog.init(name);
    defer syslog.deinit();

    const allocator = init.arena.allocator();

    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &params, parsers, args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.reportToFile(init.io, .stderr(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});
    }

    const config_path = res.positionals[0] orelse {
        try clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});
        return error.InvalidArguments;
    };

    const config_file = try std.Io.Dir.cwd().openFile(init.io, config_path, .{});
    defer config_file.close(init.io);

    var config_reader = config_file.reader(init.io, &.{});
    const config_contents = try config_reader.interface.allocRemaining(allocator, .unlimited);
    const config = try std.json.parseFromSlice([]const Interface, allocator, config_contents, .{});

    const interfaces = config.value;
    const indexes = try allocator.alloc(u32, interfaces.len);

    for (interfaces, indexes) |interface, *index| {
        index.* = try netlink.findInterface(try netlink.parseMacAddress(interface.mac)) orelse {
            log.err("no interface with MAC address {s}", .{interface.mac});
            return error.InterfaceNotFound;
        };
    }

    // Interfaces are renamed in two passes, since the name an interface is
    // destined for may still be held by another one.
    for (indexes) |index| {
        var buf: [std.posix.IFNAMESIZE]u8 = undefined;
        try netlink.setInterfaceName(
            .{ .index = index },
            try std.fmt.bufPrintZ(&buf, "mixos{d}", .{index}),
        );
    }

    for (interfaces, indexes) |interface, index| {
        try netlink.setInterfaceName(
            .{ .index = index },
            try allocator.dupeZ(u8, interface.name),
        );

        try netlink.setInterfaceState(.{ .index = index }, .up);

        for (interface.addresses) |address| {
            const parsed, const prefix_len = try parseAddress(address);
            try netlink.addInterfaceAddress(.{ .index = index }, parsed, prefix_len);
        }
    }
}
