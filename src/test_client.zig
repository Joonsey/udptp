//! A sample test client for demonstration & testing purposes
//! is not included in primary server build binary
//!
//! let it be known it is extremely incomplete. But it serves it's function
//! as a demonstration for how one could set up a simple, direct peer-to-peer client.
//!
//! List of features it does NOT include (as of now):
//!     - keeping track off if peer has disconnected
//!     - proper closing (just let's TIMEOUT handle it)
//!     - really treat all different cases

const std = @import("std");
const lib = @import("udptp_lib");
const shared = @import("shared.zig");
const builtin = @import("builtin");

const JoinPolicy = shared.JoinPolicy;
const PacketType = shared.PacketType;
const CloseReason = shared.CloseReason;

const Packet = shared.Packet;
const HostPayload = shared.HostPayload;
const JoinPayload = shared.JoinPayload;
const ReviewResponsePayload = shared.ReviewResponsePayload;
const ClosePayload = shared.ClosePayload;
const RequestHostListPayload = shared.RequestHostListPayload;
const HostListPayload = shared.HostListPayload;

const PORT = shared.PORT;
const to_fixed = shared.to_fixed;

const IP = "127.0.0.1";
const localhost = std.mem.eql(u8, IP, "127.0.0.1");

const StateEnum = union(enum) {
    Mediating: void,
    PeerToPeerEstablished: void,
    ReviewRequest: ReviewResponsePayload,
};

const State = struct {
    should_stop: bool = false,

    /// the scope of the client. I.E what 'application' we are looking for
    scope: [32]u8,
    policy: JoinPolicy = .ManualReview,
    state: StateEnum = .Mediating,

    /// the other peer who we are connecting to
    /// not to be confused with client.target which is in THIS PARTICULAR IMPLEMENTATION
    /// always going to be the mediation server.
    peer: ?lib.network.EndPoint = null,

    allocator: std.mem.Allocator,
    /// list of lobbies synced from the mediation server
    lobbies: std.ArrayListUnmanaged(HostListPayload) = .{},

    const Self = @This();
    fn init(allocator: std.mem.Allocator, scope: [32]u8) Self {
        return .{
            .allocator = allocator,
            .scope = scope,
        };
    }
};

const Client = lib.Client(State);

/// this sample function is really all that is needed to get started handling the standard information from the mediation server
fn handle_packet(self: *Client, data: []const u8, sender: lib.network.EndPoint) !void {
    var state = self.ctx;
    var packet = Packet.deserialize(data, self.allocator) catch return error.BadInput;
    defer packet.free(self.allocator);

    switch (packet.header.packet_type) {
        .ret_host_list => {
            const payload_individual_size = @sizeOf(HostListPayload);
            const c = packet.header.payload_size / payload_individual_size;

            // potential memory desync here
            state.lobbies.clearAndFree(self.allocator);
            for (0..c) |i| {
                const host = try lib.deserialize_payload(packet.payload[i * payload_individual_size .. (i + 1) * payload_individual_size], HostListPayload);
                try state.lobbies.append(self.allocator, host);
            }

            for (state.lobbies.items) |lobby| std.log.info("\t{d}.{d}.{d}.{d}:{d} {d}/{d} {any} {s}", .{
                lobby.ip[0],
                lobby.ip[1],
                lobby.ip[2],
                lobby.ip[3],
                lobby.port,
                lobby.users,
                lobby.capacity,
                lobby.policy,
                lobby.name,
            });
        },
        .review_request => {
            const review_request = try lib.deserialize_payload(packet.payload, ReviewResponsePayload);
            switch (self.ctx.policy) {
                .AutoAccept => {
                    self.ctx.peer = .{ .address = .{ .ipv4 = .{ .value = review_request.join_request.ip } }, .port = review_request.join_request.port };

                    const ack_packet = try Packet.init(.ack, "hey");
                    const ack_data = try ack_packet.serialize(self.allocator);
                    self.sendto(self.ctx.peer.?, ack_data);
                    self.allocator.free(ack_data);
                },
                .ManualReview => {
                    self.ctx.state = .{ .ReviewRequest = review_request };
                    std.log.info("got a request to join from {any}", .{review_request.join_request});
                    std.log.info("type 'yes' or 'no' to respond", .{});
                },
                else => {},
            }
        },
        .ack => {
            if (self.ctx.state != .PeerToPeerEstablished) {
                self.ctx.peer = sender;
                // We send one additional round-trip as the first packet is presumed to be lost to punching a hole in the NAT
                self.ctx.state = .PeerToPeerEstablished;
                std.log.info("connected through peer-to-peer with {any}", .{sender});
                self.sendto(self.ctx.peer.?, data);
            }
        },
        .close => {
            const close = try lib.deserialize_payload(packet.payload, ClosePayload);
            std.log.info("lobby ({s}:{s}) closed with reason! {any}", .{ close.q.scope, close.q.key, close.reason });

            switch (close.reason) {
                .HOST_QUIT => {
                    self.ctx.state = .Mediating;
                    self.target = .{
                        .address = lib.network.Address.parse(IP) catch unreachable,
                        .port = PORT,
                    };
                },
                .TIMEOUT => {},
            }
        },
        .message => {
            if (self.ctx.state == .PeerToPeerEstablished) {
                std.log.info("{any}: {s}", .{ sender, packet.payload });
            }
        },
        else => return error.BadInput,
    }
}

const Commands = enum {
    Quit,
    q,
    Host,
    h,
    Join,
    j,
    UpdateHostList,
    u,
    Close,
    c,
    Help,
};

const ReviewOptions = enum {
    Y,
    y,
    yes,
    N,
    n,
    no,
};

fn handle_stdin(self: *Client) void {
    const stdin = std.io.getStdIn();
    var buffer: [2048]u8 = undefined;
    const reader = stdin.reader();
    const stdin_buffer = reader.readUntilDelimiterOrEof(&buffer, '\n') catch unreachable;
    const data_pre_prune = stdin_buffer orelse "Q";
    // we need to prune the random '\r' character on windows stdio
    const data = if (builtin.os.tag == .windows) data_pre_prune[0 .. data_pre_prune.len - 1] else data_pre_prune;

    switch (self.ctx.state) {
        .Mediating => {
            const separator = std.mem.indexOfScalar(u8, data, ' ') orelse data.len;
            const pruned_argument = if (separator == data.len) data[separator..] else data[separator + 1 ..];

            if (std.meta.stringToEnum(Commands, data[0..separator])) |cmd| handle_command(self, cmd, pruned_argument) catch unreachable;
        },
        .PeerToPeerEstablished => {
            const packet = Packet.init(.message, data) catch unreachable;
            const message = packet.serialize(self.allocator) catch unreachable;
            self.sendto(self.ctx.peer.?, message);
            self.allocator.free(message);
        },
        .ReviewRequest => |review| {
            if (std.meta.stringToEnum(ReviewOptions, data)) |response| {
                var packet_buffer: [512]u8 = undefined;
                var review_copy = review;
                switch (response) {
                    .yes, .y, .Y => {
                        review_copy.result = .Accepted;
                        self.ctx.state = .PeerToPeerEstablished;
                    },
                    .no, .n, .N => {
                        review_copy.result = .Rejected;
                        self.ctx.state = .Mediating;
                    },
                }

                const payload = lib.serialize_payload(&packet_buffer, review_copy) catch unreachable;
                const packet = Packet.init(.review_response, payload) catch unreachable;
                const review_result_data = packet.serialize(self.allocator) catch unreachable;
                self.send(review_result_data);
                self.allocator.free(review_result_data);

                switch (response) {
                    .yes, .y, .Y => {
                        const nat_punch_packet = Packet.init(.ack, "hey") catch unreachable;
                        const nat_punch_data = nat_punch_packet.serialize(self.allocator) catch unreachable;
                        self.ctx.peer = .{ .address = .{ .ipv4 = .{ .value = review.join_request.ip } }, .port = review.join_request.port };
                        self.sendto(self.ctx.peer.?, nat_punch_data);
                        self.allocator.free(nat_punch_data);
                        std.log.info("accepted request", .{});
                        std.log.info("connected through peer-to-peer with {any}", .{review.join_request});
                    },
                    else => {},
                }
            } else {
                std.log.err("Type 'yes' or 'no' to accept request", .{});
            }
        },
    }
}

fn handle_command(self: *Client, cmd: Commands, arguments: []const u8) !void {
    var packet_buffer: [512]u8 = undefined;
    switch (cmd) {
        .Quit, .q => self.ctx.should_stop = true,
        .Host, .h => {
            if (arguments.len < 1 or arguments.len > 32) {
                std.log.err("argument for HOST must be between 1<32. got {d}", .{arguments.len});
                return;
            }
            const packet = try Packet.init(.host, try lib.serialize_payload(&packet_buffer, HostPayload{
                .q = .{ .scope = self.ctx.scope, .key = to_fixed(arguments, 32) },
                .policy = self.ctx.policy,
            }));
            const data = try packet.serialize(self.allocator);
            self.send(data);
            self.allocator.free(data);
            std.log.info("hosted new server at: {s}:{s}", .{ self.ctx.scope, arguments });
        },
        .Join, .j => {
            const lobby_idx = std.fmt.parseInt(usize, arguments, 10) catch {
                std.log.err("argument for JOIN must be a valid integer. got {s}", .{arguments});
                return;
            };
            if (lobby_idx < 1 or lobby_idx > self.ctx.lobbies.items.len) {
                std.log.err("argument for HOST must be between 1<{d}. got {d}", .{ self.ctx.lobbies.items.len, arguments.len });
                return;
            }

            const lobby = self.ctx.lobbies.items[lobby_idx - 1];
            const packet = try Packet.init(.join, try lib.serialize_payload(&packet_buffer, JoinPayload{ .scope = self.ctx.scope, .key = lobby.name }));
            const data = try packet.serialize(self.allocator);
            self.send(data);
            self.allocator.free(data);

            switch (lobby.policy) {
                .AutoAccept => std.log.info("joined via auto accept {s}:{s}", .{ self.ctx.scope, lobby.name }),
                .Reject => std.log.err("rejected (this is a private lobby)", .{}),
                .ManualReview => std.log.info("sendt request to join {s}:{s}", .{ self.ctx.scope, lobby.name }),
            }

            switch (lobby.policy) {
                .AutoAccept => {
                    const nat_punch_packet = try Packet.init(.ack, "hey");
                    const nat_punch_data = try nat_punch_packet.serialize(self.allocator);
                    self.ctx.peer = .{ .address = .{ .ipv4 = .{ .value = lobby.ip } }, .port = lobby.port };
                    self.sendto(self.ctx.peer.?, nat_punch_data);
                    self.allocator.free(nat_punch_data);
                },
                .ManualReview => {
                    // we can skip this if we are localhost. As we don't actually need to punch through the NAT
                    if (!localhost) {
                        const nat_punch_packet = try Packet.init(.ack, "hey");
                        const nat_punch_data = try nat_punch_packet.serialize(self.allocator);
                        self.ctx.peer = .{ .address = .{ .ipv4 = .{ .value = lobby.ip } }, .port = lobby.port };
                        self.sendto(self.ctx.peer.?, nat_punch_data);
                        self.allocator.free(nat_punch_data);
                    }
                },
                .Reject => {},
            }
        },
        .UpdateHostList, .u => {
            const packet = try Packet.init(.req_host_list, try lib.serialize_payload(&packet_buffer, RequestHostListPayload{ .scope = self.ctx.scope }));
            const data = try packet.serialize(self.allocator);
            self.send(data);
            self.allocator.free(data);
        },
        .Help => {
            std.log.info("Available commands\nQ - Quit\nHost <host key> - hosts a lobby\nJoin <host list index> - joins a lobby\nUpdateHostList - updates host list\nClose - closes hosted session\nHelp - brings up this", .{});
        },
        else => {
            std.log.info("{any}: {s}", .{ cmd, arguments });
        },
    }
}

fn keep_alive(client: *Client) !void {
    const packet = try Packet.init(.keepalive, "peep");
    const data = try packet.serialize(client.allocator);
    client.send(data);
    client.allocator.free(data);
}

fn listen_thread(client: *Client) !void {
    while (!client.ctx.should_stop) {
        try keep_alive(client);
        client.listen() catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
    }
}

pub fn main() !void {
    var GPA = std.heap.DebugAllocator(.{}).init;
    const allocator = GPA.allocator();

    var state = State.init(allocator, to_fixed("test_client", 32));
    var client = try Client.init(allocator, &state);

    client.handle_packet_cb = handle_packet;
    try client.socket.setReadTimeout(0.5 * std.time.us_per_s);

    var buffer: [512]u8 = undefined;
    const packet = try Packet.init(.req_host_list, try lib.serialize_payload(&buffer, RequestHostListPayload{ .scope = state.scope }));
    const data = try packet.serialize(allocator);
    try client.connect(IP, PORT, data);

    std.log.info("client connecting... with scope {s}", .{state.scope});
    const thread = try std.Thread.spawn(.{ .allocator = allocator }, listen_thread, .{&client});
    while (!state.should_stop) {
        handle_stdin(&client);
    }

    thread.join();
    std.log.info("gracefully exited", .{});
}
