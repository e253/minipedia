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

    /// Remove section without copying
    /// Start and End must point within an individual slice
    pub fn remove(self: *SliceArray, start: u32, end: u32) !void {
        if (end >= self.len) {
            @panic("Out of bounds access to SliceArray");
        }
        if (start >= self.len or start >= end) {
            @panic("Start is larger than SliceArray size or larger than start index");
        }

        const target_slice_i = blk: {
            var cumulativeSize: usize = 0;
            for (self.slices.items, 0..) |slice, i| {
                if (cumulativeSize < start and start < (cumulativeSize + slice.len)) {
                    break :blk i;
                }
                cumulativeSize += slice.len;
            }
            unreachable;
        };

        const target_slice = self.slices.items[target_slice_i];

        self.slices.items[target_slice_i] = target_slice[0..start];
        try self.slices.insert(target_slice_i + 1, target_slice[end..]);

        self.len -= end - start;
    }

    const RemoveSectionError = error{
        UnclosedSection,
        OutOfMemory, // Allocator Error
    };

    /// Removes all instances [open_token]..[close_token] within the `SliceArray` and handles nesting.
    ///
    /// If `fail_on_unclosed` is set to true, then an error is returned for an unclosed section, otherwise the section is ignored.
    pub fn removeSections(self: *SliceArray, open_token: []const u8, close_token: []const u8) RemoveSectionError!void {
        if (self.slices.items.len == 0) {
            return;
        }

        var slice_idx: u32 = 0;
        while (slice_idx < self.slices.items.len) {
            const slice = self.slices.items[slice_idx];

            const open_token_start = std.mem.indexOf(u8, slice, open_token) orelse {
                slice_idx += 1;
                continue;
            };
            const close_token_end = blk: {
                var forwardSearchPos = open_token_start + open_token.len;
                var backwardSearchPos: ?usize = null;
                while (true) {
                    const end = (std.mem.indexOfPos(u8, slice, forwardSearchPos, close_token) orelse return RemoveSectionError.UnclosedSection) + close_token.len;

                    const nestedStart = std.mem.lastIndexOf(u8, slice[0 .. backwardSearchPos orelse (end - close_token.len)], open_token) orelse unreachable; // It will find the first token if no others exist
                    if (nestedStart == open_token_start) {
                        break :blk end;
                    } else {
                        forwardSearchPos = end;
                        backwardSearchPos = nestedStart;
                    }
                }
            };

            if (open_token_start == 0 and close_token_end == slice.len) { // Section spans entire slice!
                self.slices.items[slice_idx] = "";
                self.len -= slice.len;
                slice_idx += 1;
            } else if (open_token_start == 0 and close_token_end < slice.len) { // Section starts slice, but doesn't end it
                self.slices.items[slice_idx] = slice[close_token_end..];
                self.len -= close_token_end;
            } else if (open_token_start > 0 and close_token_end == slice.len) { // Section ends slice, but doesn't start it
                self.slices.items[slice_idx] = slice[0..open_token_start];
                self.len -= slice.len - open_token_start;
                slice_idx += 1;
            } else { // Section neither begins nor ends the slice
                self.slices.items[slice_idx] = slice[0..open_token_start];
                try self.slices.insert(slice_idx + 1, slice[close_token_end..]);
                self.len -= close_token_end - open_token_start;
            }
        }
    }

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

test "Remove" {
    const test_alloc = std.testing.allocator;

    var sa = SliceArray.init(test_alloc);
    defer sa.deinit();

    try sa.append("Hello, World!");

    try sa.remove(5, 7);

    const renderedString = try sa.toSlice();
    defer test_alloc.free(renderedString);

    try std.testing.expectEqualStrings("HelloWorld!", renderedString);
}

test "Remove HTML Comment" {
    const test_alloc = std.testing.allocator;

    var sa = SliceArray.init(test_alloc);
    defer sa.deinit();

    try sa.append("<!-- No Comment! -->");
    try sa.removeSections("<!--", "-->");

    const renderedString = try sa.toSlice();
    defer test_alloc.free(renderedString);

    try std.testing.expectEqualStrings("", renderedString);
}

test "Remove Ending HTML Comment" {
    const test_alloc = std.testing.allocator;

    var sa = SliceArray.init(test_alloc);
    defer sa.deinit();

    try sa.append(
        \\Some Content Before
        \\<!-- No Comment! -->
    );
    try sa.removeSections("<!--", "-->");

    const renderedString = try sa.toSlice();
    defer test_alloc.free(renderedString);

    try std.testing.expectEqualStrings(
        \\Some Content Before
        \\
    ,
        renderedString,
    );
}

test "Remove Starting HTML Comment" {
    const test_alloc = std.testing.allocator;

    var sa = SliceArray.init(test_alloc);
    defer sa.deinit();

    try sa.append(
        \\<!-- No Comment! -->
        \\Some Content After
        \\
    );
    try sa.removeSections("<!--", "-->");

    const renderedString = try sa.toSlice();
    defer test_alloc.free(renderedString);

    try std.testing.expectEqualStrings(
        \\
        \\Some Content After
        \\
    ,
        renderedString,
    );
}

test "Remove Surounded HTML Comment" {
    const test_alloc = std.testing.allocator;

    var sa = SliceArray.init(test_alloc);
    defer sa.deinit();

    try sa.append(
        \\Some Content Before
        \\<!-- No Comment! -->
        \\Some Content After
    );
    try sa.removeSections("<!--", "-->");

    const renderedString = try sa.toSlice();
    defer test_alloc.free(renderedString);

    try std.testing.expectEqualStrings(
        \\Some Content Before
        \\
        \\Some Content After
    ,
        renderedString,
    );
}

test "Remove wikicode tag" {
    var sa = SliceArray.init(std.testing.allocator);
    defer sa.deinit();

    try sa.append(
        \\Some Content Before
        \\{{Other uses|Anarchy|Anarchism (disambiguation)|Anarchist (disambiguation)}}
        \\Some Content After
    );

    try sa.removeSections("{{", "}}");

    var al = std.ArrayList(u8).init(std.testing.allocator);

    try sa.print(al.writer());

    const renderedString = try al.toOwnedSlice();
    defer std.testing.allocator.free(renderedString);

    try std.testing.expectEqualStrings(
        \\Some Content Before
        \\
        \\Some Content After
    ,
        renderedString,
    );
}

test "Remove Sections errors on unclosed" {
    var sa = SliceArray.init(std.testing.allocator);
    defer sa.deinit();

    try sa.append(
        \\Some Content Before
        \\{{Cite [some bloated wik
        \\Some Content After
    );

    const ret = sa.removeSections("{{", "}}");
    try std.testing.expectError(SliceArray.RemoveSectionError.UnclosedSection, ret);

    const renderedString = try sa.toSlice();
    defer std.testing.allocator.free(renderedString);

    try std.testing.expectEqualStrings(
        \\Some Content Before
        \\{{Cite [some bloated wik
        \\Some Content After
    ,
        renderedString,
    );
}

test "Removes Trivial Nested Sections" {
    var sa = SliceArray.init(std.testing.allocator);
    defer sa.deinit();

    try sa.append(
        \\Before Content
        \\{{Cite [some content] {{Cite [some nested content]}} }}
        \\After Content
    );

    try sa.removeSections("{{", "}}");

    const renderedString = try sa.toSlice();
    defer std.testing.allocator.free(renderedString);

    try std.testing.expectEqualStrings(
        \\Before Content
        \\
        \\After Content
    ,
        renderedString,
    );
}

test "Removes Multiple Sections" {
    var sa = SliceArray.init(std.testing.allocator);
    defer sa.deinit();

    try sa.append(
        \\Before Content
        \\{{Cite [some content] {{Cite [some nested content]}} }}
        \\<!-- My Comment! -->
        \\After Content
    );

    try sa.removeSections("<!--", "-->");
    try sa.removeSections("{{", "}}");

    const renderedString = try sa.toSlice();
    defer std.testing.allocator.free(renderedString);

    try std.testing.expectEqualStrings(
        \\Before Content
        \\
        \\
        \\After Content
    ,
        renderedString,
    );
}

test "Removes Multiple Instances of One Section" {
    var sa = SliceArray.init(std.testing.allocator);
    defer sa.deinit();

    try sa.append(
        \\{{Other uses|Anarchy|Anarchism (disambiguation)|Anarchist (disambiguation)}}
        \\{{Pp-semi-indef}}
        \\{{Good article}}
        \\{{Use British English|date=August 2021}}
        \\{{Use dmy dates|date=August 2021}}
        \\{{Use shortened footnotes|date=May 2023}}
        \\{{Anarchism sidebar}}
    );

    try sa.removeSections("{{", "}}");

    const renderedString = try sa.toSlice();
    defer std.testing.allocator.free(renderedString);

    try std.testing.expectEqualStrings(
        \\
        \\
        \\
        \\
        \\
        \\
        \\
    ,
        renderedString,
    );
}

test "Same open and close tags" {
    var sa = SliceArray.init(std.testing.allocator);
    defer sa.deinit();

    try sa.append(
        \\Before Section Content
        \\==References==
        \\== See Also ==
        \\After Section Content
    );

    try sa.removeSections("==", "==");

    const renderedString = try sa.toSlice();
    defer std.testing.allocator.free(renderedString);

    try std.testing.expectEqualStrings(
        \\Before Section Content
        \\
        \\
        \\After Section Content
    , renderedString);
}

test "findAndReplace Trivial" {
    var sa = SliceArray.init(std.testing.allocator);
    defer sa.deinit();

    try sa.append("'''Hello''', World!");

    try sa.findAndReplace("'''", "**");

    const renderedString = try sa.toSlice();
    defer std.testing.allocator.free(renderedString);

    try std.testing.expectEqualStrings("**Hello**, World!", renderedString);
}
