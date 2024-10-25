const std = @import("std");
const toU8 = std.mem.sliceAsBytes;
const assert = std.debug.assert;
const print = std.debug.print;
const a = std.heap.c_allocator;
const lzma = @import("lzma.zig");

const GetArticleError = error{
    InvalidMagic,
    InvalidVersion,
};

pub fn main() !void {
    const args = try Args.parse();

    const f = try std.fs.cwd().openFile(args.minidump_rel_path, .{});
    defer f.close();

    // Parse Prelude
    var magic: [8]u8 = undefined;
    assert(try f.readAll(&magic) == magic.len);

    if (!std.mem.eql(u8, &magic, "MINIDUMP")) {
        print("Invalid magic: Found '{s}' expected 'MINIDUMP'\n", .{&magic});
        return GetArticleError.InvalidMagic;
    }

    const int_reader = f.reader();
    const version = try int_reader.readInt(u64, .big);
    if (version != 0) {
        print("Invalid version: Found {} expected 0\n", .{version});
        return GetArticleError.InvalidVersion;
    }

    const header_start = try int_reader.readInt(u64, .big);

    // Parse Header
    try f.seekTo(header_start);
    const header_reader = f.reader();

    const block_offset_array_size = try header_reader.readInt(u64, .big);
    const block_id_map_size = try header_reader.readInt(u64, .big);

    const block_offsets = try a.alloc(u64, block_offset_array_size / 8);
    defer a.free(block_offsets);
    const article_id_block_id_map = try a.alloc(u16, block_id_map_size / 2);
    defer a.free(article_id_block_id_map);

    assert(try f.readAll(toU8(block_offsets)) == toU8(block_offsets).len);
    assert(try f.readAll(toU8(article_id_block_id_map)) == toU8(article_id_block_id_map).len);

    const target_block_id = article_id_block_id_map[args.article_id];
    std.debug.print("blk id: {}\n", .{target_block_id});
    const block_start = block_offsets[target_block_id];
    std.debug.print("blk start: {}\n", .{block_start});

    try f.seekTo(block_start);

    const outbuf = try a.alloc(u8, 1_000_000);
    defer a.free(outbuf);
    const decomped_block = try lzma.decompress(null, f.reader(), outbuf);

    // Maybe it's the first article?
    if (std.mem.readInt(u64, decomped_block[0..8], .big) == args.article_id) {
        const next_null_byte = std.mem.indexOfPos(u8, decomped_block, 8, &.{0}) orelse @panic("Corrupt Minidump! A null byte was not found after an article.");
        const article = decomped_block[0..next_null_byte];
        try std.io.getStdOut().writeAll(article);
        return;
    }

    // otherwise, look for "\0<articleid>"
    var article_start_marker: [9]u8 = undefined; // 8 bytes for the id, one for the nullbyte
    article_start_marker[0] = 0;
    std.mem.writeInt(u64, (&article_start_marker)[1..], args.article_id, .big);
    // TODO: optimize scans with optimistic start positions and fallback backtracking
    const article_start = std.mem.indexOf(u8, decomped_block, &article_start_marker) orelse @panic("Corrupt Minidump! Article not present in a LZMA block where it should be have present!");
    const article_end = std.mem.indexOfPos(u8, decomped_block, article_start + article_start_marker.len, &.{0}) orelse @panic("Corrupt Minidump! A null byte was not found after an article.");

    try std.io.getStdOut().writeAll(decomped_block[article_start..article_end]);
}

pub const Args = struct {
    article_id: u64,
    minidump_rel_path: []const u8,

    const ParseError = error{ TooManyArgs, NotEnoughArgs };

    pub fn parse() !Args {
        const sT = std.mem.sliceTo;

        const help =
            \\
            \\Usage:
            \\  {s} [minidump relative path (str)] [article_id (int)]
            \\
            \\Example:
            \\  {s} ./out.minidump 0
            \\
            \\
        ;

        const argv0 = sT(std.os.argv[0], 0);

        if (std.os.argv.len < 3) {
            std.debug.print(help, .{ argv0, argv0 });
            return ParseError.NotEnoughArgs;
        }

        if (std.os.argv.len == 3) {
            return .{
                .minidump_rel_path = sT(std.os.argv[1], 0),
                .article_id = try std.fmt.parseInt(u64, sT(std.os.argv[2], 0), 10),
            };
        }

        std.debug.print(help, .{ argv0, argv0 });
        return ParseError.TooManyArgs;
    }
};
