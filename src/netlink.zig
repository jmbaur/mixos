const std = @import("std");

const C = @cImport({
    @cInclude("libmnl/libmnl.h");
    @cInclude("linux/netlink.h");
    @cInclude("linux/rtnetlink.h");
    @cInclude("net/if.h");
    @cInclude("time.h");
});

pub const mac_address_len = 6;

pub const MacAddress = [mac_address_len]u8;

/// What MNL_SOCKET_BUFFER_SIZE evaluates to on any page size we care about.
/// The macro itself calls sysconf(), so it is not usable from here.
const buffer_size = 8192;

const Buffer = [buffer_size]u8;

const BufferPointer = *align(C.MNL_ALIGNTO) Buffer;

/// Identifies an interface either by the name it currently has or by the index
/// the kernel gave it. The index is what survives a rename.
pub const Interface = union(enum) {
    name: [:0]const u8,
    index: u32,
};

const Socket = struct {
    nl: *C.mnl_socket,
    portid: c_uint,

    fn open() !Socket {
        const nl = C.mnl_socket_open(C.NETLINK_ROUTE) orelse return error.MnlSocketOpen;
        errdefer _ = C.mnl_socket_close(nl);

        if (C.mnl_socket_bind(nl, 0, C.MNL_SOCKET_AUTOPID) < 0) {
            return error.MnlSocketBind;
        }

        return .{ .nl = nl, .portid = C.mnl_socket_get_portid(nl) };
    }

    fn close(self: Socket) void {
        _ = C.mnl_socket_close(self.nl);
    }

    fn send(self: Socket, nlh: *C.nlmsghdr) !void {
        if (C.mnl_socket_sendto(self.nl, nlh, nlh.nlmsg_len) < 0) {
            return error.MnlSocketSendto;
        }
    }

    fn receive(self: Socket, buf: BufferPointer, seq: c_uint, callback: C.mnl_cb_t, data: ?*anyopaque) !c_int {
        const ret = C.mnl_socket_recvfrom(self.nl, @ptrCast(buf), buf.len);
        if (ret == -1) {
            return error.MnlSocketRecvfrom;
        }

        const status = C.mnl_cb_run(@ptrCast(buf), @intCast(ret), seq, self.portid, callback, data);
        if (status == -1) {
            return error.MnlCbRun;
        }

        return status;
    }

    /// Sends a request and waits for the kernel to acknowledge it.
    fn request(self: Socket, buf: BufferPointer, nlh: *C.nlmsghdr) !void {
        try self.send(nlh);
        _ = try self.receive(buf, nlh.nlmsg_seq, null, null);
    }
};

fn putHeader(buf: BufferPointer, nlmsg_type: u16, nlmsg_flags: u16) !*C.nlmsghdr {
    const nlh = @as(?*C.nlmsghdr, @ptrCast(@alignCast(C.mnl_nlmsg_put_header(
        @ptrCast(buf),
    )))) orelse return error.MnlPutHeader;

    nlh.nlmsg_type = nlmsg_type;
    nlh.nlmsg_flags = nlmsg_flags;
    nlh.nlmsg_seq = @intCast(C.time(null));

    return nlh;
}

fn putExtraHeader(nlh: *C.nlmsghdr, comptime T: type) !*T {
    return @as(?*T, @ptrCast(@alignCast(C.mnl_nlmsg_put_extra_header(
        nlh,
        @sizeOf(T),
    )))) orelse error.MnlPutExtraHeader;
}

fn putInterface(nlh: *C.nlmsghdr, ifm: *C.ifinfomsg, interface: Interface) void {
    switch (interface) {
        .name => |name| C.mnl_attr_put_str(nlh, C.IFLA_IFNAME, name),
        .index => |index| ifm.ifi_index = @intCast(index),
    }
}

pub fn setInterfaceState(interface: Interface, state: enum { up, down }) !void {
    var buf: Buffer align(C.MNL_ALIGNTO) = undefined;

    const nlh = try putHeader(&buf, C.RTM_NEWLINK, C.NLM_F_REQUEST | C.NLM_F_ACK);

    const ifm = try putExtraHeader(nlh, C.ifinfomsg);
    ifm.ifi_family = C.AF_UNSPEC;
    ifm.ifi_change = C.IFF_UP;
    ifm.ifi_flags = switch (state) {
        .up => C.IFF_UP,
        .down => 0 & ~C.IFF_UP,
    };

    putInterface(nlh, ifm, interface);

    const socket = try Socket.open();
    defer socket.close();

    try socket.request(&buf, nlh);
}

/// Renames an interface. The kernel only allows this while the interface is
/// down, and while no other interface holds the new name.
pub fn setInterfaceName(interface: Interface, name: [:0]const u8) !void {
    var buf: Buffer align(C.MNL_ALIGNTO) = undefined;

    const nlh = try putHeader(&buf, C.RTM_NEWLINK, C.NLM_F_REQUEST | C.NLM_F_ACK);

    const ifm = try putExtraHeader(nlh, C.ifinfomsg);
    ifm.ifi_family = C.AF_UNSPEC;

    putInterface(nlh, ifm, interface);
    C.mnl_attr_put_str(nlh, C.IFLA_IFNAME, name);

    const socket = try Socket.open();
    defer socket.close();

    try socket.request(&buf, nlh);
}

pub fn addInterfaceAddress(interface: Interface, address: std.Io.net.IpAddress, prefix_len: u8) !void {
    var buf: Buffer align(C.MNL_ALIGNTO) = undefined;

    const nlh = try putHeader(
        &buf,
        C.RTM_NEWADDR,
        C.NLM_F_REQUEST | C.NLM_F_ACK | C.NLM_F_CREATE | C.NLM_F_REPLACE,
    );

    const ifa = try putExtraHeader(nlh, C.ifaddrmsg);
    ifa.ifa_family = @intCast(switch (address) {
        .ip4 => C.AF_INET,
        .ip6 => C.AF_INET6,
    });
    ifa.ifa_prefixlen = prefix_len;
    ifa.ifa_scope = C.RT_SCOPE_UNIVERSE;
    ifa.ifa_index = switch (interface) {
        .index => |index| index,
        // An address can only be added to an interface by index, since
        // ifaddrmsg has no room for a name.
        .name => |name| C.if_nametoindex(name),
    };

    // The bytes of an IpAddress are already in network byte order.
    switch (address) {
        .ip4 => |ip4| {
            C.mnl_attr_put(nlh, C.IFA_LOCAL, ip4.bytes.len, &ip4.bytes);
            C.mnl_attr_put(nlh, C.IFA_ADDRESS, ip4.bytes.len, &ip4.bytes);
        },
        .ip6 => |ip6| {
            C.mnl_attr_put(nlh, C.IFA_ADDRESS, ip6.bytes.len, &ip6.bytes);
        },
    }

    const socket = try Socket.open();
    defer socket.close();

    try socket.request(&buf, nlh);
}

const Search = struct {
    mac_address: MacAddress,
    index: ?u32 = null,
    matched: bool = false,
};

fn searchAttribute(attr: ?*const C.nlattr, data: ?*anyopaque) callconv(.c) c_int {
    const search: *Search = @ptrCast(@alignCast(data.?));

    if (C.mnl_attr_get_type(attr) == C.IFLA_ADDRESS and
        C.mnl_attr_get_payload_len(attr) == mac_address_len)
    {
        const payload: [*]const u8 = @ptrCast(C.mnl_attr_get_payload(attr));
        search.matched = std.mem.eql(u8, payload[0..mac_address_len], &search.mac_address);
    }

    return C.MNL_CB_OK;
}

fn searchLink(nlh: ?*const C.nlmsghdr, data: ?*anyopaque) callconv(.c) c_int {
    const search: *Search = @ptrCast(@alignCast(data.?));

    if (search.index != null) {
        return C.MNL_CB_OK;
    }

    const ifm: *const C.ifinfomsg = @ptrCast(@alignCast(C.mnl_nlmsg_get_payload(nlh)));

    search.matched = false;
    _ = C.mnl_attr_parse(nlh, @sizeOf(C.ifinfomsg), searchAttribute, search);

    if (search.matched) {
        search.index = @intCast(ifm.ifi_index);
    }

    return C.MNL_CB_OK;
}

/// Looks up the index of the interface with the given MAC address, which is
/// the only handle on an interface that a rename does not invalidate.
pub fn findInterface(mac_address: MacAddress) !?u32 {
    var buf: Buffer align(C.MNL_ALIGNTO) = undefined;

    const nlh = try putHeader(&buf, C.RTM_GETLINK, C.NLM_F_REQUEST | C.NLM_F_DUMP);

    const ifm = try putExtraHeader(nlh, C.ifinfomsg);
    ifm.ifi_family = C.AF_UNSPEC;

    const socket = try Socket.open();
    defer socket.close();

    try socket.send(nlh);

    var search: Search = .{ .mac_address = mac_address };
    while (try socket.receive(&buf, nlh.nlmsg_seq, searchLink, &search) > C.MNL_CB_STOP) {}

    return search.index;
}

pub fn parseMacAddress(text: []const u8) !MacAddress {
    var mac_address: MacAddress = undefined;

    var octets = std.mem.splitScalar(u8, text, ':');
    for (&mac_address) |*octet| {
        octet.* = try std.fmt.parseInt(u8, octets.next() orelse return error.InvalidMacAddress, 16);
    }

    if (octets.next() != null) {
        return error.InvalidMacAddress;
    }

    return mac_address;
}

test parseMacAddress {
    try std.testing.expectEqual(
        [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x01, 0x02 },
        try parseMacAddress("52:54:00:12:01:02"),
    );
    try std.testing.expectError(error.InvalidMacAddress, parseMacAddress("52:54:00:12:01"));
    try std.testing.expectError(error.InvalidMacAddress, parseMacAddress("52:54:00:12:01:02:03"));
}
