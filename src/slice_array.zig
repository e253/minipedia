const std = @import("std");

pub const SliceArrayIterator = struct {
    sa: SliceArray,
    /// index of this slice within `sa`
    n_slice: usize = 0,
    /// index within `cur_slice`
    slice_pos: usize = 0,
    /// global index across all array elements
    global_pos: usize = 0,
    cur_slice: []const u8,

    const Self = @This();

    /// TODO: maybe inline?
    pub fn next(self: *Self) ?u8 {
        if (self.slice_pos < self.cur_slice.len) {
            defer self.slice_pos += 1;
            return self.cur_slice[self.slice_pos];
        } else {
            // no more slices
            if (self.n_slice + 1 == self.sa.slices.items.len) {
                return null;
            }
            self.n_slice += 1;
            self.cur_slice = self.sa.slices[self.n_slice];
            self.slice_pos = 0;
            return self.cur_slice[self.slice_pos];
        }
    }

    // pub fn rewind(self: *Self, n: usize) void {
    //     std.debug.assert(n < self.sa.len);

    //     if (self.slice_pos - n >= 0) {
    //         self.slice_pos -= n;
    //         return;
    //     }
    //     while (true) {
    //         n -= self.cur_slice.len; // will be at least 1
    //         self.n_slice
    //         self.cur_slice = self.sa.slices[]
    //     }
    // }
};

pub const SliceArray = struct {
    slices: std.ArrayList([]const u8),
    len: usize,
    a: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) SliceArray {
        return .{
            .slices = std.ArrayList([]const u8).init(a),
            .len = 0,
            .a = a,
        };
    }

    pub fn deinit(self: *SliceArray) void {
        self.slices.deinit();
    }

    /// Only works in debug
    pub fn printSlices(self: *const SliceArray) void {
        for (self.slices.items, 0..) |slice, i| {
            std.debug.print("Slice: {} \"{s}\"\n", .{ i, slice });
        }
    }

    /// Copies slices to single contigous buffer
    /// You must still deinit() the SliceArray afterwards
    pub fn toSlice(self: *SliceArray) ![]const u8 {
        const ownedSlice = try self.a.alloc(u8, self.len);

        var cumulativeSize: usize = 0;
        for (self.slices.items) |slice| {
            @memcpy(ownedSlice[cumulativeSize .. cumulativeSize + slice.len], slice);
            cumulativeSize += slice.len;
        }

        return ownedSlice;
    }

    /// Copies slices to externally allocated buffer `out`
    pub fn writeToSlice(self: *SliceArray, out: []u8) !void {
        var i: usize = 0;
        for (self.slices.items) |slice| {
            @memcpy(out[i .. i + slice.len], slice);
            i += slice.len;
        }
    }

    /// Print slices to array
    pub fn print(self: *SliceArray, w: anytype) !void {
        for (self.slices.items) |slice| {
            try w.writeAll(slice);
        }
    }

    pub fn append(self: *SliceArray, text: []const u8) !void {
        try self.slices.append(text);
        self.len += text.len;
    }

    const RemoveSectionError = error{
        UnclosedSection,
        OutOfMemory, // Allocator Error
    };

    pub fn findAndReplace(self: *SliceArray, comptime old: []const u8, comptime new: []const u8) !void {
        comptime {
            if (old.len == 0) {
                @compileError("`old` value must have length greater than 0");
            }
        }

        var slice_idx: usize = 0;
        while (slice_idx < self.slices.items.len) {
            const slice = self.slices.items[slice_idx];

            const old_start = std.mem.indexOf(u8, slice, old) orelse {
                slice_idx += 1;
                continue;
            };
            const old_end = old_start + old.len;

            if (old_start == 0 and old_end == slice.len) { // old takes up entire slice
                self.slices.items[slice_idx] = new;
                slice_idx += 1;
            } else if (old_start == 0 and old_end < slice.len) { // old starts slice, but doesn't end it
                self.slices.items[slice_idx] = new;
                try self.slices.insert(slice_idx + 1, slice[old_end..]);
                slice_idx += 1;
            } else if (old_start > 0 and old_end == slice.len) { // old ends slice, but doesn't start it
                self.slices.items[slice_idx] = slice[0..old_start];
                try self.slices.insert(slice_idx + 1, new);
                slice_idx += 2;
            } else {
                self.slices.items[slice_idx] = slice[0..old_start];
                try self.slices.insert(slice_idx + 1, new);
                try self.slices.insert(slice_idx + 2, slice[old_end..]);
            }
            self.len -= old.len;
            self.len += new.len;
        }
    }
};

test "Append" {
    const test_alloc = std.testing.allocator;

    var sa = SliceArray.init(test_alloc);
    defer sa.deinit();

    try sa.append("Hello, ");
    try sa.append("World!");

    const renderedString = try sa.toSlice();
    defer test_alloc.free(renderedString);

    try std.testing.expectEqualStrings("Hello, World!", renderedString);

    try sa.append("\n");

    const renderedString2 = try sa.toSlice();
    defer test_alloc.free(renderedString2);

    try std.testing.expectEqualStrings("Hello, World!\n", renderedString2);
}

test "findAndReplace" {
    var sa = SliceArray.init(std.testing.allocator);
    defer sa.deinit();

    try sa.append("'''Hello''', World!");

    try sa.findAndReplace("'''", "**");

    const renderedString = try sa.toSlice();
    defer std.testing.allocator.free(renderedString);

    try std.testing.expectEqualStrings("**Hello**, World!", renderedString);
}
