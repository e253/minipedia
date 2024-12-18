const std = @import("std");
const wxmlp = @import("lib/wiki_xml_parser.zig");
const SliceArray = @import("lib/slice_array.zig").SliceArray;
const lzma = @import("lib/lzma.zig");
const mwp = @import("lib/MediaWikiParser.zig");
const passes = @import("lib/media_wiki_parser/passes.zig");
const Tracer = @import("lib/tracing.zig").TestTrace;
const MPMCQueue = @import("lib/mpmc_queue.zig").MPMCQueue;
const BufferPool = @import("lib/mpmc_queue.zig").BufferPool;

const c_allocator = std.heap.c_allocator;

// Config
const MAX_TITLE_BYTES: usize = 256;
const BLOCK_SZ_LIMIT: usize = 1_000_000;
const HEADER_SCRATCH_SPACE: usize = 15_000_000;
comptime {
    if (@mod(HEADER_SCRATCH_SPACE, 10_000) != 0)
        @compileError("HEADER_SCRATCH_SPACE must divide by 10,000");
}

const Queue = MPMCQueue(?RawArticle, 50);

const MinidumpWriter = struct {
    const Self = @This();

    a: std.mem.Allocator,
    lock: std.Thread.Mutex = .{},
    f: std.fs.File,
    block_offsets: std.ArrayList(u64),
    article_id_block_id_map: []u16,
    aid_bid_map_sz: usize = 0,

    cur_block_id: u16,
    bytes_written: u64,

    pub fn init(out_file_name: []const u8) !Self {
        var path_buf: [std.fs.MAX_PATH_BYTES]u8 = std.mem.zeroes([std.fs.MAX_PATH_BYTES]u8);
        const real_path = try std.fs.cwd().realpath(out_file_name, &path_buf);
        const f = try std.fs.createFileAbsolute(real_path, .{ .truncate = true });

        // Write header scratch space.
        {
            const zero_buf: [10_000]u8 = std.mem.zeroes([10_000]u8);
            for (0..(HEADER_SCRATCH_SPACE / 10_000)) |_| {
                try f.writeAll(&zero_buf);
            }
        }

        return .{
            .a = c_allocator,
            .f = f,
            .block_offsets = try std.ArrayList(u64).initCapacity(c_allocator, std.math.maxInt(u16)),
            .article_id_block_id_map = try c_allocator.alloc(u16, 8_000_000),
            .cur_block_id = 0,
            .bytes_written = HEADER_SCRATCH_SPACE,
        };
    }

    pub fn addBlock(s: *Self, b: Block) void {
        s.lock.lock();
        defer s.lock.unlock();

        s.f.writeAll(b.compressed_data) catch @panic("Write Error");
        s.block_offsets.append(s.bytes_written) catch @panic("OOM");
        s.bytes_written += b.compressed_data.len;

        for (b.article_ids) |article_id| {
            if (article_id >= s.article_id_block_id_map.len) {
                std.debug.print("Article ID ({}) out of bounds\n", .{article_id});
                std.process.exit(1);
            }
            s.article_id_block_id_map[article_id] = s.cur_block_id;
            if (article_id >= s.aid_bid_map_sz) {
                s.aid_bid_map_sz = article_id + 1;
            }
        }

        s.cur_block_id += 1;
    }

    /// Write prelude and header
    pub fn finish(s: Self) !void {
        const header_size: u64 = 2 * @sizeOf(u64) + s.block_offsets.items.len * @sizeOf(u64) + s.aid_bid_map_sz * @sizeOf(u16);
        if (header_size > HEADER_SCRATCH_SPACE) {
            std.debug.print("header size, {}, larger than HEADER_SCRATCH_SPACE, {}\n", .{ header_size, HEADER_SCRATCH_SPACE });
            std.process.exit(1);
        }

        const header_start: u64 = HEADER_SCRATCH_SPACE - header_size;

        try s.f.seekTo(header_start);
        const header_out_writer = s.f.writer();
        try header_out_writer.writeInt(u64, std.mem.sliceAsBytes(s.block_offsets.items).len, .big);
        try header_out_writer.writeInt(u64, s.aid_bid_map_sz * @sizeOf(u16), .big);
        try header_out_writer.writeAll(std.mem.sliceAsBytes(s.block_offsets.items));
        try header_out_writer.writeAll(std.mem.sliceAsBytes(s.article_id_block_id_map[0..s.aid_bid_map_sz]));
        std.debug.assert((try s.f.getPos()) == HEADER_SCRATCH_SPACE);

        try s.f.seekTo(0);
        const prelude_out_writer = s.f.writer();
        try prelude_out_writer.writeAll("MINIDUMP"); // Magic
        try prelude_out_writer.writeInt(u64, 0, .big); // Version
        try prelude_out_writer.writeInt(u64, header_start, .big); // Header Start
    }
};

const Block = struct {
    compressed_data: []const u8,
    article_ids: []const u32,
};

const RawArticle = struct {
    id: u32,
    /// libc allocated
    title: []const u8,
    /// PPA allocated
    text: []const u8,
};

const Worker = struct {
    worker_id: u16,
    a: std.mem.Allocator,
    /// Index into `accum_buf`.
    i: usize,
    accum_buf: []u8,
    out_buf: []u8,
    article_ids: std.ArrayList(u32),
    minidump: *MinidumpWriter,
    queue: *Queue,
    ppa: *BufferPool,
    progress: std.Progress.Node,
    stats: *Stats,

    pub fn work(s: *Worker) void {
        while (true) {
            const ra = s.queue.take() orelse break;
            defer s.ppa.releaseBuffer(ra.text);
            defer c_allocator.free(ra.title);

            var arena = std.heap.ArenaAllocator.init(s.a);
            defer arena.deinit();
            const alloc = arena.allocator();
            const processedText = wikicodeToMarkdown(alloc, ra.text, Tracer(mwp.Error){}, Tracer(passes.Error){}) catch ra.text;

            const size_to_write = processedText.len + ra.title.len + @sizeOf(usize) + "# ".len + "\n".len + "0".len;

            if (size_to_write > BLOCK_SZ_LIMIT) {
                @panic("Article larger than 1MB found!");
            }

            if (s.i + size_to_write > BLOCK_SZ_LIMIT) {
                const compressed_data = lzma.compress(null, s.accum_buf, s.out_buf) catch |err| {
                    std.debug.print("LZMA Compression Error: {s}\n", .{@errorName(err)});
                    std.process.exit(1);
                };

                s.minidump.addBlock(.{
                    .compressed_data = compressed_data,
                    .article_ids = s.article_ids.items,
                });

                s.i = 0;
                s.article_ids.clearRetainingCapacity();
            }

            var accum_buffer_fbs = std.io.fixedBufferStream(s.accum_buf[s.i..]);
            const accum_buffer_writer = accum_buffer_fbs.writer();

            accum_buffer_writer.writeInt(usize, ra.id, .big) catch unreachable;
            accum_buffer_writer.writeAll("# ") catch unreachable;
            accum_buffer_writer.writeAll(ra.title) catch unreachable;
            accum_buffer_writer.writeByte('\n') catch unreachable;
            accum_buffer_writer.writeAll(processedText) catch unreachable;
            accum_buffer_writer.writeByte(0) catch unreachable;

            s.i += size_to_write;
            s.article_ids.append(ra.id) catch @panic("OOM");

            s.progress.completeOne();
            _ = @atomicRmw(usize, &s.stats.n_articles_processed, .Add, 1, .monotonic);
        }

        if (s.i > 0) {
            const compressed_data = lzma.compress(null, s.accum_buf, s.out_buf) catch |err| {
                std.debug.print("LZMA Compression Error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };

            _ = @atomicRmw(usize, &s.stats.total_bytes_written, .Add, compressed_data.len, .monotonic);

            s.minidump.addBlock(.{
                .compressed_data = compressed_data,
                .article_ids = s.article_ids.items,
            });

            s.i = 0;
            s.article_ids.clearRetainingCapacity();
        }

        s.a.free(s.accum_buf);
        s.a.free(s.out_buf);
        s.article_ids.deinit();
    }
};

pub fn main() !void {
    const args = try Args.parse();

    var stats: Stats = .{ .start_time_ms = std.time.milliTimestamp() };

    var stdinBR = std.io.bufferedReader(std.io.getStdIn().reader());
    const stdin = stdinBR.reader();

    var minidump = try MinidumpWriter.init(args.out_file_name);
    var queue: Queue = .{};

    var page_pool = try BufferPool.init(c_allocator, 50 + 4 + 1, BLOCK_SZ_LIMIT);
    defer page_pool.deinit();

    const global_progress = std.Progress.start(.{});
    defer global_progress.end();
    const progress = global_progress.start("Article Procressing", args.n_articles_to_process);
    defer progress.end();

    const workers = try c_allocator.alloc(Worker, 4);
    defer c_allocator.free(workers);
    const threads = try c_allocator.alloc(std.Thread, 4);
    defer c_allocator.free(threads);

    for (workers, threads, 0..) |*worker, *thread, i| {
        worker.* = .{
            .worker_id = @intCast(i),
            .a = c_allocator,
            .i = 0,
            .accum_buf = try c_allocator.alloc(u8, BLOCK_SZ_LIMIT),
            .out_buf = try c_allocator.alloc(u8, BLOCK_SZ_LIMIT),
            .article_ids = try std.ArrayList(u32).initCapacity(c_allocator, 500),
            .minidump = &minidump,
            .queue = &queue,
            .ppa = &page_pool,
            .progress = progress,
            .stats = &stats,
        };
        thread.* = try std.Thread.spawn(.{}, Worker.work, .{worker});
    }

    var titles_file = try std.fs.cwd().createFile("titles.txt", .{});
    defer titles_file.close();
    var titlesBW = std.io.bufferedWriter(titles_file.writer());
    const titles = titlesBW.writer();

    const page_buffer = try c_allocator.alloc(u8, BLOCK_SZ_LIMIT);
    var article_id: u32 = 0;
    while (article_id < args.n_articles_to_process) {
        // TODO: Use `page_buffer` to buffer reads.
        const xmlPage = wxmlp.readPage(stdin, page_buffer) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };

        stats.total_bytes_read += xmlPage.len;

        // TODO: Rather than [XML-parse --> pre-process --> copy --> parse MW-Markup --> codegen passes --> copy],
        // [XML-parse until MW (<text>), parse MW in place stopping on </text> --> codegen passes --> copy].
        // Removes one copy step and two scalar scans over the article.

        // TODO: This and below should be done in each worker.
        // Rapidxml memory pool is not thread safe.
        const wikiArticle = wxmlp.parsePage(xmlPage) orelse {
            stats.n_redirects_skipped += 1;
            continue;
        };

        try titles.writeAll(wikiArticle.title);
        try titles.writeByte('\n');

        stats.total_article_bytes_read += wikiArticle.article.len;

        const pp_page_buffer = page_pool.acquireBuffer();

        const preProcessedArticle = try preprocessArticle(c_allocator, wikiArticle.article, pp_page_buffer);
        const title = c_allocator.dupe(u8, wikiArticle.title) catch @panic("OOM");

        const ra: RawArticle = .{ .id = article_id, .text = preProcessedArticle, .title = title };
        article_id += 1;

        queue.send(ra);
    }

    for (threads) |_| queue.send(null);
    for (threads) |t| t.join();

    stats.end_time_ms = std.time.milliTimestamp();

    try minidump.finish();

    stats.toStdout();
}

/// Performs substitutions before wikitext can be parsed to an AST
///
/// Uses `SliceArray` for performance
///
/// `'''''` to `***`
///
/// `'''` to `**`
///
/// `''` to `*`
///
/// `&quot;` to `"`
///
/// `&lt;` to `<`
///
/// `&gt;` to `>`
///
/// `&amp;` to `&`
///
/// `&apos;` to `'`
///
/// delete `\r`
fn preprocessArticle(a: std.mem.Allocator, article: []const u8, out: []u8) ![]u8 {
    var sa = SliceArray.init(a);
    defer sa.deinit();
    try sa.append(article);

    try sa.findAndReplace("'''''", "***");
    try sa.findAndReplace("'''", "**");
    try sa.findAndReplace("''", "*");
    try sa.findAndReplace("&quot;", "\"");
    try sa.findAndReplace("&lt;", "<");
    try sa.findAndReplace("&gt;", ">");
    try sa.findAndReplace("&amp;", "&");
    try sa.findAndReplace("&apos;", "'");
    try sa.findAndReplace("\r", "");

    return try sa.writeToSlice(out);
}

/// Uses `mwp.parseDocument` to convert Wikicode AST to more concise and clean text
fn wikicodeToMarkdown(a: std.mem.Allocator, raw_wikitext: []const u8, parse_tracer: anytype, gen_tracer: anytype) ![]const u8 {
    var doc = try mwp.parseDocument(a, raw_wikitext, parse_tracer);

    passes.cleanAST(&doc) catch |err| {
        return gen_tracer.err(err);
    };

    passes.removeReferences(&doc) catch |err| {
        return gen_tracer.err(err);
    };

    passes.toText(a, &doc) catch |err| {
        return gen_tracer.err(err);
    };

    const out = try a.alloc(u8, try passes.textSize(&doc));
    var out_strm = std.io.fixedBufferStream(out);
    const out_wtr = out_strm.writer();

    passes.writeText(&doc, out_wtr) catch |err| {
        return gen_tracer.err(err);
    };

    try gen_tracer.success();
    return out;
}

pub const Stats = struct {
    total_bytes_read: usize = 0,
    total_article_bytes_read: usize = 0,
    total_bytes_written: usize = 0,
    n_articles_processed: usize = 0,
    n_redirects_skipped: usize = 0,
    start_time_ms: i64 = 0,
    end_time_ms: i64 = 0,

    pub fn toStdout(this: *Stats) void {
        const stdout = std.io.getStdOut().writer();

        stdout.print("Processed {} articles, skipped {} redirects\n", .{ this.n_articles_processed, this.n_redirects_skipped }) catch unreachable;

        stdout.print("Read {d} MB. Avg article len {d} KB\n", .{
            tof32(this.total_bytes_read) / 1_000_000.0,
            tof32(this.total_article_bytes_read) / tof32(this.n_articles_processed) / 1_000.0,
        }) catch unreachable;

        stdout.print("Wrote {} (header) + {d} MB. Avg article size {d} KB\n", .{
            HEADER_SCRATCH_SPACE / 1_000_000,
            tof32(this.total_bytes_written) / 1_000_000.0,
            tof32(this.total_bytes_written) / tof32(this.n_articles_processed) / 1_000.0,
        }) catch unreachable;

        const t_in_s = @divFloor((this.end_time_ms - this.start_time_ms), 1000);
        stdout.print("{} min {} sec\n", .{ @divFloor(t_in_s, 60), @mod(t_in_s, 60) }) catch unreachable;

        const articles_per_s = tof32(this.n_articles_processed) / (tof32(this.end_time_ms - this.start_time_ms) / 1000.0);
        stdout.print("{d} articles/s\n", .{articles_per_s}) catch unreachable;
    }

    inline fn tof32(in: anytype) f32 {
        return @floatFromInt(in);
    }
};

pub const Args = struct {
    n_articles_to_process: usize = std.math.maxInt(usize),
    out_file_name: []const u8 = "./out.minidump",

    pub const ParseError = error{
        Help,
        TooManyArgs,
    };

    pub fn parse() !Args {
        const sT = std.mem.sliceTo;

        const help =
            \\Usage:
            \\{s} [out_file (str)]='./out.minidump' [max_articles_to_write (int)]=inf
            \\
        ;
        const argv0 = sT(std.os.argv[0], 0);

        if (std.os.argv.len == 1) {
            try std.io.getStdOut().writeAll("processing articles until eof\n");
            return .{};
        }

        if (std.os.argv.len == 2) {
            const argv1 = sT(std.os.argv[1], 0);

            if (std.mem.eql(u8, argv1, "--help")) {
                std.debug.print(help, .{argv0});
                return ParseError.Help;
            }

            try std.io.getStdOut().writeAll("processing articles until eof\n");

            return .{
                .out_file_name = argv1,
            };
        }

        if (std.os.argv.len == 3) {
            const argv1 = sT(std.os.argv[1], 0);
            const argv2 = sT(std.os.argv[2], 0);

            const n_articles_to_process = std.fmt.parseInt(usize, argv2, 10) catch |err| {
                std.debug.print(help, .{argv0});
                return err;
            };

            return .{
                .out_file_name = argv1,
                .n_articles_to_process = n_articles_to_process,
            };
        }

        return ParseError.TooManyArgs;
    }
};
