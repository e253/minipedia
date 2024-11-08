const std = @import("std");
const std_options = .{ .log_level = .debug };

const alloc = std.heap.c_allocator;

pub fn main() !void {
    const address = std.net.Address.parseIp("127.0.0.1", 3000) catch unreachable;
    try std.io.getStdOut().writeAll("listening http://127.0.0.1:3000\n");
    var http_server = try address.listen(.{});

    while (true) {
        const connection = try http_server.accept();
        _ = std.Thread.spawn(.{}, handleConnection, .{connection}) catch |err| {
            std.log.err("unable to accept connection: {s}", .{@errorName(err)});
        };
    }
}

const Context = struct {
    a: std.mem.Allocator,
};

fn handleConnection(connection: std.net.Server.Connection) void {
    defer connection.stream.close();

    var read_buffer: [8000]u8 = undefined;
    var server = std.http.Server.init(connection, &read_buffer);
    while (server.state == .ready) {
        // grab request
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.err("closing http connection: {s}", .{@errorName(err)});
                return;
            },
        };
        handleRequest(&request) catch |err| {
            std.log.err("unabled to handle request {s}: {s}", .{ request.head.target, @errorName(err) });
            return;
        };
    }
}

fn handleRequest(req: *std.http.Server.Request) !void {
    const route = req.head.target;

    if (std.mem.startsWith(u8, route, "/wiki/") and route.len > "/wiki/".len) {
        const article = route["/wiki/".len..];

        var out_buf: [200]u8 = undefined;
        const out = try std.fmt.bufPrint(&out_buf, "<h1>{s}<h1>", .{article});
        try req.respond(out, .{});
    } else {
        try req.respond("<h1> No Match </h1>", .{});
    }
}
