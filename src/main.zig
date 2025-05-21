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

fn init_array32(str: []const u8) [32]u8 {
    if (str.len > 32) @panic("string too long");
    var buf: [32]u8 = undefined;
    for (str, 0..) |c, i| {
        buf[i] = c;
    }
    for (str.len..32) |i| {
        buf[i] = 0;
    }
    return buf;
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
    var buffer: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    switch (packet.header.packet_type) {
        .host => {
            var _stream = std.io.fixedBufferStream(packet.payload);
            const reader = _stream.reader();
            const join_payload = reader.readStructEndian(HostPayload, .big) catch return error.BadInput;

            const dupe_scope = try self.allocator.dupe(u8, join_payload.scope[0..join_payload.scope.len]);
            const dupe_key = try self.allocator.dupe(u8, join_payload.key[0..join_payload.key.len]);

            const scope_exist = self.ctx.scopes.getPtr(dupe_scope);
            if (scope_exist) |scope| {
                const lobby_exist: ?*Lobby = scope.lobbies.getPtr(dupe_key);
                if (lobby_exist) |_| {
                    return;
                }

                var lobby: Lobby = .{};
                try lobby.members.append(self.allocator, sender);
                try scope.lobbies.put(self.allocator, dupe_key, lobby);

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
            const reader = stream.reader();
            const join_payload = reader.readStructEndian(JoinPayload, .big) catch return error.BadInput;

            const dupe_scope = try self.allocator.dupeZ(u8, join_payload.scope[0..join_payload.scope.len]);
            const dupe_key = try self.allocator.dupeZ(u8, join_payload.key[0..join_payload.key.len]);

            const scope_exist = self.ctx.scopes.getPtr(dupe_scope);
            if (scope_exist) |scope| {
                const lobby_exist: ?*Lobby = scope.lobbies.getPtr(dupe_key);
                if (lobby_exist) |lobby| {
                    std.log.info("{any} new host {s}:{s}", .{ sender, dupe_scope, dupe_key });
                    try lobby.members.append(self.allocator, sender);
                }
            }

            self.allocator.free(dupe_scope);
            self.allocator.free(dupe_key);
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

test "simple connection test" {
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

    const host_payload: HostPayload = .{ .key = init_array32("hello"), .scope = init_array32("world") };
    try stream.writer().writeStructEndian(host_payload, .big);
    const ack_packet = try Packet.init(.host, stream.getWritten());
    const data = try ack_packet.serialize(allocator);
    defer allocator.free(data);

    try client.connect("127.0.0.1", 2800, data);
    thread.join();

    try std.testing.expect(client.target != null);
    try std.testing.expectEqual(server.clients.size, 1);

    const found_scope = state.scopes.get(&init_array32("world"));
    if (found_scope) |scope| {
        try std.testing.expectEqual(scope.lobbies.size, 1);
    } else {
        return error.MissingScope;
    }
}

fn _listen_wrapper(server_ptr: *lib.Server(State)) !void {
    while (server_ptr.clients.size < 2) {
        _ = try server_ptr.listen();
    }
}
