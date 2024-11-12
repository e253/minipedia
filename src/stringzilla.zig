const std = @import("std");

const c = struct {
    const sz_cptr_t = [*c]const u8;
    const sz_size_t = usize;
    extern fn sz_find(haystack: sz_cptr_t, h_length: sz_size_t, needle: sz_cptr_t, n_length: sz_size_t) sz_cptr_t;
};

pub fn indexOfPos(haystack: []const u8, needle: []const u8, pos: usize) ?usize {
    if (needle.len > haystack.len or needle.len == 0 or haystack.len == 0) return null;

    const new_haystack = haystack[pos..];

    const match_start = c.sz_find(new_haystack.ptr, new_haystack.len, needle.ptr, needle.len);

    if (match_start == null)
        return null;

    return @intFromPtr(match_start) - @intFromPtr(haystack.ptr);
}
