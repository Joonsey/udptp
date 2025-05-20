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

const HostListPayload = packed struct {
    static_names_id: u32,
    ip_1: u8,
    ip_2: u8,
    ip_3: u8,
    ip_4: u8,
    port: u16,
    users: u16,
    capacity: u16,
};

const State = struct {
    /// lobbies, with host as key
    lobbies: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(lib.network.EndPoint)),

    /// if the server should stop
    should_stop: bool = false,

    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) State {
        return .{
            .lobbies = .{},
            .allocator = allocator,
        };
    }
    fn deinit(self: *State) void {
        var iter = self.lobbies.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }

        self.lobbies.clearAndFree(self.allocator);
    }
};

pub fn handle_packet(self: *lib.Server(State), data: []const u8, sender: lib.network.EndPoint) lib.PacketError!void {
    var packet = Packet.deserialize(data, self.allocator) catch return error.BadInput;
    defer packet.free(self.allocator);

    // used for sending packet
    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    switch (packet.header.packet_type) {
        .host => {
            if (self.ctx.lobbies.get(packet.payload)) |_| {
                std.log.debug("duplicate host key request with key '{s}'", .{packet.payload});
            } else {
                const host_key = try self.allocator.dupe(u8, packet.payload);
                var new_arraylist: std.ArrayListUnmanaged(lib.network.EndPoint) = .{};
                try new_arraylist.append(self.allocator, sender);
                try self.ctx.lobbies.put(self.allocator, host_key, new_arraylist);

                std.log.info("new host with key '{s}'", .{host_key});
            }
        },
        .join => {
            const lobby_exist = self.ctx.lobbies.getPtr(packet.payload);
            if (lobby_exist) |lobby| {
                try lobby.append(self.allocator, sender);
                std.log.info("{any} joined key {s}", .{ sender, packet.payload });
            }
        },
        .close => {
            const lobby_exist = self.ctx.lobbies.fetchRemove(packet.payload);
            if (lobby_exist) |lobby| {
                std.log.info("{s} is closing", .{lobby.key});
                // TODO: broadcast to lobby members
            }
        },
        .req_host_list => {
            var iter = self.ctx.lobbies.valueIterator();
            var n: u32 = 0;
            const writer = stream.writer();
            while (iter.next()) |users| {
                const host = users.items[0];
                writer.writeStruct(HostListPayload{
                    .ip_1 = host.address.ipv4.value[0],
                    .ip_2 = host.address.ipv4.value[1],
                    .ip_3 = host.address.ipv4.value[2],
                    .ip_4 = host.address.ipv4.value[3],
                    .port = host.port,
                    .static_names_id = n,
                    .capacity = 4,
                    .users = @intCast(users.items.len),
                }) catch return error.BadInput;
                n += 1;
            }
            const payload = stream.getWritten();

            const sender_packet = try Packet.init(.ret_host_list, payload);
            const sender_data = sender_packet.serialize(self.allocator) catch return error.BadInput;

            self.send_to(sender, sender_data);
            self.allocator.free(sender_data);
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

test "simple connection test" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);
    defer server.deinit();
    defer state.deinit();
    server.handle_packet_cb = handle_packet;

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, lib.Server(State).listen, .{&server});

    const TestContext = struct {};
    var ctx: TestContext = .{};
    var client = try lib.Client(TestContext).init(allocator, &ctx);

    const ack_packet = try Packet.init(.host, "hello, world!");
    const data = try ack_packet.serialize(allocator);
    defer allocator.free(data);

    try client.connect("127.0.0.1", 2800, data);
    thread.join();

    try std.testing.expect(client.target != null);
    try std.testing.expect(server.clients.size == 1);
}

fn _listen_wrapper(server_ptr: *lib.Server(State)) !void {
    while (server_ptr.clients.size < 2) {
        _ = try server_ptr.listen();
    }
}

test "several connections test" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);
    defer server.deinit();
    defer state.deinit();
    server.handle_packet_cb = handle_packet;

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, _listen_wrapper, .{&server});

    const ack_packet = try Packet.init(.host, "hello, world!");
    const data = try ack_packet.serialize(allocator);
    defer allocator.free(data);

    const TestContext = struct {};
    var ctx: TestContext = .{};
    var client = try lib.Client(TestContext).init(allocator, &ctx);
    try client.connect("127.0.0.1", 2800, data);

    var client2 = try lib.Client(TestContext).init(allocator, &ctx);
    try client2.connect("127.0.0.1", 2800, data);
    thread.join();

    try std.testing.expect(server.clients.size == 2);
}

test "packet transmition" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);

    defer server.deinit();
    defer state.deinit();

    server.handle_packet_cb = handle_packet;

    server.set_read_timeout(1000);

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, lib.Server(State).listen, .{&server});

    const ack_packet = try Packet.init(.host, "host/world");

    const TestContext = struct {};
    var ctx: TestContext = .{};
    var client = try lib.Client(TestContext).init(allocator, &ctx);

    const data = try ack_packet.serialize(allocator);
    try client.connect("127.0.0.1", 2800, data);
    allocator.free(data);

    thread.join();

    try std.testing.expectEqual(state.lobbies.size, 1);

    const lobby = state.lobbies.get("host/world").?;

    try std.testing.expectEqual(lobby.items[0], server.clients.getKey(lobby.items[0]));
}

const MoreTestContext = struct {
    available_lobbies: std.ArrayListUnmanaged(HostListPayload),
};

fn sample_client_handle_packet_cb(self: *lib.Client(MoreTestContext), data: []const u8, _: lib.network.EndPoint) lib.PacketError!void {
    var packet = Packet.deserialize(data, self.allocator) catch return error.BadInput;
    defer packet.free(self.allocator);

    var stream = std.io.fixedBufferStream(packet.payload);

    const n = packet.header.payload_size;
    const l = @sizeOf(HostListPayload);

    const amount: usize = @divTrunc(n, l);

    var reader = stream.reader();

    for (0..amount) |_| {
        try self.ctx.available_lobbies.append(self.allocator, reader.readStruct(HostListPayload) catch unreachable);
    }
}

test "get host list" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);

    defer server.deinit();
    defer state.deinit();

    server.handle_packet_cb = handle_packet;

    server.set_read_timeout(1000);

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, _listen_wrapper, .{&server});

    const ack_packet = try Packet.init(.host, "host/world");

    var ctx: MoreTestContext = .{ .available_lobbies = .{} };
    defer ctx.available_lobbies.deinit(allocator);

    var client = try lib.Client(MoreTestContext).init(allocator, &ctx);

    const data = try ack_packet.serialize(allocator);
    try client.connect("127.0.0.1", 2800, data);
    allocator.free(data);

    const req_packet = try Packet.init(.req_host_list, "");

    var client2 = try lib.Client(MoreTestContext).init(allocator, &ctx);
    client2.handle_packet_cb = sample_client_handle_packet_cb;

    const data2 = try req_packet.serialize(allocator);
    try client2.connect("127.0.0.1", 2800, data2);
    allocator.free(data2);
    try client2.listen();

    thread.join();

    try std.testing.expectEqual(state.lobbies.size, 1);
    try std.testing.expectEqual(ctx.available_lobbies.items.len, 1);

    const lobby = state.lobbies.get("host/world").?;

    try std.testing.expectEqual(ctx.available_lobbies.items[0].ip_1, lobby.items[0].address.ipv4.value[0]);
    try std.testing.expectEqual(ctx.available_lobbies.items[0].ip_2, lobby.items[0].address.ipv4.value[1]);
    try std.testing.expectEqual(ctx.available_lobbies.items[0].ip_3, lobby.items[0].address.ipv4.value[2]);
    try std.testing.expectEqual(ctx.available_lobbies.items[0].ip_4, lobby.items[0].address.ipv4.value[3]);
}

fn _listen_wrapper2(server_ptr: *lib.Server(State)) !void {
    while (server_ptr.clients.size < 4) {
        _ = try server_ptr.listen();
    }
}

test "get host list plural hosts" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);

    defer server.deinit();
    defer state.deinit();

    server.handle_packet_cb = handle_packet;

    server.set_read_timeout(1000);

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, _listen_wrapper2, .{&server});

    const ack_packet = try Packet.init(.host, "host/world");

    var ctx: MoreTestContext = .{ .available_lobbies = .{} };
    defer ctx.available_lobbies.deinit(allocator);

    var client = try lib.Client(MoreTestContext).init(allocator, &ctx);
    const data = try ack_packet.serialize(allocator);
    try client.connect("127.0.0.1", 2800, data);
    allocator.free(data);

    const ack_packet2 = try Packet.init(.host, "host/second");
    var client2 = try lib.Client(MoreTestContext).init(allocator, &ctx);
    const data2 = try ack_packet2.serialize(allocator);
    try client2.connect("127.0.0.1", 2800, data2);
    allocator.free(data2);

    const ack_packet3 = try Packet.init(.host, "host/third");
    var client3 = try lib.Client(MoreTestContext).init(allocator, &ctx);
    const data3 = try ack_packet3.serialize(allocator);
    try client3.connect("127.0.0.1", 2800, data3);
    allocator.free(data3);

    const req_packet = try Packet.init(.req_host_list, "");

    var client4 = try lib.Client(MoreTestContext).init(allocator, &ctx);
    client4.handle_packet_cb = sample_client_handle_packet_cb;
    const data4 = try req_packet.serialize(allocator);
    try client4.connect("127.0.0.1", 2800, data4);
    allocator.free(data4);
    try client4.listen();

    thread.join();

    try std.testing.expectEqual(state.lobbies.size, 3);
    try std.testing.expectEqual(ctx.available_lobbies.items.len, 3);

    var lobby = state.lobbies.get("host/world").?;
    try std.testing.expectEqual(ctx.available_lobbies.items[0].ip_1, lobby.items[0].address.ipv4.value[0]);
    try std.testing.expectEqual(ctx.available_lobbies.items[0].ip_2, lobby.items[0].address.ipv4.value[1]);
    try std.testing.expectEqual(ctx.available_lobbies.items[0].ip_3, lobby.items[0].address.ipv4.value[2]);
    try std.testing.expectEqual(ctx.available_lobbies.items[0].ip_4, lobby.items[0].address.ipv4.value[3]);

    lobby = state.lobbies.get("host/second").?;
    try std.testing.expectEqual(ctx.available_lobbies.items[1].ip_1, lobby.items[0].address.ipv4.value[0]);
    try std.testing.expectEqual(ctx.available_lobbies.items[1].ip_2, lobby.items[0].address.ipv4.value[1]);
    try std.testing.expectEqual(ctx.available_lobbies.items[1].ip_3, lobby.items[0].address.ipv4.value[2]);
    try std.testing.expectEqual(ctx.available_lobbies.items[1].ip_4, lobby.items[0].address.ipv4.value[3]);

    lobby = state.lobbies.get("host/third").?;
    try std.testing.expectEqual(ctx.available_lobbies.items[2].ip_1, lobby.items[0].address.ipv4.value[0]);
    try std.testing.expectEqual(ctx.available_lobbies.items[2].ip_2, lobby.items[0].address.ipv4.value[1]);
    try std.testing.expectEqual(ctx.available_lobbies.items[2].ip_3, lobby.items[0].address.ipv4.value[2]);
    try std.testing.expectEqual(ctx.available_lobbies.items[2].ip_4, lobby.items[0].address.ipv4.value[3]);
}

test "get host list plural users" {
    const allocator = std.testing.allocator;

    var state = State.init(allocator);
    var server = try lib.Server(State).init(2800, allocator, &state);

    defer server.deinit();
    defer state.deinit();

    server.handle_packet_cb = handle_packet;

    server.set_read_timeout(1000);

    const thread = try std.Thread.spawn(.{ .allocator = allocator }, _listen_wrapper2, .{&server});
    const ack_packet = try Packet.init(.host, "host/world");

    var ctx: MoreTestContext = .{ .available_lobbies = .{} };
    defer ctx.available_lobbies.deinit(allocator);

    var client = try lib.Client(MoreTestContext).init(allocator, &ctx);
    const data = try ack_packet.serialize(allocator);
    try client.connect("127.0.0.1", 2800, data);
    allocator.free(data);

    const ack_packet2 = try Packet.init(.join, "host/world");
    const ack_data = try ack_packet2.serialize(allocator);

    var client2 = try lib.Client(MoreTestContext).init(allocator, &ctx);
    try client2.connect("127.0.0.1", 2800, ack_data);

    var client3 = try lib.Client(MoreTestContext).init(allocator, &ctx);
    try client3.connect("127.0.0.1", 2800, ack_data);

    allocator.free(ack_data);

    const req_packet = try Packet.init(.req_host_list, "");
    const req_data = try req_packet.serialize(allocator);

    var client4 = try lib.Client(MoreTestContext).init(allocator, &ctx);
    client4.handle_packet_cb = sample_client_handle_packet_cb;
    try client4.connect("127.0.0.1", 2800, req_data);
    allocator.free(req_data);
    try client4.listen();

    thread.join();

    try std.testing.expectEqual(state.lobbies.size, 1);
    try std.testing.expectEqual(ctx.available_lobbies.items.len, 1);
    try std.testing.expectEqual(ctx.available_lobbies.items[0].users, 3);
    try std.testing.expectEqual(ctx.available_lobbies.items[0].capacity, 4);
}
