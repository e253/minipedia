const std = @import("std");

const c = struct {
    const sz_cptr_t = [*c]const u8;
    const sz_size_t = usize;
    extern fn sz_find(haystack: sz_cptr_t, h_length: sz_size_t, needle: sz_cptr_t, n_length: sz_size_t) sz_cptr_t;
    extern fn sz_find_case_insensitive(haystack: sz_cptr_t, h_length: sz_size_t, needle: sz_cptr_t, n_length: sz_size_t) sz_cptr_t;

    /// Very inefficient
    ///
    /// This called from stringzilla.c
    export fn sz_find_byte_case_insensitive_serial(haystack_ptr: [*c]const u8, h_length: usize, needle_ptr: [*c]const u8) ?[*]u8 {
        if (haystack_ptr == null or needle_ptr == null or h_length == 0)
            return null;

        const haystack = haystack_ptr[0..h_length];
        const needle = needle_ptr[0];

        for (haystack, 0..) |ch, i| {
            if (needle == std.ascii.toLower(ch))
                return @ptrFromInt(@intFromPtr(haystack_ptr) + i);
        }

        return null;
    }

    /// Very inefficient
    ///
    /// This called from stringzilla.c
    export fn sz_find_case_insensitive_serial(haystack_ptr: [*c]const u8, h_length: usize, needle_ptr: [*c]const u8, n_length: usize) ?[*]u8 {
        if (haystack_ptr == null or needle_ptr == null)
            return null;
        if (n_length > h_length) return null;

        const haystack = haystack_ptr[0..h_length];
        const needle = needle_ptr[0..n_length];

        var i: usize = 0;
        const end = haystack.len - needle.len;
        while (i <= end) : (i += 1) {
            const ministack = haystack[i..][0..needle.len];

            const eql = blk: {
                if (ministack.len != needle.len) break :blk false;
                if (ministack.len == 0) break :blk true;

                for (ministack, needle) |m_c, n_c| {
                    if (std.ascii.toLower(m_c) != std.ascii.toLower(n_c))
                        break :blk false;
                }
                break :blk true;
            };

            if (eql) return @ptrFromInt(@intFromPtr(haystack_ptr) + i);
        }
        return null;
    }
};

pub fn indexOfPos(haystack: []const u8, needle: []const u8, pos: usize) ?usize {
    if (needle.len > haystack.len or needle.len == 0 or haystack.len == 0) return null;

    const new_haystack = haystack[pos..];

    const match_start = c.sz_find(new_haystack.ptr, new_haystack.len, needle.ptr, needle.len);

    if (match_start == null)
        return null;

    return @intFromPtr(match_start) - @intFromPtr(haystack.ptr);
}

pub fn indexOfCaseInsensitivePos(haystack: []const u8, needle: []const u8, pos: usize) ?usize {
    if (needle.len > haystack.len or needle.len == 0 or haystack.len == 0) return null;

    const new_haystack = haystack[pos..];

    const match_start = c.sz_find_case_insensitive(new_haystack.ptr, new_haystack.len, needle.ptr, needle.len);

    if (match_start == null)
        return null;

    return @intFromPtr(match_start) - @intFromPtr(haystack.ptr);
}
