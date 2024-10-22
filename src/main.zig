const std = @import("std");
const wxmlp = @import("wikixmlparser.zig");
const SliceArray = @import("slice_array.zig").SliceArray;

pub fn main() !void {
    const start_time = std.time.milliTimestamp();

    var stdinBW = std.io.bufferedReader(std.io.getStdIn().reader());
    const stdin = stdinBW.reader();
    var stdoutBW = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout = stdoutBW.writer();

    const fbaBuffer = try std.heap.c_allocator.alloc(u8, 25_153_824);
    defer std.heap.page_allocator.free(fbaBuffer);
    var fba = std.heap.FixedBufferAllocator.init(fbaBuffer);
    const fbaAlloc = fba.allocator();

    // stats
    var total_bytes_read: usize = 0;
    var total_article_bytes_read: usize = 0;
    var total_bytes_written: usize = 0;
    const n_articles_to_process: usize = blk: {
        if (std.os.argv.len == 1) {
            std.debug.print("{s}\n", .{"processing articles until EOF"});
            break :blk std.math.maxInt(usize);
        } else {
            break :blk std.fmt.parseInt(usize, std.mem.sliceTo(std.os.argv[1], 0), 10) catch |err| {
                std.debug.print("{s}\n", .{"argv[1] must be an integer representing the number of articles to process"});
                return err;
            };
        }
    };
    var n_articles_processed: usize = 0;
    var n_redirects_skipped: usize = 0;
    var n_low_value_articles_skipped: usize = 0;

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

        const title = wikiArticle.title;
        if (std.mem.indexOfPosLinear(u8, title, 0, "isambiguation") != null) {
            n_low_value_articles_skipped += 1;
            continue;
        }

        const article = wikiArticle.article;
        total_article_bytes_read += article.len;

        const ref_section_start = blk: {
            const ref_start_opt = std.mem.indexOf(u8, article, "== References ==");
            if (ref_start_opt) |ref_start| {
                break :blk ref_start;
            }
            const ref_start_opt2 = std.mem.indexOf(u8, article, "==References==");
            if (ref_start_opt2) |ref_start| {
                break :blk ref_start;
            }

            break :blk article.len;
        };

        var processedArticle = SliceArray.init(alloc);
        try processedArticle.append(article[0..ref_section_start]);

        processedArticle.removeSections("{|", "|}") catch |err| switch (err) {
            error.UnclosedSection => {}, // TODO: log
            error.OutOfMemory => return err,
        };
        processedArticle.removeSections("&lt;!--", "--&gt;") catch |err| switch (err) {
            error.UnclosedSection => {}, // TODO: log
            error.OutOfMemory => return err,
        };
        processedArticle.removeSections("&lt;!--", "--") catch |err| switch (err) {
            error.UnclosedSection => {}, // TODO: log
            error.OutOfMemory => return err,
        };
        processedArticle.removeSections("{{", "}}") catch |err| switch (err) {
            error.UnclosedSection => {}, // TODO: log
            error.OutOfMemory => return err,
        };
        processedArticle.removeSections("&lt;ref&gt;", "&lt;/ref&gt;") catch |err| switch (err) {
            error.UnclosedSection => {}, // TODO: log
            error.OutOfMemory => return err,
        };
        try processedArticle.findAndReplace("''''", "***");
        try processedArticle.findAndReplace("'''", "**");
        try processedArticle.findAndReplace("''", "*");
        try processedArticle.findAndReplace("&quot;", "\"");

        total_bytes_written += processedArticle.len;

        // TODO: Gather blocks and compress with lzma
        try stdout.writeAll(title);
        try stdout.writeAll(&.{1});
        try processedArticle.print(stdout);
        try stdout.writeAll(&.{2});

        n_articles_processed += 1;
        if (n_articles_processed == n_articles_to_process) {
            break;
        }
    }

    // Stats to stderr
    std.debug.print("Read {d} MB. Avg article len {d} KB\n", .{
        @as(f32, @floatFromInt(total_bytes_read)) / 1_000_000.0,
        @as(f32, @floatFromInt(total_article_bytes_read)) / @as(f32, @floatFromInt(n_articles_to_process)) / 1_000.0,
    });
    std.debug.print("Wrote {d} MB. Avg article len {d} KB\n", .{
        @as(f32, @floatFromInt(total_bytes_written)) / 1_000_000.0,
        @as(f32, @floatFromInt(total_bytes_written)) / @as(f32, @floatFromInt(n_articles_to_process)) / 1_000.0,
    });
    std.debug.print("Processed {} articles, skipped {} articles\n", .{ n_articles_processed, n_redirects_skipped });
    std.debug.print("Skipped {} low value articles\n", .{n_low_value_articles_skipped});
    const end_time = std.time.milliTimestamp();
    const t_in_s = @divFloor((end_time - start_time), 1000);
    std.debug.print("{} min {} sec\n", .{ @divFloor(t_in_s, 60), @mod(t_in_s, 60) });
    const articles_per_s = @as(f32, @floatFromInt(n_articles_processed)) / (@as(f32, @floatFromInt(end_time - start_time)) / 1000.0);
    std.debug.print("{d} articles/s\n", .{articles_per_s});
}
