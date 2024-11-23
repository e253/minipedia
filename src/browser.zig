const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");
const MinidumpReader = @import("minidump_reader.zig");
const Minisearch = @import("minisearch.zig");
const frontend = @import("frontend"); // generated

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
    try std.fmt.format(std.io.getStdOut().writer(), "http://{s}:{}/\n\n", .{ ADDRESS, PORT });

    server.dispatcher(dispatcher);
    var router = server.router();

    router.get("/api/article", serveArticle);
    router.get("/api/search", search);
    router.get("/*", spa);

    try server.listen();
}

fn registerCleanShutdown() !void {
    if (builtin.target.os.tag != .windows) {
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
    } else {
        try std.os.windows.SetConsoleCtrlHandler(&win_shutdown, true);
    }
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

fn win_shutdown(_: std.os.windows.DWORD) callconv(std.os.windows.WINAPI) std.os.windows.BOOL {
    if (shutdown_lock.tryLock()) {
        defer shutdown_lock.unlock();
        if (server_instance) |server| {
            server.stop();
            server_instance = null;
            std.io.getStdIn().writeAll("\rBye!\n") catch {};
            return std.os.windows.TRUE;
        }
    }
    return std.os.windows.FALSE;
}

fn spa(_: State, req: *httpz.Request, res: *httpz.Response) !void {
    if (frontend.files.get(req.url.path)) |contents| {
        res.content_type = contentTypeFromPath(req.url.path);
        res.body = contents;
    } else {
        res.content_type = .HTML;
        res.body = frontend.files.get("/fallback.html").?;
    }
}

fn contentTypeFromPath(path: []const u8) httpz.ContentType {
    const ext_type_pairs = [_]struct { []const u8, httpz.ContentType }{
        .{ ".js", .JS },
        .{ ".html", .JS },
    };

    inline for (ext_type_pairs) |pair| {
        if (path.len > pair[0].len and std.mem.eql(u8, path[path.len - pair[0].len ..], pair[0])) {
            return pair[1];
        }
    }

    return .UNKNOWN;
}

fn serveArticle(s: State, req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();

    if (query.get("title")) |title| {
        if (title.len == 0) {
            res.status = 400;
            res.body = "Invalid 'title': empty title.";
        } else if (std.mem.indexOfAny(u8, title, &std.ascii.whitespace) != null) {
            res.status = 400;
            res.body = "Invalid 'title': contains whitespace.";
        } else if (title.len > Minisearch.MAX_TITLE_SIZE) {
            res.status = 400;
            try std.fmt.format(res.writer(), "Invalid 'title': Exceeds the max size, {}", .{Minisearch.MAX_TITLE_SIZE});
        } else {
            // Wikititle url encoding replaces spaces with underscores.
            // We want the canonical version for searching.
            var scratch: [Minisearch.MAX_TITLE_SIZE]u8 = undefined;
            @memcpy(scratch[0..title.len], title);
            const normalized_title = scratch[0..title.len];
            std.mem.replaceScalar(u8, normalized_title, '_', ' ');

            if (s.search.doc(normalized_title)) |doc_id| {
                try serveArticleByID(s.reader, doc_id, res);
            } else {
                res.status = 404;
                try std.fmt.format(res.writer(), "No article for title '{s}' in the index.", .{normalized_title});
            }
        }
    } else if (query.get("id")) |id_str| {
        _ = id_str;
        // TODO
        res.status = 400;
        res.body = "'id' query param not supported yet";
    } else {
        res.status = 400;
        res.content_type = .TEXT;
        res.body = "Invalid request: no 'title' or 'id' query parameters provided";
    }
}

fn serveArticleByID(reader: MinidumpReader, id: usize, res: *httpz.Response) !void {
    if (try reader.markdown(id)) |markdown| {
        res.status = 200;
        res.body = markdown;
    } else {
        res.status = 404;
        try std.fmt.format(res.writer(), "No article for id {}", .{id});
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
