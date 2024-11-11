const std = @import("std");
const ST = std.mem.sliceTo;

const Self = @This();

pub const Match = struct {
    title: []const u8,
    match_pos: usize,
    id: usize,
};

a: std.mem.Allocator,
f: std.fs.File,
matches: std.ArrayList(Match),
match_str_buf: []u8,
match_str_fba: std.heap.FixedBufferAllocator,

mtx: std.Thread.Mutex = .{},

//pub const InitError = std.fs.File.OpenError || std.fs.Dir.RealPathError || std.mem.Allocator.Error;
pub fn init(a: std.mem.Allocator, path: []const u8) !Self {
    var buf: [100]u8 = undefined;
    const real_path = try std.fs.cwd().realpath(path, &buf);
    const f = try std.fs.openFileAbsolute(real_path, .{});

    const match_str_buf = try a.alloc(u8, 256 * 50);
    const match_str_fba = std.heap.FixedBufferAllocator.init(match_str_buf);

    return .{
        .a = a,
        .f = f,
        .matches = try std.ArrayList(Match).initCapacity(a, 50),
        .match_str_buf = match_str_buf,
        .match_str_fba = match_str_fba,
    };
}

pub fn deinit(s: Self) void {
    s.f.close();
    s.matches.deinit();
    s.a.free(s.match_str_buf);
}

fn reset(s: *Self) !void {
    s.matches.clearRetainingCapacity();
    s.match_str_fba.reset();
    try s.f.seekTo(0);
}

pub fn lock(s: *Self) void {
    s.mtx.lock();
}

pub fn unlock(s: *Self) void {
    s.mtx.unlock();
}

/// Default `limit` is 50
pub fn search(s: *Self, query: []const u8, limit: ?usize) !void {
    try s.reset();
    const a = s.match_str_fba.allocator();

    if (query.len == 0)
        return;

    var f_br = std.io.bufferedReader(s.f.reader());
    const reader = f_br.reader();

    var skip_table: [256]usize = undefined;
    boyerMooreHorspoolPreprocess(query, &skip_table);

    var linebuf: [256]u8 = undefined;

    var doc_id: usize = 0;
    while (true) : (doc_id += 1) {
        const line = try reader.readUntilDelimiterOrEof(&linebuf, '\n') orelse break;
        if (indexOfWithSkipTable(line, query, &skip_table)) |pos| {
            const title = a.alloc(u8, line.len) catch unreachable;
            @memcpy(title, line);

            s.matches.append(.{ .title = title, .match_pos = pos, .id = doc_id }) catch unreachable;

            const real_limit = limit orelse 50;
            if (s.matches.items.len == real_limit)
                break;
        }
    }
}

/// from `std.mem`
fn indexOfWithSkipTable(haystack: []const u8, needle: []const u8, skip_table: *[256]usize) ?usize {
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle))
            return i;
        i += skip_table[haystack[i + needle.len - 1]];
    }

    return null;
}

/// from `std.mem`
fn boyerMooreHorspoolPreprocess(pattern: []const u8, table: *[256]usize) void {
    for (table) |*c| c.* = pattern.len;
    var i: usize = 0;
    while (i < pattern.len - 1) : (i += 1) table[pattern[i]] = pattern.len - 1 - i;
}
