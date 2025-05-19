//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const lib = @import("udptp_lib");

const PORT = 3306;
const MAGIC_HEADER = 0xDEADBEEF;

const CRC32 = std.hash.crc.Crc32Cksum;

const PacketType = enum(u32) {
    host,
    req_host_list,
    ret_host_list,
};

const HostListPayload = packed struct {
    static_names_id: u32,
    ip_1: u8,
    ip_2: u8,
    ip_3: u8,
    ip_4: u8,
    port: u16,
};

const PacketHeader = packed struct {
    magic: u32,
    header_size: u16,
    payload_size: u32,
    packet_type: PacketType,
    checksum: u32,

    pub fn init(packet_type: PacketType, payload_size: u32, checksum: u32) !PacketHeader {
        return .{
            .magic = MAGIC_HEADER,
            .header_size = @sizeOf(PacketHeader),
            .payload_size = payload_size,
            .packet_type = packet_type,
            .checksum = checksum,
        };
    }
};

const Packet = struct {
    header: PacketHeader,
    payload: []const u8,

    pub fn init(packet_type: PacketType, payload: []const u8) !Packet {
        const hash = CRC32.hash(payload);
        return .{
            .header = try PacketHeader.init(packet_type, @intCast(payload.len), hash),
            .payload = payload,
        };
    }

    pub fn serialize(self: *const Packet, writer: std.io.AnyWriter) !void {
        try writer.writeStruct(self.header);
        try writer.writeAll(self.payload);
    }

    /// caller is responsible for freeing after this is called
    pub fn deserialize(reader: std.io.AnyReader, allocator: std.mem.Allocator) !Packet {
        const header = try reader.readStruct(PacketHeader);

        const payload = try allocator.alloc(u8, header.payload_size);
        try reader.readNoEof(payload);

        if (header.checksum != CRC32.hash(payload)) return error.InvalidChecksum;

        return Packet{
            .header = header,
            .payload = payload,
        };
    }

    pub fn free(self: *Packet, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
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
    var stream = std.io.fixedBufferStream(data);
    var packet = Packet.deserialize(stream.reader().any(), self.allocator) catch return error.BadInput;
    errdefer packet.free(self.allocator);
    defer packet.free(self.allocator);

    stream = std.io.fixedBufferStream(packet.payload);

    switch (packet.header.packet_type) {
        .host => {
            const host_key = try self.allocator.dupe(u8, packet.payload);
            if (self.ctx.lobbies.get(host_key)) |_| {
                std.log.debug("duplicate host key request with key '{s}'", .{host_key});
                self.allocator.free(host_key);
            } else {
                var new_arraylist: std.ArrayListUnmanaged(lib.network.EndPoint) = .{};
                try new_arraylist.append(self.allocator, sender);
                try self.ctx.lobbies.put(self.allocator, host_key, new_arraylist);

                std.log.info("new host with key '{s}'", .{host_key});
            }
        },
        .req_host_list => {
            var buffer: [1024]u8 = undefined;
            var _stream = std.io.fixedBufferStream(&buffer);

            var iter = self.ctx.lobbies.valueIterator();
            var n: u32 = 0;
            const sender_writer = _stream.writer();
            while (iter.next()) |users| {
                const host = users.items[0];
                sender_writer.writeStruct(HostListPayload{
                    .ip_1 = host.address.ipv4.value[0],
                    .ip_2 = host.address.ipv4.value[1],
                    .ip_3 = host.address.ipv4.value[2],
                    .ip_4 = host.address.ipv4.value[3],
                    .port = host.port,
                    .static_names_id = n,
                }) catch return error.BadInput;
                n += 1;
            }

            const sender_packet = try Packet.init(.ret_host_list, sender_writer.context.getWritten());

            var sender_buffer: [1024]u8 = undefined;
            var sender_stream = std.io.fixedBufferStream(&sender_buffer);

            sender_packet.serialize(sender_stream.writer().any()) catch return error.BadInput;

            self.send_to(sender, sender_stream.buffer);
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
    errdefer server.deinit();

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
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try ack_packet.serialize(writer.any());

    try client.connect("127.0.0.1", 2800, writer.context.buffer);
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
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try ack_packet.serialize(writer.any());

    const TestContext = struct {};
    var ctx: TestContext = .{};
    var client = try lib.Client(TestContext).init(allocator, &ctx);
    try client.connect("127.0.0.1", 2800, writer.context.buffer);

    var client2 = try lib.Client(TestContext).init(allocator, &ctx);
    try client2.connect("127.0.0.1", 2800, writer.context.buffer);
    thread.join();

    try std.testing.expect(server.clients.size == 2);
}

test "packet serialization and deserialization" {
    const allocator = std.testing.allocator;
    const ack_packet = try Packet.init(.host, "hello, world!");
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try ack_packet.serialize(writer.any());

    writer.context.reset();
    const reader = writer.context.reader();

    var des_packet = try Packet.deserialize(reader.any(), allocator);
    defer des_packet.free(allocator);

    try std.testing.expectEqual(des_packet.header, ack_packet.header);
    try std.testing.expectEqualStrings(des_packet.payload, ack_packet.payload);
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
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try ack_packet.serialize(writer.any());

    const TestContext = struct {};
    var ctx: TestContext = .{};
    var client = try lib.Client(TestContext).init(allocator, &ctx);
    try client.connect("127.0.0.1", 2800, writer.context.buffer);

    thread.join();

    try std.testing.expectEqual(state.lobbies.size, 1);

    const lobby = state.lobbies.get("host/world").?;

    try std.testing.expectEqual(lobby.items[0], server.clients.getKey(lobby.items[0]));
}

const MoreTestContext = struct {
    available_lobbies: std.ArrayListUnmanaged(HostListPayload),
};

fn sample_client_handle_packet_cb(self: *lib.Client(MoreTestContext), data: []const u8, _: lib.network.EndPoint) lib.PacketError!void {
    var stream = std.io.fixedBufferStream(data);
    var packet = Packet.deserialize(stream.reader().any(), self.allocator) catch return error.BadInput;
    errdefer packet.free(self.allocator);
    defer packet.free(self.allocator);

    stream = std.io.fixedBufferStream(packet.payload);

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
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try ack_packet.serialize(writer.any());

    var ctx: MoreTestContext = .{ .available_lobbies = .{} };
    defer ctx.available_lobbies.deinit(allocator);

    var client = try lib.Client(MoreTestContext).init(allocator, &ctx);
    try client.connect("127.0.0.1", 2800, writer.context.buffer);

    const req_packet = try Packet.init(.req_host_list, "");

    stream.reset();
    writer = stream.writer();
    try req_packet.serialize(writer.any());

    var client2 = try lib.Client(MoreTestContext).init(allocator, &ctx);
    client2.handle_packet_cb = sample_client_handle_packet_cb;
    try client2.connect("127.0.0.1", 2800, writer.context.buffer);
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
    var buffer: [512]u8 = undefined;

    const ack_packet = try Packet.init(.host, "host/world");
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try ack_packet.serialize(writer.any());

    var ctx: MoreTestContext = .{ .available_lobbies = .{} };
    defer ctx.available_lobbies.deinit(allocator);

    var client = try lib.Client(MoreTestContext).init(allocator, &ctx);
    try client.connect("127.0.0.1", 2800, writer.context.buffer);

    const ack_packet2 = try Packet.init(.host, "host/second");
    stream = std.io.fixedBufferStream(&buffer);
    writer = stream.writer();
    try ack_packet2.serialize(writer.any());
    var client2 = try lib.Client(MoreTestContext).init(allocator, &ctx);
    try client2.connect("127.0.0.1", 2800, writer.context.buffer);

    const ack_packet3 = try Packet.init(.host, "host/third");
    stream = std.io.fixedBufferStream(&buffer);
    writer = stream.writer();
    try ack_packet3.serialize(writer.any());
    var client3 = try lib.Client(MoreTestContext).init(allocator, &ctx);
    try client3.connect("127.0.0.1", 2800, writer.context.buffer);

    const req_packet = try Packet.init(.req_host_list, "");

    stream.reset();
    writer = stream.writer();
    try req_packet.serialize(writer.any());

    var client4 = try lib.Client(MoreTestContext).init(allocator, &ctx);
    client4.handle_packet_cb = sample_client_handle_packet_cb;
    try client4.connect("127.0.0.1", 2800, writer.context.buffer);
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
