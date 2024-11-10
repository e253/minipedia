const std = @import("std");
const httpz = @import("httpz");
const stdout = std.io.getStdOut();
const MinidumpReader = @import("minidump_reader.zig");

const c_allocator = std.heap.c_allocator;

const ADDRESS = "127.0.0.1";
const PORT: u16 = 3000;

pub const State = struct {
    mdr: MinidumpReader,
};

pub fn main() !void {
    const mdr = try MinidumpReader.init(c_allocator, "./out.minidump");
    const state = State{ .mdr = mdr };

    var server = try httpz.ServerApp(State).init(c_allocator, .{ .address = ADDRESS, .port = PORT }, state);
    defer server.deinit();

    try std.fmt.format(stdout.writer(), "http://{s}:{}/\n\n", .{ ADDRESS, PORT });

    var router = server.router();

    router.get("/wiki/id/:id", serveArticle);
    router.get("/*", spa);

    try server.listen();
}

fn spa(_: State, _: *httpz.Request, res: *httpz.Response) !void {
    const SPA = @embedFile("index.html");
    res.content_type = .HTML;
    res.body = SPA;
}

fn serveArticle(s: State, req: *httpz.Request, res: *httpz.Response) !void {
    const id_str_opt = req.param("id");
    if (id_str_opt == null) {
        res.status = 400;
        res.body =
            \\<h1> No article id found </h1>
        ;
        return;
    }
    const id = std.fmt.parseInt(u64, id_str_opt.?, 10) catch |err| {
        res.status = 400;
        try std.fmt.format(res.writer(), "<h1>Could not parse '{s}' to u64. error.{s}</h1>", .{ id_str_opt.?, @errorName(err) });
        return;
    };

    if (try s.mdr.markdown(id)) |markdown| {
        res.status = 200;
        res.body = markdown;
    } else {
        res.status = 404;
        try std.fmt.format(res.writer(), "<h1> No article for id {} </h1>", .{id});
    }
}
