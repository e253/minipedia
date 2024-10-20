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
    const end_time = std.time.milliTimestamp();
    const t_in_s = @divFloor((end_time - start_time), 1000);
    std.debug.print("{} min {} sec\n", .{ @divFloor(t_in_s, 60), @mod(t_in_s, 60) });
    const articles_per_s = @as(f32, @floatFromInt(n_articles_processed)) / (@as(f32, @floatFromInt(end_time - start_time)) / 1000.0);
    std.debug.print("{d} articles/s\n", .{articles_per_s});
}

// dump
// pub const SliceArray = struct {
//     slices: std.ArrayList([]const u8),
//     len: usize,
//     a: std.mem.Allocator,
//
//     pub fn init(a: std.mem.Allocator) SliceArray {
//         return .{
//             .slices = std.ArrayList([]const u8).init(a),
//             .len = 0,
//             .a = a,
//         };
//     }
//
//     pub fn deinit(self: *SliceArray) void {
//         self.slices.deinit();
//     }
//
//     /// Only works in debug
//     pub fn printSlices(self: *const SliceArray) void {
//         for (self.slices.items, 0..) |slice, i| {
//             std.debug.print("Slice: {} \"{s}\"\n", .{ i, slice });
//         }
//     }
//
//     /// Copies slices to single contigous buffer
//     /// You must still deinit() the SliceArray afterwards
//     pub fn toSlice(self: *SliceArray) ![]const u8 {
//         const ownedSlice = try self.a.alloc(u8, self.len);
//
//         var cumulativeSize: usize = 0;
//         for (self.slices.items) |slice| {
//             @memcpy(ownedSlice[cumulativeSize .. cumulativeSize + slice.len], slice);
//             cumulativeSize += slice.len;
//         }
//
//         return ownedSlice;
//     }
//
//     /// Print slices to array
//     pub fn print(self: *SliceArray, w: anytype) !void {
//         for (self.slices.items) |slice| {
//             try w.writeAll(slice);
//         }
//     }
//
//     pub fn append(self: *SliceArray, text: []const u8) !void {
//         try self.slices.append(text);
//         self.len += text.len;
//     }
//
//     /// Remove section without copying
//     /// Start and End must point within an individual slice
//     pub fn remove(self: *SliceArray, start: u32, end: u32) !void {
//         if (end >= self.len) {
//             @panic("Out of bounds access to SliceArray");
//         }
//         if (start >= self.len or start >= end) {
//             @panic("Start is larger than SliceArray size or larger than start index");
//         }
//
//         const target_slice_i = blk: {
//             var cumulativeSize: usize = 0;
//             for (self.slices.items, 0..) |slice, i| {
//                 if (cumulativeSize < start and start < (cumulativeSize + slice.len)) {
//                     break :blk i;
//                 }
//                 cumulativeSize += slice.len;
//             }
//             unreachable;
//         };
//
//         const target_slice = self.slices.items[target_slice_i];
//
//         self.slices.items[target_slice_i] = target_slice[0..start];
//         try self.slices.insert(target_slice_i + 1, target_slice[end..]);
//
//         self.len -= end - start;
//     }
//
//     const RemoveSectionError = error{
//         UnclosedSection,
//         OutOfMemory, // Allocator Error
//     };
//
//     /// Removes all instances [open_token]..[close_token] within the `SliceArray` and handles nesting.
//     ///
//     /// If `fail_on_unclosed` is set to true, then an error is returned for an unclosed section, otherwise the section is ignored.
//     pub fn removeSections(self: *SliceArray, open_token: []const u8, close_token: []const u8) RemoveSectionError!void {
//         if (self.slices.items.len == 0) {
//             return;
//         }
//
//         var slice_idx: u32 = 0;
//         while (slice_idx < self.slices.items.len) : (slice_idx += 1) {
//             const slice = self.slices.items[slice_idx];
//
//             const open_token_start = std.mem.indexOf(u8, slice, open_token) orelse continue;
//             const close_token_end = blk: {
//                 var forwardSearchPos = open_token_start + open_token.len;
//                 var backwardSearchPos: ?usize = null;
//                 while (true) {
//                     const end = (std.mem.indexOfPos(u8, slice, forwardSearchPos, close_token) orelse return RemoveSectionError.UnclosedSection) + close_token.len;
//
//                     const nestedStart = std.mem.lastIndexOf(u8, slice[0 .. backwardSearchPos orelse (end - close_token.len)], open_token) orelse unreachable; // It will find the first token if no others exist
//                     if (nestedStart == open_token_start) {
//                         break :blk end;
//                     } else {
//                         forwardSearchPos = end;
//                         backwardSearchPos = nestedStart;
//                     }
//                 }
//             };
//
//             if (open_token_start == 0 and close_token_end == slice.len) { // Section spans entire slice!
//                 self.slices.items[slice_idx] = "";
//                 self.len -= slice.len;
//             } else if (open_token_start == 0 and close_token_end < slice.len) { // Section starts slice, but doesn't end it
//                 self.slices.items[slice_idx] = slice[close_token_end..];
//                 self.len -= close_token_end;
//             } else if (open_token_start > 0 and close_token_end == slice.len) { // Section ends slice, but doesn't start it
//                 self.slices.items[slice_idx] = slice[0..open_token_start];
//                 self.len -= slice.len - open_token_start;
//             } else { // Section neither begins nor ends the slice
//                 self.slices.items[slice_idx] = slice[0..open_token_start];
//                 try self.slices.insert(slice_idx + 1, slice[close_token_end..]);
//                 self.len -= close_token_end - open_token_start;
//             }
//         }
//     }
// };
//
// test "Append" {
//     const test_alloc = std.testing.allocator;
//
//     var sa = SliceArray.init(test_alloc);
//     defer sa.deinit();
//
//     try sa.append("Hello, ");
//     try sa.append("World!");
//
//     const renderedString = try sa.toSlice();
//     defer test_alloc.free(renderedString);
//
//     try std.testing.expectEqualStrings("Hello, World!", renderedString);
//
//     try sa.append("\n");
//
//     const renderedString2 = try sa.toSlice();
//     defer test_alloc.free(renderedString2);
//
//     try std.testing.expectEqualStrings("Hello, World!\n", renderedString2);
// }
//
// test "Remove" {
//     const test_alloc = std.testing.allocator;
//
//     var sa = SliceArray.init(test_alloc);
//     defer sa.deinit();
//
//     try sa.append("Hello, World!");
//
//     try sa.remove(5, 7);
//
//     const renderedString = try sa.toSlice();
//     defer test_alloc.free(renderedString);
//
//     try std.testing.expectEqualStrings("HelloWorld!", renderedString);
// }
//
// test "Remove HTML Comment" {
//     const test_alloc = std.testing.allocator;
//
//     var sa = SliceArray.init(test_alloc);
//     defer sa.deinit();
//
//     try sa.append("<!-- No Comment! -->");
//     try sa.removeSections("<!--", "-->");
//
//     const renderedString = try sa.toSlice();
//     defer test_alloc.free(renderedString);
//
//     try std.testing.expectEqualStrings("", renderedString);
// }
//
// test "Remove Ending HTML Comment" {
//     const test_alloc = std.testing.allocator;
//
//     var sa = SliceArray.init(test_alloc);
//     defer sa.deinit();
//
//     try sa.append(
//         \\Some Content Before
//         \\<!-- No Comment! -->
//     );
//     try sa.removeSections("<!--", "-->");
//
//     const renderedString = try sa.toSlice();
//     defer test_alloc.free(renderedString);
//
//     try std.testing.expectEqualStrings(
//         \\Some Content Before
//         \\
//     ,
//         renderedString,
//     );
// }
//
// test "Remove Starting HTML Comment" {
//     const test_alloc = std.testing.allocator;
//
//     var sa = SliceArray.init(test_alloc);
//     defer sa.deinit();
//
//     try sa.append(
//         \\<!-- No Comment! -->
//         \\Some Content After
//         \\
//     );
//     try sa.removeSections("<!--", "-->");
//
//     const renderedString = try sa.toSlice();
//     defer test_alloc.free(renderedString);
//
//     try std.testing.expectEqualStrings(
//         \\
//         \\Some Content After
//         \\
//     ,
//         renderedString,
//     );
// }
//
// test "Remove Surounded HTML Comment" {
//     const test_alloc = std.testing.allocator;
//
//     var sa = SliceArray.init(test_alloc);
//     defer sa.deinit();
//
//     try sa.append(
//         \\Some Content Before
//         \\<!-- No Comment! -->
//         \\Some Content After
//     );
//     try sa.removeSections("<!--", "-->");
//
//     const renderedString = try sa.toSlice();
//     defer test_alloc.free(renderedString);
//
//     try std.testing.expectEqualStrings(
//         \\Some Content Before
//         \\
//         \\Some Content After
//     ,
//         renderedString,
//     );
// }
//
// test "Remove wikicode tag" {
//     var sa = SliceArray.init(std.testing.allocator);
//     defer sa.deinit();
//
//     try sa.append(
//         \\Some Content Before
//         \\{{Cite [some bloated wikicode tag]}}
//         \\Some Content After
//     );
//
//     try sa.removeSections("{{", "}}");
//
//     const renderedString = try sa.toSlice();
//     defer std.testing.allocator.free(renderedString);
//
//     try std.testing.expectEqualStrings(
//         \\Some Content Before
//         \\
//         \\Some Content After
//     ,
//         renderedString,
//     );
// }
//
// test "Remove Sections errors on unclosed" {
//     var sa = SliceArray.init(std.testing.allocator);
//     defer sa.deinit();
//
//     try sa.append(
//         \\Some Content Before
//         \\{{Cite [some bloated wik
//         \\Some Content After
//     );
//
//     const ret = sa.removeSections("{{", "}}");
//     try std.testing.expectError(SliceArray.RemoveSectionError.UnclosedSection, ret);
//
//     const renderedString = try sa.toSlice();
//     defer std.testing.allocator.free(renderedString);
//
//     try std.testing.expectEqualStrings(
//         \\Some Content Before
//         \\{{Cite [some bloated wik
//         \\Some Content After
//     ,
//         renderedString,
//     );
// }
//
// test "Removes Trivial Nested Sections" {
//     var sa = SliceArray.init(std.testing.allocator);
//     defer sa.deinit();
//
//     try sa.append(
//         \\Before Content
//         \\{{Cite [some content] {{Cite [some nested content]}} }}
//         \\After Content
//     );
//
//     try sa.removeSections("{{", "}}");
//
//     const renderedString = try sa.toSlice();
//     defer std.testing.allocator.free(renderedString);
//
//     try std.testing.expectEqualStrings(
//         \\Before Content
//         \\
//         \\After Content
//     ,
//         renderedString,
//     );
// }
//
