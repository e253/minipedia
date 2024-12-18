const std = @import("std");

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

    pub fn reset(self: *SliceArray) void {
        self.slices.clearRetainingCapacity();
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
    pub fn writeToSlice(self: *SliceArray, out: []u8) ![]u8 {
        var i: usize = 0;
        for (self.slices.items) |slice| {
            @memcpy(out[i .. i + slice.len], slice);
            i += slice.len;
        }

        return out[0..i];
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

    /// Faster f and r the searches for multiple targets at once.
    pub fn findAndReplaceMulti(self: *SliceArray, comptime old_list: []const []const u8, comptime new_list: []const []const u8) !void {
        comptime {
            if (old_list.len != new_list.len) @compileError("`old_list` and `new_list` must have the same length.");
            for (old_list) |old| if (old.len == 0) @compileError("`old` value must have length greater than 0.");
            for (0..old_list.len - 1) |i| {
                if (old_list[i].len < old_list[i + 1].len) @compileError("`old_list` length must be in descending order.");
            }
        }
        // TODO: comptime
        var stop_chars: [256]bool = [1]bool{false} ** 256;
        for (old_list) |old| stop_chars[old[0]] = true;

        var slice_idx: usize = 0;
        outer: while (slice_idx < self.slices.items.len) {
            const slice = self.slices.items[slice_idx];

            var i: usize = 0;
            while (i < slice.len) : (i += 1) {
                if (!stop_chars[slice[i]]) continue;
                inline for (old_list, new_list) |old, new| {
                    const cmp_slice_end = if (i + old.len < slice.len) i + old.len else slice.len;
                    if (std.mem.eql(u8, slice[i..cmp_slice_end], old)) {
                        const old_start = i;
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

                        continue :outer;
                    }
                }
            }
            slice_idx += 1;
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

test "findAndReplace" {
    var sa = SliceArray.init(std.testing.allocator);
    defer sa.deinit();

    try sa.append("'''Hello''', World!");

    try sa.findAndReplace("'''", "**");

    const renderedString = try sa.toSlice();
    defer std.testing.allocator.free(renderedString);

    try std.testing.expectEqualStrings("**Hello**, World!", renderedString);
}

test "findAndReplaceMulti" {
    var sa = SliceArray.init(std.testing.allocator);
    defer sa.deinit();

    try sa.append("&quot;&amp;&quo");

    const old_list: []const []const u8 = &.{ "&quot;", "&amp;", "&quo" };
    const new_list: []const []const u8 = &.{ "He", "llo", ", World!" };

    try sa.findAndReplaceMulti(old_list, new_list);

    const renderedString = try sa.toSlice();
    defer std.testing.allocator.free(renderedString);

    try std.testing.expectEqualStrings("Hello, World!", renderedString);
}
