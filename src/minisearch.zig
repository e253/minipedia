const std = @import("std");

/// Rust data structures and call signatures.
///
/// `search/lib.rs`
const rs = struct {
    const Ctx = extern struct {
        /// tantivy `Index`
        ptr1: ?*anyopaque = std.mem.zeroes(?*anyopaque),
        /// tantivy `IndexReader`
        ptr2: ?*anyopaque = std.mem.zeroes(?*anyopaque),
    };

    const Result = extern struct {
        _title: [*]const u8,
        title_len: usize,
        doc_id: usize,

        pub fn title(self: rs.Result) []const u8 {
            return self._title[0..self.title_len];
        }
    };

    /// Initializes `c` with tantivy index at `index_dir`
    extern fn ms_init(c: *Ctx, index_dir: [*]const u8, index_dir_len: usize) void;

    /// Writes results to `results_buf`
    ///
    /// `results_buf` should be length `limit`
    ///
    /// `title_buf` should be length `limit * 256`
    extern fn ms_search(
        c: *const Ctx,
        query: [*]const u8,
        query_len: usize,
        limit: usize,
        offset: usize,
        results_buf: [*]rs.Result,
        title_buf: [*]u8,
    ) usize;

    /// Closes
    extern fn ms_deinit(c: *const Ctx) void;
};

const Minisearch = @This();
pub const Result = rs.Result;

internal: rs.Ctx,

pub fn init(index_dir: []const u8) Minisearch {
    var internal_ctx: rs.Ctx = .{};

    rs.ms_init(&internal_ctx, index_dir.ptr, index_dir.len);

    return .{ .internal = internal_ctx };
}

pub fn deinit(self: *const Minisearch) void {
    rs.ms_deinit(&self.internal);
}

pub fn search(
    self: *const Minisearch,
    query: []const u8,
    limit: usize,
    offset: usize,
    results: *[]Result,
    title_buf: []u8,
) void {
    std.debug.assert(results.len >= limit);
    std.debug.assert(title_buf.len >= limit * 256);

    const n_results = rs.ms_search(&self.internal, query.ptr, query.len, limit, offset, results.ptr, title_buf.ptr);

    results.len = n_results;
}
