const std = @import("std");

const C = @cImport({
    @cInclude("libmnl/libmnl.h");
    @cInclude("linux/netlink.h");
    @cInclude("linux/rtnetlink.h");
    @cInclude("net/if.h");
    @cInclude("time.h");
});

pub fn setInterfaceState(ifname: [:0]const u8, state: enum { up, down }) !void {
    var buf: [std.heap.page_size_min]u8 align(C.MNL_ALIGNTO) = undefined;

    const seq: c_uint = @intCast(C.time(null));

    const nlh = @as(?*C.nlmsghdr, @ptrCast(@alignCast(C.mnl_nlmsg_put_header(
        @ptrCast(&buf),
    )))) orelse return error.MnlPutHeader;
    nlh.nlmsg_type = C.RTM_NEWLINK;
    nlh.nlmsg_flags = C.NLM_F_REQUEST | C.NLM_F_ACK;
    nlh.nlmsg_seq = seq;

    var ifm = @as(?*C.ifinfomsg, @ptrCast(@alignCast(C.mnl_nlmsg_put_extra_header(
        nlh,
        @sizeOf(C.ifinfomsg),
    )))) orelse return error.MnlPutExtraHeader;
    ifm.ifi_family = C.AF_UNSPEC;
    ifm.ifi_change = C.IFF_UP;
    ifm.ifi_flags = switch (state) {
        .up => C.IFF_UP,
        .down => 0 & ~C.IFF_UP,
    };

    C.mnl_attr_put_str(nlh, C.IFLA_IFNAME, ifname);

    const nl = C.mnl_socket_open(C.NETLINK_ROUTE) orelse return error.MnlSocketOpen;
    defer _ = C.mnl_socket_close(nl);

    if (C.mnl_socket_bind(nl, 0, C.MNL_SOCKET_AUTOPID) < 0) {
        return error.MnlSocketBind;
    }

    const portid = C.mnl_socket_get_portid(nl);

    if (C.mnl_socket_sendto(nl, nlh, nlh.nlmsg_len) < 0) {
        return error.MnlSocketSendto;
    }

    const ret = C.mnl_socket_recvfrom(nl, @ptrCast(&buf), buf.len);
    if (ret == -1) {
        return error.MnlSocketRecvfrom;
    }

    if (C.mnl_cb_run(@ptrCast(&buf), @intCast(ret), seq, portid, null, null) == -1) {
        return error.MnlCbRun;
    }
}

pub fn main(init: std.process.Init) !void {
    var iter = init.minimal.args.iterate();
    _ = iter.next();
    const ifname = iter.next() orelse return error.InvalidArguments;
    const state = iter.next() orelse return error.InvalidArguments;
    try setInterfaceState(
        try init.arena.allocator().dupeZ(u8, ifname),
        if (std.mem.eql(u8, state, "up"))
            .up
        else if (std.mem.eql(u8, state, "down"))
            .down
        else
            return error.InvalidArguments,
    );
}
