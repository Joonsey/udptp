//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const lib = @import("udptp_lib");
const shared = @import("shared.zig");

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

const Lobby = struct {
    host_idx: usize = 0,
    members: std.ArrayListUnmanaged(lib.network.EndPoint) = .{},
    join_policy: JoinPolicy = .AutoAccept,

    fn deinit(self: *Lobby, allocator: std.mem.Allocator) void {
        self.members.deinit(allocator);
    }
};

const Scope = struct {
    lobbies: std.StringHashMapUnmanaged(Lobby) = .{},

    fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        var iter = self.lobbies.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }

        self.lobbies.clearAndFree(allocator);
    }
};

const State = struct {
    /// map of all scopes
    scopes: std.StringHashMapUnmanaged(Scope),

    /// if the server should stop
    should_stop: bool = false,

    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) State {
        return .{
            .scopes = .{},
            .allocator = allocator,
        };
    }
    fn deinit(self: *State) void {
        var iter = self.scopes.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }

        self.scopes.clearAndFree(self.allocator);
    }
};

pub fn handle_packet(self: *lib.Server(State), data: []const u8, sender: lib.network.EndPoint) lib.PacketError!void {
    var packet = Packet.deserialize(data, self.allocator) catch return error.BadInput;
    defer packet.free(self.allocator);

    // used for sending packet
    var buffer: [1024]u8 = undefined;

    switch (packet.header.packet_type) {
        .host => {
            const host_payload = lib.deserialize_payload(packet.payload, HostPayload) catch return error.BadInput;

            const dupe_scope = try self.allocator.dupe(u8, host_payload.q.scope[0..host_payload.q.scope.len]);
            const dupe_key = try self.allocator.dupe(u8, host_payload.q.key[0..host_payload.q.key.len]);
            errdefer self.allocator.free(dupe_scope);
            errdefer self.allocator.free(dupe_key);

            // need to study the memory implications here. Too tired to do it now.
            // this is memory safe according to all test cases
            // but this took a fair bit of work.
            const scope_exist = self.ctx.scopes.getPtr(dupe_scope);
            if (scope_exist) |scope| {
                const lobby_exist = scope.lobbies.getPtr(dupe_key);
                if (lobby_exist) |_| {
                    std.log.warn("lobby attempted to start with existing key / scope combination '{s}:{s}'", .{ dupe_scope, dupe_key });

                    self.allocator.free(dupe_scope);
                    self.allocator.free(dupe_key);
                    return;
                }

                var lobby: Lobby = .{ .join_policy = host_payload.policy };
                try lobby.members.append(self.allocator, sender);
                errdefer self.allocator.free(dupe_key);
                try scope.lobbies.put(self.allocator, dupe_key, lobby);
                self.allocator.free(dupe_scope);

                std.log.info("{any} new host {s}:{s}", .{ sender, dupe_scope, dupe_key });
            } else {
                var scope: Scope = .{};
                var lobby: Lobby = .{ .join_policy = host_payload.policy };
                try lobby.members.append(self.allocator, sender);
                try scope.lobbies.put(self.allocator, dupe_key, lobby);
                try self.ctx.scopes.put(self.allocator, dupe_scope, scope);

                std.log.info("{any} new host {s}:{s}", .{ sender, dupe_scope, dupe_key });
            }
        },
        .join => {
            const join_payload = lib.deserialize_payload(packet.payload, JoinPayload) catch return error.BadInput;

            const dupe_scope = join_payload.scope[0..join_payload.scope.len];
            const dupe_key = join_payload.key[0..join_payload.key.len];

            const scope_exist = self.ctx.scopes.getPtr(dupe_scope);
            if (scope_exist) |scope| {
                const lobby_exist: ?*Lobby = scope.lobbies.getPtr(dupe_key);
                if (lobby_exist) |lobby| {
                    switch (lobby.join_policy) {
                        .AutoAccept => {
                            std.log.info("{any} joined lobby {s}:{s} (via auto-accept)", .{ sender, dupe_scope, dupe_key });

                            try lobby.members.append(self.allocator, sender);
                            const payload = lib.serialize_payload(
                                &buffer,
                                ReviewResponsePayload{ .join_request = .{ .ip = sender.address.ipv4.value, .port = sender.port }, .q = join_payload, .result = .Accepted },
                            ) catch return error.BadInput;
                            const sender_packet = try Packet.init(.review_request, payload);
                            const sender_data = sender_packet.serialize(self.allocator) catch return error.BadInput;
                            self.send_to(lobby.members.items[lobby.host_idx], sender_data);
                            self.allocator.free(sender_data);
                        },
                        .Reject => std.log.info("{any} got rejected from lobby {s}:{s}", .{ sender, dupe_scope, dupe_key }),
                        .ManualReview => {
                            const payload = lib.serialize_payload(
                                &buffer,
                                ReviewResponsePayload{ .join_request = .{ .ip = sender.address.ipv4.value, .port = sender.port }, .q = join_payload, .result = .Pending },
                            ) catch return error.BadInput;
                            const sender_packet = try Packet.init(.review_request, payload);
                            const sender_data = sender_packet.serialize(self.allocator) catch return error.BadInput;
                            self.send_to(lobby.members.items[lobby.host_idx], sender_data);
                            self.allocator.free(sender_data);
                        },
                    }
                }
            }
        },
        .review_response => {
            const review_response = lib.deserialize_payload(packet.payload, ReviewResponsePayload) catch return error.BadInput;

            const join_payload = review_response.q;
            const dupe_scope = join_payload.scope[0..join_payload.scope.len];
            const dupe_key = join_payload.key[0..join_payload.key.len];

            switch (review_response.result) {
                .Accepted => {
                    const scope_exist = self.ctx.scopes.getPtr(dupe_scope);
                    if (scope_exist) |scope| {
                        const lobby_exist: ?*Lobby = scope.lobbies.getPtr(dupe_key);
                        if (lobby_exist) |lobby| {
                            const requester = lib.network.EndPoint{ .address = .{ .ipv4 = .{ .value = review_response.join_request.ip } }, .port = review_response.join_request.port };
                            // authorize?
                            try lobby.members.append(self.allocator, requester);
                            std.log.info("{any} accepted {any}'s request", .{ sender, review_response.join_request });
                        }
                    }
                },
                .Rejected => std.log.info("{any} rejected {any}'s request", .{ sender, review_response.join_request }),
                .Pending => return,
            }
        },
        .close => {
            const close_payload = lib.deserialize_payload(packet.payload, ClosePayload) catch return error.BadInput;

            const dupe_scope = close_payload.q.scope[0..close_payload.q.scope.len];
            const dupe_key = close_payload.q.key[0..close_payload.q.key.len];

            const scope_exist = self.ctx.scopes.getPtr(dupe_scope);
            if (scope_exist) |scope| {
                // lose check. could potentially arbitrarily fail
                //if (lobby.members.items[lobby.host_idx].port == sender.port) return;

                var entry_exist = scope.lobbies.fetchRemove(dupe_key);
                if (entry_exist) |*entry| {
                    var lobby: Lobby = entry.value;
                    std.log.info("{any} closed lobby {s}:{s} with reason '{any}'", .{ sender, dupe_scope, dupe_key, close_payload.reason });

                    const broadcast_packet = try Packet.init(.close, packet.payload);
                    const packet_data = broadcast_packet.serialize(self.allocator) catch return error.BadInput;
                    self.broadcast(lobby.members.items, packet_data);

                    lobby.deinit(self.allocator);
                    self.allocator.free(entry.key);
                    self.allocator.free(packet_data);
                }
            }
        },
        .req_host_list => {
            const request_payload = lib.deserialize_payload(packet.payload, RequestHostListPayload) catch return error.BadInput;

            const requested_scope = request_payload.scope[0..request_payload.scope.len];
            const scope_exist = self.ctx.scopes.get(requested_scope);
            if (scope_exist) |scope| {
                var stream = std.io.fixedBufferStream(&buffer);
                var iter = scope.lobbies.iterator();
                while (iter.next()) |entry| {
                    const lobby: *Lobby = entry.value_ptr;
                    const name = entry.key_ptr; // key
                    const host = lobby.members.items[lobby.host_idx];

                    stream.writer().writeStructEndian(HostListPayload{
                        .name = to_fixed(name.*, 32),
                        .port = host.port,
                        .users = @intCast(lobby.members.items.len),
                        .capacity = 4, // TODO
                        .ip = host.address.ipv4.value,
                        .policy = lobby.join_policy,
                    }, .big) catch return error.BadInput;
                }

                const payload = stream.getWritten();

                const sender_packet = try Packet.init(.ret_host_list, payload);
                const sender_data = sender_packet.serialize(self.allocator) catch return error.BadInput;

                self.send_to(sender, sender_data);
                self.allocator.free(sender_data);
            }
        },
        else => {
            return error.BadInput;
        },
    }
}

pub fn main() !void {
    var GPA = std.heap.DebugAllocator(.{}).init;
    const allocator = GPA.allocator();

    var state = State.init(allocator);
    var server = try lib.Server(State).init(PORT, allocator, &state);
    defer server.deinit();
    defer state.deinit();

    server.set_read_timeout(1000);

    server.handle_packet_cb = handle_packet;

    std.log.info("starting server!", .{});
    while (!state.should_stop) {
        server.listen() catch |err| switch (err) {
            error.WouldBlock => continue,
            else => std.log.err("An error occured!\n{!}", .{err}),
        };
    }
}

test "simple connection" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);
    defer server.deinit();
    defer state.deinit();
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    server.handle_packet_cb = handle_packet;

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, lib.Server(State).listen, .{&server});

    const TestContext = struct {};
    var ctx: TestContext = .{};
    var client = try lib.Client(TestContext).init(allocator, &ctx);

    const host_payload: HostPayload = .{ .q = .{ .key = to_fixed("hello", 32), .scope = to_fixed("world", 32) } };
    try stream.writer().writeStructEndian(host_payload, .big);
    const ack_packet = try Packet.init(.host, stream.getWritten());
    const data = try ack_packet.serialize(allocator);
    defer allocator.free(data);

    try client.connect("127.0.0.1", 2800, data);
    thread.join();

    try std.testing.expect(client.target != null);
    try std.testing.expectEqual(1, server.clients.size);

    const found_scope = state.scopes.get(&to_fixed("world", 32));
    if (found_scope) |scope| {
        try std.testing.expectEqual(scope.lobbies.size, 1);
    } else {
        return error.MissingScope;
    }
}

test "join lobby" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);
    defer server.deinit();
    defer state.deinit();
    var buffer: [512]u8 = undefined;
    server.handle_packet_cb = handle_packet;
    server.set_read_timeout(200);

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, _listen_wrapper, .{&server});

    const TestContext = struct {};
    var ctx: TestContext = .{};
    var client = try lib.Client(TestContext).init(allocator, &ctx);

    const host_payload: HostPayload = .{ .q = .{ .key = to_fixed("hello", 32), .scope = to_fixed("world", 32) } };
    const host_packet = try Packet.init(.host, try lib.serialize_payload(&buffer, host_payload));
    const host_data = try host_packet.serialize(allocator);
    try client.connect("127.0.0.1", 2800, host_data);
    client.send(host_data);
    defer allocator.free(host_data);

    var join_client = try lib.Client(TestContext).init(allocator, &ctx);
    const join_payload: JoinPayload = .{ .key = to_fixed("hello", 32), .scope = to_fixed("world", 32) };
    const join_packet = try Packet.init(.join, try lib.serialize_payload(&buffer, join_payload));
    const join_data = try join_packet.serialize(allocator);
    try join_client.connect("127.0.0.1", 2800, join_data);
    defer allocator.free(join_data);

    std.Thread.sleep(10 * std.time.ns_per_ms);
    state.should_stop = true;
    thread.join();

    try std.testing.expect(client.target != null);
    try std.testing.expectEqual(2, server.clients.size);

    const scope = state.scopes.get(&to_fixed("world", 32)).?;
    const lobby: Lobby = scope.lobbies.get(&to_fixed("hello", 32)).?;

    try std.testing.expectEqual(2, lobby.members.items.len);
}

test "join lobby multiple scopes" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);
    defer server.deinit();
    defer state.deinit();
    server.handle_packet_cb = handle_packet;
    server.set_read_timeout(200);

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, _listen_wrapper, .{&server});

    const scopes = [_][]const u8{ "new", "world" };
    inline for (scopes) |scope| {
        const TestContext = struct {};
        var ctx: TestContext = .{};
        var client = try lib.Client(TestContext).init(allocator, &ctx);
        var buffer: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);

        const host_payload: HostPayload = .{ .q = .{ .key = to_fixed("hello", 32), .scope = to_fixed(scope, 32) } };
        try stream.writer().writeStructEndian(host_payload, .big);
        const host_packet = try Packet.init(.host, stream.getWritten());
        const host_data = try host_packet.serialize(allocator);
        try client.connect("127.0.0.1", 2800, host_data);
        client.send(host_data);
        defer allocator.free(host_data);

        buffer = undefined;
        stream = std.io.fixedBufferStream(&buffer);
        stream.reset();
        var join_client = try lib.Client(TestContext).init(allocator, &ctx);
        const join_payload: JoinPayload = .{ .key = to_fixed("hello", 32), .scope = to_fixed(scope, 32) };
        try stream.writer().writeStructEndian(join_payload, .big);
        const join_packet = try Packet.init(.join, stream.getWritten());
        const join_data = try join_packet.serialize(allocator);
        try join_client.connect("127.0.0.1", 2800, join_data);
        defer allocator.free(join_data);
    }

    std.Thread.sleep(10 * std.time.ns_per_ms);
    state.should_stop = true;
    thread.join();

    try std.testing.expectEqual(4, server.clients.size);

    inline for (scopes) |scope_name| {
        const scope = state.scopes.get(&to_fixed(scope_name, 32)).?;
        const lobby: Lobby = scope.lobbies.get(&to_fixed("hello", 32)).?;

        try std.testing.expectEqual(2, lobby.members.items.len);
    }
}

test "join lobby multiple lobbies" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);
    defer server.deinit();
    defer state.deinit();
    server.handle_packet_cb = handle_packet;
    server.set_read_timeout(200);

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, _listen_wrapper, .{&server});

    const lobbies = [_][]const u8{ "new", "world" };
    inline for (lobbies) |lobby| {
        const TestContext = struct {};
        var ctx: TestContext = .{};
        var client = try lib.Client(TestContext).init(allocator, &ctx);
        var buffer: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);

        const host_payload: HostPayload = .{ .q = .{ .key = to_fixed(lobby, 32), .scope = to_fixed("world", 32) } };
        try stream.writer().writeStructEndian(host_payload, .big);
        const host_packet = try Packet.init(.host, stream.getWritten());
        const host_data = try host_packet.serialize(allocator);
        try client.connect("127.0.0.1", 2800, host_data);
        client.send(host_data);
        defer allocator.free(host_data);

        buffer = undefined;
        stream = std.io.fixedBufferStream(&buffer);
        stream.reset();
        var join_client = try lib.Client(TestContext).init(allocator, &ctx);
        const join_payload: JoinPayload = .{ .key = to_fixed(lobby, 32), .scope = to_fixed("world", 32) };
        try stream.writer().writeStructEndian(join_payload, .big);
        const join_packet = try Packet.init(.join, stream.getWritten());
        const join_data = try join_packet.serialize(allocator);
        try join_client.connect("127.0.0.1", 2800, join_data);
        defer allocator.free(join_data);
    }

    std.Thread.sleep(10 * std.time.ns_per_ms);
    state.should_stop = true;
    thread.join();

    try std.testing.expectEqual(4, server.clients.size);

    inline for (lobbies) |lobby_name| {
        const scope = state.scopes.get(&to_fixed("world", 32)).?;
        const lobby: Lobby = scope.lobbies.get(&to_fixed(lobby_name, 32)).?;

        try std.testing.expectEqual(2, lobby.members.items.len);
    }
}

test "close lobby" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);
    defer server.deinit();
    defer state.deinit();
    server.handle_packet_cb = handle_packet;
    server.set_read_timeout(200);

    var buffer: [512]u8 = undefined;

    const TestContext = struct {};
    var ctx: TestContext = .{};
    var host_client = try lib.Client(TestContext).init(allocator, &ctx);

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, _listen_wrapper, .{&server});

    const host_payload: HostPayload = .{ .q = .{ .key = to_fixed("hello", 32), .scope = to_fixed("world", 32) } };
    const host_packet = try Packet.init(.host, try lib.serialize_payload(&buffer, host_payload));
    const host_data = try host_packet.serialize(allocator);
    try host_client.connect("127.0.0.1", 2800, host_data);
    defer allocator.free(host_data);

    inline for (0..3) |_| {
        var join_client = try lib.Client(TestContext).init(allocator, &ctx);
        const join_packet = try Packet.init(.join, try lib.serialize_payload(&buffer, JoinPayload{ .key = to_fixed("hello", 32), .scope = to_fixed("world", 32) }));
        const join_data = try join_packet.serialize(allocator);
        try join_client.connect("127.0.0.1", 2800, join_data);
        allocator.free(join_data);
    }

    const close_packet = try Packet.init(.close, try lib.serialize_payload(&buffer, ClosePayload{
        .q = .{
            .key = to_fixed("hello", 32),
            .scope = to_fixed("world", 32),
        },
        .reason = .HOST_QUIT,
    }));
    const close_data = try close_packet.serialize(allocator);
    host_client.send(close_data);
    allocator.free(close_data);

    std.Thread.sleep(10 * std.time.ns_per_ms);
    state.should_stop = true;
    thread.join();

    const scope = state.scopes.get(&to_fixed("world", 32)).?;
    try std.testing.expectEqual(0, scope.lobbies.size);
}

test "request lobby list" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);
    defer server.deinit();
    defer state.deinit();
    server.handle_packet_cb = handle_packet;
    server.set_read_timeout(200);

    var buffer: [512]u8 = undefined;

    const TestContext = struct {};
    var ctx: TestContext = .{};

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, _listen_wrapper, .{&server});

    const lobbies = [_][]const u8{ "orange", "purple", "yellow", "blueberry", "potatoes" };
    inline for (lobbies) |lobby| {
        var host_client = try lib.Client(TestContext).init(allocator, &ctx);
        const host_packet = try Packet.init(.host, try lib.serialize_payload(&buffer, HostPayload{ .q = .{ .key = to_fixed(lobby, 32), .scope = to_fixed("test_123", 32) } }));
        const host_data = try host_packet.serialize(allocator);
        try host_client.connect("127.0.0.1", 2800, host_data);
        allocator.free(host_data);
    }

    var request_client = try lib.Client(TestContext).init(allocator, &ctx);
    const request_packet = try Packet.init(.req_host_list, try lib.serialize_payload(
        &buffer,
        RequestHostListPayload{ .scope = to_fixed("test_123", 32) },
    ));
    const request_data = try request_packet.serialize(allocator);
    try request_client.connect("127.0.0.1", 2800, request_data);
    allocator.free(request_data);

    const socket = request_client.socket;

    var buff: [1024]u8 = undefined;

    const from = try socket.receiveFrom(&buff);
    std.debug.assert(from.numberOfBytes <= 1024);

    const data = buff[0..from.numberOfBytes];
    const response_packet = try Packet.deserialize(data, allocator);
    defer response_packet.free(allocator);

    const payload_individual_size = @sizeOf(HostListPayload);
    const c = response_packet.header.payload_size / payload_individual_size;
    try std.testing.expectEqual(lobbies.len, c);

    const payload_start = data[response_packet.header.header_size..];

    for (0..c) |i| {
        const host = try lib.deserialize_payload(payload_start[i * payload_individual_size .. (i + 1) * payload_individual_size], HostListPayload);
        //                                                      they come in reversed order
        //                                                      last in first out, i think
        // try std.testing.expectEqualStrings(&host.name, &to_fixed(lobbies[lobbies.len - 1 - i], 32));
        //                                                  although this is not consistent with > 2 lobbies so idk the best way to do this
        try std.testing.expectEqual(JoinPolicy.AutoAccept, host.policy);
        try std.testing.expectEqual(1, host.users);
    }

    state.should_stop = true;
    thread.join();
}

fn _listen_wrapper(server_ptr: *lib.Server(State)) !void {
    while (!server_ptr.ctx.should_stop) {
        _ = server_ptr.listen() catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
    }
}
