//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

pub const network = @import("network");

pub const PacketError = error{ DeserializationError, AuthorizationError, BadInput, OutOfMemory };

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

        pub fn send_to(self: *Self, to: network.EndPoint, data: []const u8) void {
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

            try self.socket.setReadTimeout(100);

            var buff: [BUFF_SIZE]u8 = undefined;

            const from = try socket.receiveFrom(&buff);
            std.debug.assert(from.numberOfBytes <= BUFF_SIZE);

            try self.handle_packet_cb(self, buff[0..from.numberOfBytes], from.sender);
        }
    };
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
