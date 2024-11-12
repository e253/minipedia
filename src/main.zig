const std = @import("std");
const wxmlp = @import("wikixmlparser.zig");
const SliceArray = @import("slice_array.zig").SliceArray;
const lzma = @import("lzma.zig");
const mwp = @import("MediaWikiParser.zig");
const passes = @import("passes.zig");
const DuckTrace = @import("tracing.zig").DuckTrace;

const c_allocator = std.heap.c_allocator;

pub fn main() !void {
    const args = try Args.parse();

    var stats: Stats = .{ .start_time_ms = std.time.milliTimestamp() };

    var stdinBR = std.io.bufferedReader(std.io.getStdIn().reader());
    const stdin = stdinBR.reader();

    var out_file = try std.fs.cwd().createFile(args.out_file_name, .{});
    defer out_file.close();
    const out = out_file.writer();

    var titles_file = try std.fs.cwd().createFile("titles.txt", .{});
    defer titles_file.close();
    var titlesBW = std.io.bufferedWriter(titles_file.writer());
    const titles = titlesBW.writer();

    const fbaBuffer = try c_allocator.alloc(u8, 4096 * 2048);
    defer c_allocator.free(fbaBuffer);
    var fba = std.heap.FixedBufferAllocator.init(fbaBuffer);
    const fbaAlloc = fba.allocator();

    const page_buffer = try c_allocator.alloc(u8, 4096 * 2048);
    defer c_allocator.free(page_buffer);

    // Initialize DuckDB tracing.
    var duckTrace = try DuckTrace.init("logs.db");

    // Write 15MB of 0s
    const tmp_zero_buf = try fbaAlloc.alloc(u8, 100_000);
    @memset(tmp_zero_buf, 0);
    inline for (0..150) |_| {
        try out.writeAll(tmp_zero_buf);
    }
    fbaAlloc.free(tmp_zero_buf);

    // Header
    var block_offsets = std.ArrayList(u64).init(std.heap.c_allocator);
    defer block_offsets.deinit();
    var article_id_block_id_map = std.ArrayList(u16).init(std.heap.c_allocator);
    defer article_id_block_id_map.deinit();

    // Block
    var block_id: u16 = 0;
    var lzma_block_size: usize = 0;
    var lzma_last_block_size: usize = 0; // we need to know how large the last block was to create an offset for the current one
    const lzma_block_size_limit: usize = 1_000_000;
    var lzma_block_accum_buffer = try std.heap.c_allocator.alloc(u8, lzma_block_size_limit);
    defer std.heap.c_allocator.free(lzma_block_accum_buffer);
    const lzma_block_out_buffer = try std.heap.c_allocator.alloc(u8, lzma_block_size_limit);
    defer std.heap.c_allocator.free(lzma_block_out_buffer);

    var document_id: usize = 0;
    while (document_id < args.n_articles_to_process) {
        var arena = std.heap.ArenaAllocator.init(fbaAlloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const xmlPage = wxmlp.readPage(stdin, page_buffer) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };

        stats.total_bytes_read += xmlPage.len;

        const wikiArticle = wxmlp.parsePage(xmlPage) orelse {
            stats.n_redirects_skipped += 1;
            continue;
        };

        try titles.writeAll(wikiArticle.title);
        try titles.writeByte('\n');

        stats.total_article_bytes_read += wikiArticle.article.len;

        const preProcessedArticle = try preprocessArticle(alloc, wikiArticle.article);

        var duckTraceDocInstance = duckTrace.newInstance(document_id, preProcessedArticle, mwp.Error);
        var duckTraceGenInstance = duckTrace.newInstance(document_id, "", passes.Error);
        duckTraceGenInstance.section = .Parsing;
        const processedArticle = wikicodeToMarkdown(alloc, preProcessedArticle, &duckTraceDocInstance, &duckTraceGenInstance) catch blk: {
            stats.n_articles_failed_parsing += 1;
            break :blk preProcessedArticle;
        };

        const size_to_write = processedArticle.len + wikiArticle.title.len + @sizeOf(usize) + "# ".len + "\n".len + "0".len;

        if (size_to_write > lzma_block_size_limit) {
            @panic("Article larger than 1MB found!");
        }

        // block is full! compress contents and flush them out
        // add a block_offset to the array
        if (lzma_block_size + size_to_write >= lzma_block_size_limit) {
            const compressed_output = try lzma.compress(null, lzma_block_accum_buffer[0..lzma_block_size], lzma_block_out_buffer);
            try out.writeAll(compressed_output);

            if (block_offsets.items.len == 0) {
                try block_offsets.append(15_000_000);
            } else {
                try block_offsets.append(block_offsets.items[block_offsets.items.len - 1] + lzma_last_block_size);
            }

            lzma_last_block_size = compressed_output.len;
            lzma_block_size = 0;
            stats.total_bytes_written += compressed_output.len;
            block_id += 1;
        }

        var accum_buffer_fbs = std.io.fixedBufferStream(lzma_block_accum_buffer[lzma_block_size..]);
        const accum_buffer_writer = accum_buffer_fbs.writer();

        try accum_buffer_writer.writeInt(usize, document_id, .big);
        try accum_buffer_writer.writeAll("# ");
        try accum_buffer_writer.writeAll(wikiArticle.title);
        try accum_buffer_writer.writeByte('\n');
        try accum_buffer_writer.writeAll(processedArticle);
        try accum_buffer_writer.writeByte(0);

        lzma_block_size += size_to_write;

        // Write down what block this article is in
        try article_id_block_id_map.append(block_id);

        stats.n_articles_processed += 1;
        document_id += 1;
    }

    if (lzma_block_size > 0) {
        const compressed_output = try lzma.compress(null, lzma_block_accum_buffer[0..lzma_block_size], lzma_block_out_buffer);
        try out.writeAll(compressed_output);
        lzma_block_size = 0;
        stats.total_bytes_written += compressed_output.len;

        if (block_offsets.items.len == 0) {
            try block_offsets.append(15_000_000);
        } else {
            try block_offsets.append(block_offsets.items[block_offsets.items.len - 1] + lzma_last_block_size);
        }
    }

    // Write prelude and header
    const header_size: u64 = 2 * @sizeOf(u64) + block_offsets.items.len * @sizeOf(u64) + article_id_block_id_map.items.len * @sizeOf(u16);
    std.debug.assert(header_size < 15_000_000);
    const header_start: u64 = 15_000_000 - header_size;

    try out_file.seekTo(header_start);
    const header_out_writer = out_file.writer();
    try header_out_writer.writeInt(u64, std.mem.sliceAsBytes(block_offsets.items).len, .big);
    try header_out_writer.writeInt(u64, std.mem.sliceAsBytes(article_id_block_id_map.items).len, .big);
    try header_out_writer.writeAll(std.mem.sliceAsBytes(block_offsets.items));
    try header_out_writer.writeAll(std.mem.sliceAsBytes(article_id_block_id_map.items));
    std.debug.assert((try out_file.getPos()) == 15_000_000);

    try out_file.seekTo(0);
    const prelude_out_writer = out_file.writer();
    try prelude_out_writer.writeAll("MINIDUMP"); // Magic
    try prelude_out_writer.writeInt(u64, 0, .big); // Version
    try prelude_out_writer.writeInt(u64, header_start, .big); // Header Start

    stats.end_time_ms = std.time.milliTimestamp();

    duckTrace.deinit();

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
fn preprocessArticle(a: std.mem.Allocator, article: []const u8) ![]const u8 {
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

    return try sa.toSlice();
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
    n_articles_failed_parsing: usize = 0,
    start_time_ms: i64 = 0,
    end_time_ms: i64 = 0,

    pub fn toStdout(this: *Stats) void {
        const stdout = std.io.getStdOut().writer();

        stdout.print("Processed {} articles, skipped {} redirects and {} parsing errors\n", .{ this.n_articles_processed, this.n_redirects_skipped, this.n_articles_failed_parsing }) catch unreachable;

        stdout.print("Read {d} MB. Avg article len {d} KB\n", .{
            tof32(this.total_bytes_read) / 1_000_000.0,
            tof32(this.total_article_bytes_read) / tof32(this.n_articles_processed) / 1_000.0,
        }) catch unreachable;

        stdout.print("Wrote 15 (header) + {d} MB. Avg article len {d} KB\n", .{
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
            std.debug.print("processing articles until eof\n", .{});
            return .{};
        }

        if (std.os.argv.len == 2) {
            const argv1 = sT(std.os.argv[1], 0);

            if (std.mem.eql(u8, argv1, "--help")) {
                std.debug.print(help, .{argv0});
                return ParseError.Help;
            }

            std.debug.print("processing articles until eof\n", .{});

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
