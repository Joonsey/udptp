//! A sample test client for demonstration & testing purposes
//! is not included in primary server build binary

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

const State = struct {
    should_stop: bool = false,
    scope: [32]u8,

    allocator: std.mem.Allocator,
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

fn handle_packet(self: *Client, data: []const u8, _: lib.network.EndPoint) !void {
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

fn handle_stdin(self: *Client) void {
    const stdin = std.io.getStdIn();
    var buffer: [2048]u8 = undefined;
    const reader = stdin.reader();
    const stdin_buffer = reader.readUntilDelimiterOrEof(&buffer, '\n') catch unreachable;
    const data = stdin_buffer orelse "Q";

    const separator = std.mem.indexOfScalar(u8, data, ' ') orelse data.len;
    const pruned_argument = if (separator == data.len) data[separator..] else data[separator + 1 ..];
    if (std.meta.stringToEnum(Commands, data[0..separator])) |cmd| handle_command(self, cmd, pruned_argument) catch unreachable;
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
            const packet = try Packet.init(.host, try lib.serialize_payload(&packet_buffer, HostPayload{ .scope = self.ctx.scope, .key = to_fixed(arguments, 32) }));
            const data = try packet.serialize(self.allocator);
            self.send(data);
            self.allocator.free(data);
            std.log.info("hosted new server at: {s}:{s}", .{ self.ctx.scope, arguments });
        },
        .Join, .j => {
            if (arguments.len < 1 or arguments.len > 32) {
                std.log.err("argument for JOIN must be between 1<32. got {d}", .{arguments.len});
                return;
            }
            const packet = try Packet.init(.join, try lib.serialize_payload(&packet_buffer, JoinPayload{ .scope = self.ctx.scope, .key = to_fixed(arguments, 32) }));
            const data = try packet.serialize(self.allocator);
            self.send(data);
            self.allocator.free(data);
            std.log.info("sendt join request to {s}:{s}", .{ self.ctx.scope, arguments });
        },
        .UpdateHostList, .u => {
            const packet = try Packet.init(.req_host_list, try lib.serialize_payload(&packet_buffer, RequestHostListPayload{ .scope = self.ctx.scope }));
            const data = try packet.serialize(self.allocator);
            self.send(data);
            self.allocator.free(data);
        },
        .Help => {
            std.log.info("Available commands\nQ - Quit\nHost <host key> - hosts a lobby\nJoin <host key> - joins a lobby\nUpdateHostList - updates host list\nClose - closes hosted session\nHelp - brings up this", .{});
        },
        else => {
            std.log.info("{any}: {s}", .{ cmd, arguments });
        },
    }
}

fn listen_thread(client: *Client) !void {
    while (!client.ctx.should_stop)
        client.listen() catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
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
    try client.connect("127.0.0.1", PORT, data);

    std.log.info("client connecting... with scope {s}", .{state.scope});
    const thread = try std.Thread.spawn(.{ .allocator = allocator }, listen_thread, .{&client});
    while (!state.should_stop) {
        handle_stdin(&client);
    }

    thread.join();
    std.log.info("gracefully exited", .{});
}
