const c = @cImport({
    @cDefine("LZMA_API(type)", "type");
    @cInclude("lzma.h");
});

const std = @import("std");

// Allocator
const Allocator = c.lzma_allocator;
/// DOES NOT FREE, must use external arena to do this instead
fn lzma_allocator_free(_: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {}
fn lzma_allocator_alloc(_zig_a: ?*anyopaque, _: usize, size: usize) callconv(.C) ?*anyopaque {
    const zig_a: *std.mem.Allocator = @alignCast(@ptrCast(_zig_a));
    const alloc_slice = zig_a.alloc(u8, size) catch |err| switch (err) {
        error.OutOfMemory => @panic("LZMA Allocator ran out of memory!"),
    };
    return alloc_slice.ptr;
}
/// ALLOCATOR MUST BE AN ARENA!!
pub fn from_zig_allocator(a: *const std.mem.Allocator) Allocator {
    return .{
        .alloc = lzma_allocator_alloc,
        .free = lzma_allocator_free,
        .@"opaque" = @constCast(a),
    };
}

// Streams
pub const Stream = c.lzma_stream;
/// 0 initializes a `Stream` struct
pub fn stream_init() Stream {
    return .{
        .next_in = null,
        .avail_in = 0,
        .total_in = 0,
        .next_out = null,
        .avail_out = 0,
        .total_out = 0,
        .allocator = null,
        .reserved_ptr1 = null,
        .reserved_ptr2 = null,
        .reserved_ptr3 = null,
        .reserved_ptr4 = null,
        .seek_pos = 0,
        .reserved_int2 = 0,
        .reserved_int3 = 0,
        .reserved_int4 = 0,
        .reserved_enum1 = c.LZMA_RESERVED_ENUM,
        .reserved_enum2 = c.LZMA_RESERVED_ENUM,
    };
}
pub const end = c.lzma_end;

// LZMA2 Configuration
pub const OptionsLZMA = c.lzma_options_lzma;
/// Defaults to -9e, the highest lzma cli setting
pub fn options_lzma_default() OptionsLZMA {
    return .{
        .dict_size = 64_000_000,
        .lc = 3,
        .lp = 0,
        .pb = 2,
        .mode = c.LZMA_MODE_NORMAL,
        .nice_len = 273,
        .mf = c.LZMA_MF_BT4,
        .depth = 512,
    };
}

// LZMA Filters
pub const FILTERS_MAX: usize = @intCast(c.LZMA_FILTERS_MAX);
pub const Filter = c.lzma_filter;
pub const FilterId = enum(u64) {
    lzma2 = c.LZMA_FILTER_LZMA2,
    filters_end = c.LZMA_VLI_UNKNOWN,
};

// Checks
pub const check = enum(u32) {
    none = c.LZMA_CHECK_NONE,
    crc32 = c.LZMA_CHECK_CRC32,
    crc64 = c.LZMA_CHECK_CRC64,
    sha256 = c.LZMA_CHECK_SHA256,
};

// Stream Initialization
pub const StreamInitError = error{
    ProgError,
    OptionsError,
    MemError,
};

pub fn stream_encoder(s: *Stream, filters: [FILTERS_MAX + 1]Filter, ch: check) StreamInitError!void {
    const r: c.lzma_ret = c.lzma_stream_encoder(s, &filters, @intFromEnum(ch));
    switch (r) {
        c.LZMA_PROG_ERROR => return StreamInitError.ProgError,
        c.LZMA_OPTIONS_ERROR => return StreamInitError.OptionsError,
        c.LZMA_MEM_ERROR => return StreamInitError.MemError,
        c.LZMA_OK => return,
        else => unreachable,
    }
}

pub fn stream_decoder(s: *Stream) StreamInitError!void {
    const r: c.lzma_ret = c.lzma_stream_decoder(s, c.UINT64_MAX, 0);
    switch (r) {
        c.LZMA_PROG_ERROR => return StreamInitError.ProgError,
        c.LZMA_OPTIONS_ERROR => return StreamInitError.OptionsError,
        c.LZMA_MEM_ERROR => return StreamInitError.MemError,
        c.LZMA_OK => return,
        else => unreachable,
    }
}

// Encoding / Decoding Execution
pub const Action = enum(u32) {
    run = c.LZMA_RUN,
    finish = c.LZMA_FINISH,
};

pub const LzmaError = error{
    NoCheck,
    UnsupportedCheck,
    GetCheck,
    MemError,
    MemLimitError,
    FormatError,
    OptionsError,
    DataError,
    BufError,
    ProgError,
    SeekNeeded,
};

/// StreamEnd and Ok are both valid,
/// but mean different things
pub const LzmaOk = enum {
    StreamEnd,
    Ok,
};

/// Wraps `lzma_code` with nice error handling
pub fn execute(s: *Stream, a: Action) LzmaError!LzmaOk {
    const r: c.lzma_ret = c.lzma_code(s, @intFromEnum(a));
    switch (r) {
        c.LZMA_NO_CHECK => return LzmaError.NoCheck,
        c.LZMA_UNSUPPORTED_CHECK => return LzmaError.UnsupportedCheck,
        c.LZMA_GET_CHECK => return LzmaError.GetCheck,
        c.LZMA_MEM_ERROR => return LzmaError.MemError,
        c.LZMA_MEMLIMIT_ERROR => return LzmaError.MemLimitError,
        c.LZMA_FORMAT_ERROR => return LzmaError.FormatError,
        c.LZMA_OPTIONS_ERROR => return LzmaError.OptionsError,
        c.LZMA_DATA_ERROR => return LzmaError.DataError,
        c.LZMA_BUF_ERROR => return LzmaError.BufError,
        c.LZMA_PROG_ERROR => return LzmaError.ProgError,
        c.LZMA_SEEK_NEEDED => return LzmaError.SeekNeeded,
        c.LZMA_STREAM_END => return LzmaOk.StreamEnd,
        c.LZMA_OK => return LzmaOk.Ok,
        else => unreachable,
    }
}

/// Single call lzma2 -9e compress from input data `in`
/// to output buffer `out`
///
/// `a` MUST BE AN ARENA since it will be passed to liblzma
///
/// Otherwise, `a` can be null and the libc allocator is used instead
///
/// Return value points to `out` but with an adjusted size
pub fn compress(a_opt: ?*const std.mem.Allocator, in: []const u8, out: []u8) ![]u8 {
    var compression_opts = options_lzma_default();
    const filters = [FILTERS_MAX + 1]Filter{
        .{ .id = @intFromEnum(FilterId.lzma2), .options = &compression_opts },
        .{ .id = @intFromEnum(FilterId.filters_end) },
        .{},
        .{},
        .{},
    };

    var s = stream_init();

    if (a_opt) |a| {
        s.allocator = &from_zig_allocator(a);
    }

    try stream_encoder(&s, filters, .crc32);

    s.next_in = @constCast(in.ptr);
    s.avail_in = in.len;
    s.next_out = out.ptr;
    s.avail_out = out.len;

    std.debug.assert(try execute(&s, .finish) == .StreamEnd);

    end(&s);

    return out[0 .. out.len - s.avail_out];
}

/// This will decode the XZ block that the `GenericReader` `in` is pointing to
///
/// `out` must be large enough to hold the decompressed block or else UB
pub fn decompress(a_opt: ?*const std.mem.Allocator, in: anytype, out: []u8) ![]u8 {
    var s = stream_init();

    if (a_opt) |a| {
        s.allocator = &from_zig_allocator(a);
    }

    try stream_decoder(&s);

    var inbuf: [4096]u8 = undefined;

    s.next_in = null;
    s.avail_in = 0;
    s.next_out = out.ptr;
    s.avail_out = out.len;

    var action: Action = .run;

    while (true) {
        if (s.avail_in == 0) { // the buffer is exhausted and we need to read more!
            s.next_in = &inbuf;
            s.avail_in = blk: {
                const bytes_in = try in.read(&inbuf);
                if (bytes_in < inbuf.len) { // eof
                    action = .finish;
                }
                break :blk bytes_in;
            };
        }

        const ret = try execute(&s, action);

        if (ret == .StreamEnd) { // we are done!
            break;
        }
    }

    end(&s);

    return out[0 .. out.len - s.avail_out];
}

test "Stream Initialization" {
    const s = stream_init();
    try std.testing.expect(s.next_in == null);
}

test "Hello, World! Compress" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const in: []const u8 = "Hello, World!";
    var out = try alloc.alloc(u8, 256);
    const expected = [_]u8{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x0, 0x0, 0x1, 0x69, 0x22, 0xde, 0x36, 0x02, 0x00, 0x21, 0x01, 0x1c, 0x00, 0x00, 0x00, 0x10, 0xcf, 0x58, 0xcc, 0x01, 0x00, 0x0c, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21, 0x0, 0x0, 0x0, 0x0, 0xd0, 0xc3, 0x4a, 0xec, 0x0, 0x1, 0x21, 0xd, 0x75, 0xdc, 0xa8, 0xd2, 0x90, 0x42, 0x99, 0x0d, 0x1, 0x0, 0x0, 0x0, 0x0, 0x1, 0x59, 0x5a };

    out = try compress(&alloc, in, out);

    try std.testing.expect(out.len == 68);
    try std.testing.expectEqualSlices(u8, &expected, out);
}

test "Hello, World! Decompress" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const in = [_]u8{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x0, 0x0, 0x1, 0x69, 0x22, 0xde, 0x36, 0x02, 0x00, 0x21, 0x01, 0x1c, 0x00, 0x00, 0x00, 0x10, 0xcf, 0x58, 0xcc, 0x01, 0x00, 0x0c, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21, 0x0, 0x0, 0x0, 0x0, 0xd0, 0xc3, 0x4a, 0xec, 0x0, 0x1, 0x21, 0xd, 0x75, 0xdc, 0xa8, 0xd2, 0x90, 0x42, 0x99, 0x0d, 0x1, 0x0, 0x0, 0x0, 0x0, 0x1, 0x59, 0x5a };
    var in_fbs_stream = std.io.fixedBufferStream(&in);
    const in_reader = in_fbs_stream.reader();
    var out = try alloc.alloc(u8, 256);
    const expected: []const u8 = "Hello, World!";

    out = try decompress(&alloc, in_reader, out);

    try std.testing.expectEqualStrings(expected, out);
}
