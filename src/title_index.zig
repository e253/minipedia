const std = @import("std");
const sz = @import("stringzilla.zig");
const ST = std.mem.sliceTo;

const Self = @This();

pub const Match = struct {
    title: []const u8,
    match_pos: usize,
    id: usize,
};

map: []const u8,

pub fn init(path: []const u8) !Self {
    var buf: [100]u8 = undefined;
    const real_path = try std.fs.cwd().realpath(path, &buf);
    const f = try std.fs.openFileAbsolute(real_path, .{});
    defer f.close();
    try f.seekFromEnd(0);
    const f_size = try f.getPos();
    try f.seekTo(0);

    const map = try std.posix.mmap(null, f_size, std.c.PROT.READ, .{ .TYPE = .PRIVATE }, f.handle, 0);

    return .{ .map = map };
}

pub fn deinit(s: Self) void {
    std.posix.munmap(@alignCast(s.map));
}

/// `matches` must have enough memory for `limit` elements.
///
/// assert `matches.len` >= limit.
/// and `match_str_buf.len` >= 256 * limit
pub fn search(s: *Self, query: []const u8, limit: usize, matches: *[]Match, match_str_buf: []u8) !void {
    if (query.len == 0) {
        matches.len = 0;
        return;
    }
    if (std.mem.indexOfScalar(u8, query, 0) != null)
        return error.NullByteInQuery;
    std.debug.assert(matches.len >= limit);
    std.debug.assert(match_str_buf.len >= 256 * limit);

    var fba = std.heap.FixedBufferAllocator.init(match_str_buf);
    const a = fba.allocator();

    var matches_found: usize = 0;
    var last_match_pos: usize = 0;
    while (matches_found < limit) {
        if (sz.indexOfCaseInsensitivePos(s.map, query, last_match_pos)) |pos| {
            const title_start = (std.mem.lastIndexOfScalar(u8, s.map[0..pos], 0) orelse @panic("Title not preceeded by \\0")) + 1;
            const title_end = std.mem.indexOfScalarPos(u8, s.map, pos, 0) orelse @panic("Title not null terminated");

            const _title = s.map[title_start..title_end];
            const title = a.alloc(u8, _title.len) catch unreachable;
            @memcpy(title, _title);

            var id_bytes: [3]u8 = undefined;
            @memcpy(&id_bytes, s.map[title_end + 1 .. title_end + 4]);
            const id: u24 = std.mem.readInt(u24, &id_bytes, .big);

            matches.*[matches_found] = .{ .title = title, .match_pos = pos - title_start, .id = id };

            matches_found += 1;
            last_match_pos = title_end + 5;
        } else {
            break;
        }
    }
    matches.len = matches_found;
}

pub fn idFromTitle(s: *Self, title: []const u8) usize {
    _ = title;
    _ = s;
    return 0;
}
