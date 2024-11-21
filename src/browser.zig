const std = @import("std");
const httpz = @import("httpz");
const stdout = std.io.getStdOut();
const MinidumpReader = @import("minidump_reader.zig");
const Minisearch = @import("minisearch.zig");

const c_allocator = std.heap.c_allocator;

const ADDRESS = "127.0.0.1";
const PORT: u16 = 3000;

const State = struct {
    reader: MinidumpReader,
    search: Minisearch,
};

var server_instance: ?*httpz.ServerCtx(State, State) = null;

pub fn main() !void {
    try registerCleanShutdown();

    const reader = try MinidumpReader.init(c_allocator, "./out.minidump");
    defer reader.deinit();
    const minisearch = Minisearch.init("./search_index");
    defer minisearch.deinit();

    const state: State = .{
        .reader = reader,
        .search = minisearch,
    };

    var server = try httpz.ServerApp(State).init(c_allocator, .{ .address = ADDRESS, .port = PORT }, state);
    defer server.deinit();
    server_instance = &server;
    try std.fmt.format(stdout.writer(), "http://{s}:{}/\n\n", .{ ADDRESS, PORT });

    server.dispatcher(dispatcher);
    var router = server.router();

    router.get("/api/article/:id", serveArticle);
    router.get("/api/search", search);
    router.get("/*", spa);

    try server.listen();
}

fn registerCleanShutdown() !void {
    try std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);
    try std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);
}

var shutdown_lock = std.Thread.Mutex{};
fn shutdown(_: c_int) callconv(.C) void {
    if (shutdown_lock.tryLock()) {
        defer shutdown_lock.unlock();
        if (server_instance) |server| {
            server.stop();
            server_instance = null;
            std.io.getStdIn().writeAll("\rBye!\n") catch {};
        }
    }
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
            \\<h1> No article id provided </h1>
        ;
        return;
    }
    const id = std.fmt.parseInt(u64, id_str_opt.?, 10) catch |err| {
        res.status = 400;
        try std.fmt.format(res.writer(), "<h1>Could not parse '{s}' to u64. error.{s}</h1>", .{ id_str_opt.?, @errorName(err) });
        return;
    };

    if (try s.reader.markdown(id)) |markdown| {
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
fn search(s: State, req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();

    if (query.get("q")) |q| {
        if (q.len > 256) {
            res.content_type = .TEXT;
            res.body = "Query must be less than 256 characters.";
            res.status = 400;
            return;
        }

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

        const results = try s.search.search(res.arena, q, limit, 0);

        try std.json.stringify(results, .{}, res.writer());
    } else {
        res.content_type = .JSON;
        res.body = "[]";
    }
}

fn dispatcher(s: State, action: httpz.Action(State), req: *httpz.Request, res: *httpz.Response) !void {
    var timer = std.time.Timer.start() catch @panic("Gettime syscall failed in logger");

    if (req.url.query.len == 0) {
        std.log.info("<-- {s} {s}", .{ @tagName(req.method), req.url.path });
    } else {
        std.log.info("<-- {s} {s}?{s}", .{ @tagName(req.method), req.url.path, req.url.query });
    }

    defer {
        const elapsed = timer.read() / 1_000_000; // ns --> ms
        if (req.url.query.len == 0) {
            std.log.info("--> {s} {s} {d} {d}ms", .{ @tagName(req.method), req.url.path, res.status, elapsed });
        } else {
            std.log.info("--> {s} {s}?{s} {d} {d}ms", .{ @tagName(req.method), req.url.path, req.url.query, res.status, elapsed });
        }
    }

    return action(s, req, res);
}
