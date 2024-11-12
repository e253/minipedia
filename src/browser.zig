const std = @import("std");
const httpz = @import("httpz");
const stdout = std.io.getStdOut();
const MinidumpReader = @import("minidump_reader.zig");
const TitleIndex = @import("title_index.zig");

const c_allocator = std.heap.c_allocator;

const ADDRESS = "127.0.0.1";
const PORT: u16 = 3000;

pub const State = struct {
    mdr: MinidumpReader,
    ti: TitleIndex,
};

pub fn main() !void {
    const mdr = try MinidumpReader.init(c_allocator, "./out.minidump");
    const ti = try TitleIndex.init("./out.index");
    var state = State{ .mdr = mdr, .ti = ti };

    var server = try httpz.ServerApp(*State).init(c_allocator, .{ .address = ADDRESS, .port = PORT }, &state);
    defer server.deinit();
    defer server.stop();
    try std.fmt.format(stdout.writer(), "http://{s}:{}/\n\n", .{ ADDRESS, PORT });

    server.dispatcher(dispatcher);
    var router = server.router();

    router.get("/api/article/:id", serveArticle);
    router.get("/api/search", search);
    router.get("/*", spa);

    try server.listen();
}

fn spa(_: *State, _: *httpz.Request, res: *httpz.Response) !void {
    const SPA = @embedFile("index.html");
    res.content_type = .HTML;
    res.body = SPA;
}

fn serveArticle(s: *State, req: *httpz.Request, res: *httpz.Response) !void {
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

/// searches for query param `q`
///
/// Returns at most `l` matches (`1 <= l <= 20`)
fn search(s: *State, req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();

    if (query.get("q")) |q| {
        const limit = blk: {
            if (query.get("l")) |limit_str| {
                const limit = std.fmt.parseInt(usize, limit_str, 10) catch {
                    break :blk 10;
                };
                if (limit < 1) {
                    break :blk 1;
                } else if (limit > 20) {
                    break :blk 20;
                } else {
                    break :blk limit;
                }
            }
            break :blk 10;
        };

        var matches_buf: [20]TitleIndex.Match = undefined;
        var matches = matches_buf[0..limit];
        var matches_str_buf: [256 * 20]u8 = undefined;

        try s.ti.search(q, limit, &matches, &matches_str_buf);

        try std.json.stringify(matches, .{}, res.writer());
    } else {
        std.debug.print("No q!", .{});
        res.content_type = .JSON;
        res.body = "[]";
    }
}

fn dispatcher(s: *State, action: httpz.Action(*State), req: *httpz.Request, res: *httpz.Response) !void {
    var timer = std.time.Timer.start() catch @panic("Gettime systcall failed in logger");

    std.log.info("<-- {s} {s}?{s}", .{ @tagName(req.method), req.url.path, req.url.query });

    defer {
        const elapsed = timer.read() / 1_000_000; // ns --> ms
        std.log.info("--> {s} {s}?{s} {d} {d}ms", .{ @tagName(req.method), req.url.path, req.url.query, res.status, elapsed });
    }

    return action(s, req, res);
}
