//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const lib = @import("udptp_lib");

const PORT = 3306;

const PacketType = enum(u32) {
    host,
    join,
    close,
    req_host_list,
    ret_host_list,
};

const Packet = lib.Packet(.{ .T = PacketType });

const CloseReason = enum(u16) {
    HOST_QUIT,
};

const JoinPayload = extern struct {
    scope: [32]u8,
    key: [32]u8,
};

fn to_fixed(str: []const u8, comptime arr_len: usize) [arr_len]u8 {
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

const HostPayload = JoinPayload;

const HostListPayload = extern struct {
    static_names_id: u32,
    ip: [4]u8,
    port: u16,
    users: u16,
    capacity: u16,
};

const Lobby = struct {
    host_idx: usize = 0,
    members: std.ArrayListUnmanaged(lib.network.EndPoint) = .{},

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
    //var buffer: [1024]u8 = undefined;
    //const stream = std.io.fixedBufferStream(&buffer);

    switch (packet.header.packet_type) {
        .host => {
            const join_payload = lib.deserialize_payload(packet.payload, HostPayload) catch return error.BadInput;

            const dupe_scope = try self.allocator.dupe(u8, join_payload.scope[0..join_payload.scope.len]);
            const dupe_key = try self.allocator.dupe(u8, join_payload.key[0..join_payload.key.len]);
            errdefer self.allocator.free(dupe_scope);
            errdefer self.allocator.free(dupe_key);

            // need to study the memory implications here. Too tired to do it now.
            // this is memory safe according to all test cases
            // but this took a fair bit of work.
            const scope_exist = self.ctx.scopes.getPtr(dupe_scope);
            if (scope_exist) |scope| {
                const lobby_exist = scope.lobbies.getPtr(dupe_key);
                if (lobby_exist) |_| {
                    self.allocator.free(dupe_scope);
                    self.allocator.free(dupe_key);
                    return;
                }

                var lobby: Lobby = .{};
                try lobby.members.append(self.allocator, sender);
                errdefer self.allocator.free(dupe_key);
                try scope.lobbies.put(self.allocator, dupe_key, lobby);
                self.allocator.free(dupe_scope);

                std.log.info("{any} new host {s}:{s}", .{ sender, dupe_scope, dupe_key });
            } else {
                var scope: Scope = .{};
                var lobby: Lobby = .{};
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

            std.log.info("{any} joined lobby {s}:{s}", .{ sender, dupe_scope, dupe_key });

            const scope_exist = self.ctx.scopes.getPtr(dupe_scope);
            if (scope_exist) |scope| {
                const lobby_exist: ?*Lobby = scope.lobbies.getPtr(dupe_key);
                if (lobby_exist) |lobby| {
                    std.log.info("{any} joined lobby {s}:{s}", .{ sender, dupe_scope, dupe_key });
                    try lobby.members.append(self.allocator, sender);
                }
            }
        },
        .close => {
            // TODO
        },
        .req_host_list => {
            // TODO
            //var iter = self.ctx.lobbies.valueIterator();
            //var n: u32 = 0;
            //const writer = stream.writer();
            //while (iter.next()) |users| {
            //    const host = users.items[0];
            //    writer.writeStructEndian(HostListPayload{
            //        .ip = host.address.ipv4.value,
            //        .port = host.port,
            //        .static_names_id = n,
            //        .capacity = 4,
            //        .users = @intCast(users.items.len),
            //    }, .big) catch return error.BadInput;
            //    n += 1;
            //}

            //const payload = stream.getWritten();

            //const sender_packet = try Packet.init(.ret_host_list, payload);
            //const sender_data = sender_packet.serialize(self.allocator) catch return error.BadInput;

            //self.send_to(sender, sender_data);
            //self.allocator.free(sender_data);
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

    const host_payload: HostPayload = .{ .key = to_fixed("hello", 32), .scope = to_fixed("world", 32) };
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

    const host_payload: HostPayload = .{ .key = to_fixed("hello", 32), .scope = to_fixed("world", 32) };
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

    std.Thread.sleep(50 * std.time.ns_per_ms);
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

        const host_payload: HostPayload = .{ .key = to_fixed("hello", 32), .scope = to_fixed(scope, 32) };
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

    std.Thread.sleep(50 * std.time.ns_per_ms);
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

        const host_payload: HostPayload = .{ .key = to_fixed(lobby, 32), .scope = to_fixed("world", 32) };
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

    std.Thread.sleep(50 * std.time.ns_per_ms);
    state.should_stop = true;
    thread.join();

    try std.testing.expectEqual(4, server.clients.size);

    inline for (lobbies) |lobby_name| {
        const scope = state.scopes.get(&to_fixed("world", 32)).?;
        const lobby: Lobby = scope.lobbies.get(&to_fixed(lobby_name, 32)).?;

        try std.testing.expectEqual(2, lobby.members.items.len);
    }
}

fn _listen_wrapper(server_ptr: *lib.Server(State)) !void {
    while (!server_ptr.ctx.should_stop) {
        _ = server_ptr.listen() catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
    }
}
