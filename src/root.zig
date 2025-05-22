//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

const CRC32 = std.hash.crc.Crc32Cksum;

pub const network = @import("network");

pub const PacketError = error{ DeserializationError, AuthorizationError, BadInput, OutOfMemory, InvalidMagicBytes, InvalidChecksum, EndOfStream };

pub fn Server(comptime T: type) type {
    return struct {
        fn log_data_info(_: *Self, buff: []const u8, from: network.EndPoint) PacketError!void {
            const ip = from.address.ipv4.value;
            std.log.info("received '{s}' from: {d}.{d}.{d}.{d}:{d}", .{ buff, ip[0], ip[1], ip[2], ip[3], from.port });
        }

        fn log_data_warn(_: *Self, buff: []const u8, from: network.EndPoint) PacketError!void {
            const ip = from.address.ipv4.value;
            std.log.warn("received '{s}' from: {d}.{d}.{d}.{d}:{d}", .{ buff, ip[0], ip[1], ip[2], ip[3], from.port });
        }

        fn log_data_debug(_: *Self, buff: []const u8, from: network.EndPoint) PacketError!void {
            const ip = from.address.ipv4.value;
            std.log.debug("received '{s}' from: {d}.{d}.{d}.{d}:{d}", .{ buff, ip[0], ip[1], ip[2], ip[3], from.port });
        }

        fn log_data_err(_: *Self, buff: []const u8, from: network.EndPoint) PacketError!void {
            const ip = from.address.ipv4.value;
            std.log.err("received '{s}' from: {d}.{d}.{d}.{d}:{d}", .{ buff, ip[0], ip[1], ip[2], ip[3], from.port });
        }
        const Self = @This();

        clients: std.AutoHashMapUnmanaged(network.EndPoint, i64),
        socket: network.Socket,

        ctx: *T,

        handle_packet_cb: *const fn (*Self, []const u8, network.EndPoint) PacketError!void,

        allocator: std.mem.Allocator,

        pub fn init(port: u16, allocator: std.mem.Allocator, ctx: *T) !Self {
            var socket = try network.Socket.create(.ipv4, .udp);
            try socket.bind(.{ .address = .{ .ipv4 = network.Address.IPv4.loopback }, .port = port });

            return .{
                .socket = socket,
                .allocator = allocator,
                .clients = .{},
                .handle_packet_cb = log_data_info,
                .ctx = ctx,
            };
        }

        pub fn broadcast(self: Self, clients: []network.EndPoint, data: []const u8) void {
            for (clients) |client| self.send_to(client, data);
        }

        pub fn set_read_timeout(self: *Self, timeout: u32) void {
            self.socket.setReadTimeout(timeout) catch unreachable;
        }

        /// will propogate error from socket.receiveFrom
        /// and handle packet callback
        /// can raise error.WouldBlock if set_read_timeout is set
        /// the server will just naively add clients to the known client list if packet is successfully handled.
        ///
        /// This is because we are presuming a udp NAT punching peer to peer solution,
        /// so the presumption is that the user would have first have had to reached out to the client in the first place to even get packets routed to us.
        ///
        /// if the users wishes they can authorize within the callback and throw an error to interupt the client being added
        /// but again it's an opt-in feature as we presume authentication via the NAT
        pub fn listen(self: *Self) !void {
            const socket = self.socket;
            const BUFF_SIZE = 1024;

            var buff: [BUFF_SIZE]u8 = undefined;

            const from = try socket.receiveFrom(&buff);
            std.debug.assert(from.numberOfBytes <= BUFF_SIZE);

            try self.handle_packet_cb(self, buff[0..from.numberOfBytes], from.sender);
            try self.clients.put(self.allocator, from.sender, std.time.microTimestamp());
        }

        pub fn send_to(self: Self, to: network.EndPoint, data: []const u8) void {
            _ = self.socket.sendTo(to, data) catch unreachable;
        }

        pub fn deinit(self: *Self) void {
            self.socket.close();
            self.clients.clearAndFree(self.allocator);
        }
    };
}

pub fn Client(comptime T: type) type {
    return struct {
        fn log_data_info(_: *Self, buff: []const u8, from: network.EndPoint) PacketError!void {
            const ip = from.address.ipv4.value;
            std.log.info("received '{s}' from: {d}.{d}.{d}.{d}:{d}", .{ buff, ip[0], ip[1], ip[2], ip[3], from.port });
        }

        fn log_data_warn(_: *Self, buff: []const u8, from: network.EndPoint) PacketError!void {
            const ip = from.address.ipv4.value;
            std.log.warn("received '{s}' from: {d}.{d}.{d}.{d}:{d}", .{ buff, ip[0], ip[1], ip[2], ip[3], from.port });
        }

        fn log_data_debug(_: *Self, buff: []const u8, from: network.EndPoint) PacketError!void {
            const ip = from.address.ipv4.value;
            std.log.debug("received '{s}' from: {d}.{d}.{d}.{d}:{d}", .{ buff, ip[0], ip[1], ip[2], ip[3], from.port });
        }

        fn log_data_err(_: *Self, buff: []const u8, from: network.EndPoint) PacketError!void {
            const ip = from.address.ipv4.value;
            std.log.err("received '{s}' from: {d}.{d}.{d}.{d}:{d}", .{ buff, ip[0], ip[1], ip[2], ip[3], from.port });
        }
        const Self = @This();

        socket: network.Socket,
        target: ?network.EndPoint = null,
        ctx: *T,

        handle_packet_cb: *const fn (*Self, []const u8, network.EndPoint) PacketError!void,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, ctx: *T) !Self {
            return .{
                .socket = try network.Socket.create(.ipv4, .udp),
                .handle_packet_cb = log_data_info,
                .allocator = allocator,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.socket.close();
        }

        pub fn connect(self: *Self, addr: []const u8, port: u16, connect_data: []const u8) !void {
            self.target = .{ .address = try network.Address.parse(addr), .port = port };
            self.send(connect_data);
        }

        pub fn send(self: *Self, data: []const u8) void {
            const socket = self.socket;
            if (self.target) |target| {
                _ = socket.sendTo(target, data) catch std.log.err("error sending data!", .{});
            }
        }

        pub fn listen(self: *Self) !void {
            const socket = self.socket;
            const BUFF_SIZE = 1024;

            var buff: [BUFF_SIZE]u8 = undefined;

            const from = try socket.receiveFrom(&buff);
            std.debug.assert(from.numberOfBytes <= BUFF_SIZE);

            try self.handle_packet_cb(self, buff[0..from.numberOfBytes], from.sender);
        }
    };
}

pub const PacketConfig = struct {
    T: type,
    magic_bytes: u32 = 0xDEADBEEF,
};

pub fn PacketHeader(config: PacketConfig) type {
    return packed struct {
        magic: u32,
        header_size: u16,
        payload_size: u32,
        packet_type: config.T,
        checksum: u32,

        const Self = @This();

        pub fn init(packet_type: config.T, payload_size: u32, checksum: u32) !Self {
            return .{
                .magic = config.magic_bytes,
                .header_size = @sizeOf(Self),
                .payload_size = payload_size,
                .packet_type = packet_type,
                .checksum = checksum,
            };
        }
    };
}

pub fn DefaultPacket(T: type) type {
    return Packet(.{ .T = T });
}

pub fn Packet(config: PacketConfig) type {
    const PacketHeaderType = PacketHeader(config);
    return struct {
        header: PacketHeaderType,
        payload: []const u8,

        const Self = @This();

        pub fn init(packet_type: config.T, payload: []const u8) !Self {
            const hash = CRC32.hash(payload);
            return .{
                .header = try PacketHeaderType.init(packet_type, @intCast(payload.len), hash),
                .payload = payload,
            };
        }

        /// caller is responsible for freeing after this is called
        pub fn serialize(self: *const Self, allocator: std.mem.Allocator) ![]const u8 {
            const buffer = try allocator.alloc(u8, (self.header.header_size + self.header.payload_size) / @sizeOf(u8));
            errdefer allocator.free(buffer);
            var stream = std.io.fixedBufferStream(buffer);

            const writer = stream.writer();

            try writer.writeStruct(self.header);
            try writer.writeAll(self.payload);
            return stream.getWritten();
        }

        /// caller is responsible for freeing after this is called
        pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !Self {
            var stream = std.io.fixedBufferStream(data);
            const reader = stream.reader();

            const header = try reader.readStruct(PacketHeaderType);
            if (header.magic != config.magic_bytes) return error.InvalidMagicBytes;

            const payload = try allocator.alloc(u8, header.payload_size);
            errdefer allocator.free(payload);
            try reader.readNoEof(payload);

            if (header.checksum != CRC32.hash(payload)) return error.InvalidChecksum;

            return .{
                .header = header,
                .payload = payload,
            };
        }

        pub fn free(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.payload);
        }
    };
}

/// returned slice's lifetime will be as long as buffer argument
pub fn serialize_payload(buffer: []u8, payload: anytype) ![]u8 {
    @memset(buffer, 0);
    var stream = std.io.fixedBufferStream(buffer);

    try stream.writer().writeStructEndian(payload, .big);

    return stream.getWritten();
}

pub fn deserialize_payload(payload: []const u8, comptime T: type) !T {
    var stream = std.io.fixedBufferStream(payload);

    return try stream.reader().readStructEndian(T, .big);
}

test "packet serialization and deserialization" {
    const TestPacket = DefaultPacket(enum(u32) { host, join });

    const allocator = std.testing.allocator;
    const ack_packet = try TestPacket.init(.host, "hello, world!");

    const data = try ack_packet.serialize(allocator);
    defer allocator.free(data);

    var des_packet = try TestPacket.deserialize(data, allocator);
    defer des_packet.free(allocator);

    try std.testing.expectEqual(des_packet.header, ack_packet.header);
    try std.testing.expectEqualStrings(des_packet.payload, ack_packet.payload);
}

test "packet invalid magic bytes" {
    const TestPacket = DefaultPacket(enum(u32) { host, join });
    const TestPacketDiffBytes = Packet(.{ .T = enum(u32) { host, join }, .magic_bytes = 0xC0DEFACE });

    const allocator = std.testing.allocator;
    const ack_packet = try TestPacket.init(.host, "hello, world!");

    const data = try ack_packet.serialize(allocator);
    defer allocator.free(data);

    const err = TestPacketDiffBytes.deserialize(data, allocator);

    try std.testing.expectError(error.InvalidMagicBytes, err);
}

const TestContext = struct {};
const TestServer = Server(TestContext);
const TestClient = Client(TestContext);

test "basic server init" {
    var ctx: TestContext = .{};
    var s = try TestServer.init(4200, std.testing.allocator, &ctx);
    s.deinit();
}

test "test server timeout" {
    var ctx: TestContext = .{};
    var server = try TestServer.init(4200, std.testing.allocator, &ctx);
    defer server.deinit();
    server.set_read_timeout(200);
    const listen = server.listen();
    try std.testing.expectError(error.WouldBlock, listen);
}

test "test handshake" {
    var ctx: TestContext = .{};
    var server = try TestServer.init(4201, std.testing.allocator, &ctx);
    defer server.deinit();

    var client = try TestClient.init(std.testing.allocator, &ctx);

    const listen_thread = try std.Thread.spawn(.{ .allocator = std.testing.allocator }, TestServer.listen, .{&server});

    try client.connect("127.0.0.1", 4201, "hello world");
    listen_thread.join();

    try std.testing.expect(server.clients.size == 1);
}

test "test handshake and changed callback" {
    var ctx: TestContext = .{};
    var server = try TestServer.init(4201, std.testing.allocator, &ctx);
    defer server.deinit();
    server.handle_packet_cb = TestServer.log_data_debug;

    var client = try TestClient.init(std.testing.allocator, &ctx);

    const listen_thread = try std.Thread.spawn(.{ .allocator = std.testing.allocator }, TestServer.listen, .{&server});

    try client.connect("127.0.0.1", 4201, "hello world");
    listen_thread.join();

    try std.testing.expect(server.clients.size == 1);
}

fn _unauthorizing_client(_: *TestServer, _: []const u8, _: network.EndPoint) PacketError!void {
    return PacketError.AuthorizationError;
}

fn _listen_wrapper(server_ptr: *TestServer) !void {
    const listen = server_ptr.listen();
    if (listen != error.AuthorizationError) {
        std.log.err("Server listen error: {!}", .{listen});
        return listen;
    }
}

test "unauthorizing client request" {
    var ctx: TestContext = .{};
    var server = try TestServer.init(4201, std.testing.allocator, &ctx);
    defer server.deinit();
    server.handle_packet_cb = _unauthorizing_client;

    var client = try TestClient.init(std.testing.allocator, &ctx);

    const listen_thread = try std.Thread.spawn(.{ .allocator = std.testing.allocator }, _listen_wrapper, .{&server});

    try client.connect("127.0.0.1", 4201, "hello world");
    listen_thread.join();

    try std.testing.expect(server.clients.size == 0); // user authentication process interupted by _unauthorizing_client
}

const ReflectingTestContext = struct {
    server: *Server(ReflectingTestContext) = undefined,
};

test "self-reflecting context" {
    // valid, but considered an antipattern
    var ctx: ReflectingTestContext = .{};
    var server = try Server(ReflectingTestContext).init(4201, std.testing.allocator, &ctx);
    ctx.server = &server;
}
