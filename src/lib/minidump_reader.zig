const std = @import("std");
const lzma = @import("lzma.zig");
const toU8 = std.mem.sliceAsBytes;

pub const MinidumpReader = @This();

f: std.fs.File,
a: std.mem.Allocator,
block_offsets: []u64,
article_id_block_id_map: []u16,
out_buf: []u8,

pub const MinidumpError = error{
    InvalidMagic,
    InvalidVersion,
    CorruptMinidump,
};

const MinidumpInitError = MinidumpError || std.fs.Dir.RealPathAllocError || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.SeekError || error{EndOfStream};
pub fn init(a: std.mem.Allocator, path: []const u8) MinidumpInitError!MinidumpReader {
    const real_path = try std.fs.cwd().realpathAlloc(a, path);

    const f = try std.fs.openFileAbsolute(real_path, .{});

    // Check magic.
    var magic: [8]u8 = undefined;
    std.debug.assert(try f.readAll(&magic) == magic.len);
    if (!std.mem.eql(u8, &magic, "MINIDUMP")) {
        std.log.err("Invalid magic: Found '{s}' expected 'MINIDUMP'\n", .{&magic});
        return MinidumpError.InvalidMagic;
    }

    // Check dump version.
    const int_reader = f.reader();
    const version = try int_reader.readInt(u64, .big);
    if (version != 0) {
        std.log.err("Invalid version: Found {} expected 0\n", .{version});
        return MinidumpInitError.InvalidVersion;
    }

    // Extract offset arrays.
    const header_start = try int_reader.readInt(u64, .big);

    try f.seekTo(header_start);
    const header_reader = f.reader();

    const block_offset_array_size = try header_reader.readInt(u64, .big);
    const block_id_map_size = try header_reader.readInt(u64, .big);

    const block_offsets = try a.alloc(u64, block_offset_array_size / 8);
    const article_id_block_id_map = try a.alloc(u16, block_id_map_size / 2);

    std.debug.assert(try f.readAll(toU8(block_offsets)) == toU8(block_offsets).len);
    std.debug.assert(try f.readAll(toU8(article_id_block_id_map)) == toU8(article_id_block_id_map).len);

    return .{
        .a = a,
        .f = f,
        .block_offsets = block_offsets,
        .article_id_block_id_map = article_id_block_id_map,
        .out_buf = try a.alloc(u8, 1_000_000),
    };
}

pub fn deinit(self: MinidumpReader) void {
    self.f.close();
    self.a.free(self.block_offsets);
    self.a.free(self.article_id_block_id_map);
    self.a.free(self.out_buf);
}

const MarkdownFromMinidumpError = MinidumpError || lzma.LzmaError || std.fs.File.ReadError || std.fs.File.SeekError || error{EndOfStream};
pub fn markdown(self: MinidumpReader, article_id: u64) MarkdownFromMinidumpError!?[]const u8 {
    if (article_id >= self.article_id_block_id_map.len)
        return null;

    const target_block_id = self.article_id_block_id_map[article_id];
    const block_offset = self.block_offsets[target_block_id];
    try self.f.seekTo(block_offset);

    const block = try lzma.decompress(null, self.f.reader(), self.out_buf);

    if (std.mem.readInt(u64, block[0..8], .big) == article_id) {
        // First article.
        const end = std.mem.indexOfScalar(u8, block[8..], 0) orelse return MinidumpError.CorruptMinidump;
        return block[8..end];
    }

    // Middle or ending article.
    // Look for "\0<articleid>".
    var article_start_marker: [9]u8 = undefined;
    article_start_marker[0] = 0;
    std.mem.writeInt(u64, (&article_start_marker)[1..], article_id, .big);

    const article_start = blk: {
        const start = std.mem.indexOf(u8, block, &article_start_marker) orelse return MinidumpError.CorruptMinidump;
        break :blk start + article_start_marker.len;
    };
    const article_end = blk: {
        const end = std.mem.indexOfScalar(u8, block[article_start + 9 ..], 0) orelse return MinidumpError.CorruptMinidump;
        break :blk end + article_start + 9;
    };

    return block[article_start..article_end];
}

pub fn articleCount(self: MinidumpReader) usize {
    return self.article_id_block_id_map.len;
}
