const std = @import("std");
const wxmlp = @import("wikixmlparser.zig");
const SliceArray = @import("slice_array.zig").SliceArray;
const lzma = @import("lzma.zig");
const MWParser = @import("MediaWikiParser.zig").MWParser;

pub const std_options = .{ .log_level = .debug };

pub fn main() !void {
    const args = try Args.parse();

    const start_time = std.time.milliTimestamp();

    var stdinBW = std.io.bufferedReader(std.io.getStdIn().reader());
    const stdin = stdinBW.reader();

    var out_file = try std.fs.cwd().createFile(args.out_file_name, .{});
    const out = out_file.writer();
    defer out_file.close();

    const fbaBuffer = try std.heap.c_allocator.alloc(u8, 1_609_780_728);
    defer std.heap.c_allocator.free(fbaBuffer);
    var fba = std.heap.FixedBufferAllocator.init(fbaBuffer);
    const fbaAlloc = fba.allocator();

    // Write 15MB of 0s
    const tmp_zero_buf = try fbaAlloc.alloc(u8, 100_000);
    @memset(tmp_zero_buf, 0);
    inline for (0..150) |_| {
        try out.writeAll(tmp_zero_buf);
    }
    fbaAlloc.free(tmp_zero_buf);

    // Stats
    var total_bytes_read: usize = 0;
    var total_article_bytes_read: usize = 0;
    var total_bytes_written: usize = 0;
    const n_articles_to_process = args.n_articles_to_process;
    var n_articles_processed: usize = 0;
    var n_redirects_skipped: usize = 0;

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

    while (true) {
        var arena = std.heap.ArenaAllocator.init(fbaAlloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const xmlPage = wxmlp.nextPageAlloc(alloc, stdin) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };

        total_bytes_read += xmlPage.len;

        const wikiArticle = wxmlp.parsePage(xmlPage) orelse {
            n_redirects_skipped += 1;
            continue;
        };

        total_article_bytes_read += wikiArticle.article.len;

        const preProcessedArticle = try preprocessArticle(alloc, wikiArticle.article);
        const processedArticle = blk: {
            const PE = MWParser.ParseError;
            break :blk wikicodeToMarkdown(alloc, preProcessedArticle) catch |err| switch (err) {
                PE.BadExternalLink,
                PE.BadTemplate,
                PE.BadWikiLink,
                PE.IncompleteArgument,
                PE.IncompleteHeading,
                PE.IncompleteHtmlEntity,
                PE.IncompleteTable,
                PE.InvalidHtmlTag,
                PE.UnclosedHtmlComment,
                => {
                    std.log.warn("Article ID: {} ... {s}", .{ n_articles_processed, @errorName(err) });
                    break :blk preProcessedArticle;
                },
                else => return err,
            };
        };

        const size_to_write = processedArticle.len + wikiArticle.title.len + @sizeOf(usize) + "# ".len + "\n".len + "0".len;

        // block is full! compress contents and flush them out
        // add a block_offset to the array
        if (lzma_block_size + size_to_write >= lzma_block_size_limit) {
            const compressed_output = try lzma.compress(&alloc, lzma_block_accum_buffer[0..lzma_block_size], lzma_block_out_buffer);
            try out.writeAll(compressed_output);

            if (block_offsets.items.len == 0) {
                try block_offsets.append(15_000_000);
            } else {
                try block_offsets.append(block_offsets.items[block_offsets.items.len - 1] + lzma_last_block_size);
            }

            lzma_last_block_size = compressed_output.len;
            lzma_block_size = 0;
            total_bytes_written += compressed_output.len;
            block_id += 1;
        }

        var accum_buffer_fbs = std.io.fixedBufferStream(lzma_block_accum_buffer[lzma_block_size..]);
        const accum_buffer_writer = accum_buffer_fbs.writer();

        try accum_buffer_writer.writeInt(usize, n_articles_processed, .big);
        try accum_buffer_writer.writeAll("# ");
        try accum_buffer_writer.writeAll(wikiArticle.title);
        try accum_buffer_writer.writeByte('\n');
        try accum_buffer_writer.writeAll(processedArticle);
        try accum_buffer_writer.writeByte(0);

        lzma_block_size += size_to_write;

        // Write down what block this article is in
        try article_id_block_id_map.append(block_id);

        n_articles_processed += 1;
        if (n_articles_processed == n_articles_to_process) {
            break;
        }
    }

    if (lzma_block_size > 0) {
        const compressed_output = try lzma.compress(null, lzma_block_accum_buffer[0..lzma_block_size], lzma_block_out_buffer);
        try out.writeAll(compressed_output);
        lzma_block_size = 0;
        total_bytes_written += compressed_output.len;

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

    // Stats to stderr
    std.debug.print("Read {d} MB. Avg article len {d} KB\n", .{
        @as(f32, @floatFromInt(total_bytes_read)) / 1_000_000.0,
        @as(f32, @floatFromInt(total_article_bytes_read)) / @as(f32, @floatFromInt(n_articles_to_process)) / 1_000.0,
    });
    std.debug.print("Wrote 15 + {d} MB. Avg article len {d} KB\n", .{
        @as(f32, @floatFromInt(total_bytes_written)) / 1_000_000.0,
        @as(f32, @floatFromInt(total_bytes_written)) / @as(f32, @floatFromInt(n_articles_to_process)) / 1_000.0,
    });
    std.debug.print("Processed {} articles, skipped {} articles\n", .{ n_articles_processed, n_redirects_skipped });
    const end_time = std.time.milliTimestamp();
    const t_in_s = @divFloor((end_time - start_time), 1000);
    std.debug.print("{} min {} sec\n", .{ @divFloor(t_in_s, 60), @mod(t_in_s, 60) });
    const articles_per_s = @as(f32, @floatFromInt(n_articles_processed)) / (@as(f32, @floatFromInt(end_time - start_time)) / 1000.0);
    std.debug.print("{d} articles/s\n", .{articles_per_s});
}

/// Performs substitutions before wikitext can be parsed to an AST
///
/// Uses `SliceArray` for performance
///
/// `''''` to `***`
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
/// delete `\r`
fn preprocessArticle(a: std.mem.Allocator, article: []const u8) ![]const u8 {
    var sa = SliceArray.init(a);
    defer sa.deinit();
    try sa.append(article);

    try sa.findAndReplace("''''", "***");
    try sa.findAndReplace("'''", "**");
    try sa.findAndReplace("''", "*");
    try sa.findAndReplace("&quot;", "\"");
    try sa.findAndReplace("&lt;", "<");
    try sa.findAndReplace("&gt;", ">");
    try sa.findAndReplace("&amp;", "&");
    try sa.findAndReplace("\r", "");

    return try sa.toSlice();
}

/// Uses `MWParser` to convert Wikicode AST to more concise and clean text
fn wikicodeToMarkdown(a: std.mem.Allocator, raw_wikitext: []const u8) ![]const u8 {
    var wp = MWParser.init(a, raw_wikitext);
    try wp.parse();
    return raw_wikitext;
}

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
