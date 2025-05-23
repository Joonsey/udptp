//! shared variables between main.zig - the mediation server
//! and test_client.zig - the demonstration client
//!
//! all of the Payload types in this file 'should' be thoroughly documented
//! as they should be compatible with all other languages via basic bytecode serialization
const std = @import("std");
const lib = @import("udptp_lib");

pub const PORT = 8469;

pub const PacketType = enum(u32) {
    host,
    join,
    review_response,
    review_request,
    close,
    req_host_list,
    ret_host_list,

    // inter-client specific values
    ack,
    message,
    keepalive,
};

pub const Packet = lib.Packet(.{ .T = PacketType, .magic_bytes = 0x13800818 });

pub const CloseReason = enum(u8) {
    HOST_QUIT,
    TIMEOUT,
};

pub fn to_fixed(str: []const u8, comptime arr_len: usize) [arr_len]u8 {
    std.debug.assert(str.len <= arr_len);
    var buf: [arr_len]u8 = std.mem.zeroes([arr_len]u8);
    @memcpy(buf[0..str.len], str);
    return buf;
}

test "static string converter" {
    const str = "hello, world!";
    const static_str = to_fixed(str, 15);

    try std.testing.expectEqualSlices(u8, str, static_str[0..str.len]);
    try std.testing.expectEqualStrings(str, static_str[0..str.len]);
}

pub const JoinPayload = extern struct {
    scope: [32]u8,
    key: [32]u8,
};

pub const JoinRequestPayload = extern struct {
    ip: [4]u8,
    port: u16,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}.{}.{}.{}:{}", .{ self.ip[0], self.ip[1], self.ip[2], self.ip[3], self.port });
    }

    // id: [32]u8, // some user identifier, of arbitrary kind
};

pub const ReviewResponsePayload = extern struct {
    result: enum(u8) {
        Accepted,
        Rejected,
        Pending,
    },
    q: JoinPayload,
    join_request: JoinRequestPayload,
};

pub const HostPayload = extern struct {
    q: JoinPayload,
    policy: JoinPolicy = .AutoAccept,
};
pub const ClosePayload = extern struct {
    q: JoinPayload,
    reason: CloseReason,
};
pub const RequestHostListPayload = extern struct {
    scope: [32]u8,
};

pub const JoinPolicy = enum(u8) {
    AutoAccept,
    ManualReview,
    Reject,
};

pub const HostListPayload = extern struct {
    name: [32]u8,
    ip: [4]u8,
    port: u16,
    users: u16,
    capacity: u16,
    policy: JoinPolicy,
};
