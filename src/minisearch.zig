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
    /// `title_buf` should be length `limit * MAX_TITLE_SIZE`
    ///
    /// **Asserts `limit > 0` and `query_len > 0`**
    extern fn ms_search(
        c: *const Ctx,
        query: [*]const u8,
        query_len: usize,
        limit: usize,
        offset: usize,
        results_buf: [*]rs.Result,
        title_buf: [*]u8,
    ) usize;

    /// Checks if document with `title` exists in the index.
    /// Only exact matches are given
    extern fn ms_doc_id_from_title(
        state: *const rs.Ctx,
        title: [*]const u8,
        title_len: usize,
    ) usize;

    /// Closes
    extern fn ms_deinit(c: *const Ctx) void;
};

const Minisearch = @This();
internal: rs.Ctx,

pub const MAX_TITLE_SIZE = 256;
pub const Result = struct {
    title: []const u8,
    id: usize,
};

/// Initializes tantivy index
pub fn init(index_dir: []const u8) Minisearch {
    var internal_ctx: rs.Ctx = .{};

    rs.ms_init(&internal_ctx, index_dir.ptr, index_dir.len);

    return .{ .internal = internal_ctx };
}

/// Close tantivy index
pub fn deinit(self: Minisearch) void {
    rs.ms_deinit(&self.internal);
}

/// **`a` must be an arena!**
pub fn search(
    self: Minisearch,
    a: std.mem.Allocator,
    query: []const u8,
    limit: usize,
    offset: usize,
) ![]const Result {
    if (limit == 0 or query.len == 0) {
        return &[0]Result{};
    }

    var c_results = try a.alloc(rs.Result, limit);
    const storage = try a.alloc(u8, limit * MAX_TITLE_SIZE);

    c_results.len = rs.ms_search(&self.internal, query.ptr, query.len, limit, offset, c_results.ptr, storage.ptr);

    const results = try a.alloc(Result, limit);

    for (c_results, 0..) |cres, i| {
        results[i] = .{
            .title = cres.title(),
            .id = cres.doc_id,
        };
    }

    return results;
}

/// gets document id from title
///
/// `title` must be an exact match
pub fn doc(self: Minisearch, title: []const u8) ?usize {
    const id = rs.ms_doc_id_from_title(&self.internal, title.ptr, title.len);
    if (id == std.math.maxInt(usize)) {
        return null;
    } else {
        return id;
    }
}
