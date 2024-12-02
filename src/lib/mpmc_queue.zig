const std = @import("std");

pub fn MPMCQueue(T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            turn: std.atomic.Value(usize) align(std.atomic.cache_line),
            item: T,
        };

        slots: [capacity]Slot = std.mem.zeroes([capacity]Slot),
        head: std.atomic.Value(usize) align(std.atomic.cache_line) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = std.atomic.Value(usize).init(0),

        pub fn send(s: *Self, item: T) void {
            @setRuntimeSafety(false);
            const write_ticket = s.head.fetchAdd(1, .monotonic);

            const slot = &s.slots[write_ticket % capacity];
            const turn = 2 * (write_ticket / capacity);

            while (turn != slot.turn.load(.acquire)) {}

            (&slot.item).* = item;
            slot.turn.store(turn + 1, .release);
        }

        pub fn take(s: *Self) T {
            @setRuntimeSafety(false);
            const read_ticket = s.tail.fetchAdd(1, .monotonic);

            const slot = &s.slots[read_ticket % capacity];
            const turn = 2 * (read_ticket / capacity) + 1;

            while (turn != slot.turn.load(.acquire)) {}

            defer slot.turn.store(turn + 1, .release);
            return slot.item;
        }
    };
}

pub const BufferPool = struct {
    const Self = @This();
    const AtomicInt = std.atomic.Value(usize);

    a: std.mem.Allocator,
    slab: []u8,
    buf_size: usize,
    buffers: [][]u8,
    head: AtomicInt,
    tail: AtomicInt,

    pub fn init(a: std.mem.Allocator, capacity: usize, buf_size: usize) !Self {
        const slab = try std.heap.page_allocator.alloc(u8, buf_size * capacity);

        const buffers: [][]u8 = try a.alloc([]u8, capacity);
        for (buffers, 0..) |*buf, i|
            buf.* = slab[i * buf_size .. (i + 1) * buf_size];

        return .{
            .a = a,
            .slab = slab,
            .buf_size = buf_size,
            .buffers = buffers,
            .tail = AtomicInt.init(0),
            .head = AtomicInt.init(capacity),
        };
    }

    /// Do not change 'ptr' on the return value.
    ///
    /// This function is not thread safe.
    pub fn acquireBuffer(this: *Self) []u8 {
        return this.buffers[this.tail.fetchAdd(1, .monotonic) % this.buffers.len];
    }

    /// `error.PageNotFound` returned when
    pub fn releaseBuffer(this: *Self, page: []const u8) void {
        if (!this.ownsPtr(page.ptr)) @panic("Pool doesn't own buffer.");
        if (@mod(@intFromPtr(page.ptr) - @intFromPtr(this.slab.ptr), this.buf_size) != 0) @panic("Buffer ptr was modified.");

        this.buffers[this.head.fetchAdd(1, .monotonic) % this.buffers.len] = @constCast(page.ptr[0..this.buf_size]);
    }

    fn ownsPtr(this: *Self, ptr: [*]const u8) bool {
        return @intFromPtr(ptr) >= @intFromPtr(this.slab.ptr) and
            @intFromPtr(ptr) < (@intFromPtr(this.slab.ptr) + this.slab.len);
    }

    pub fn deinit(s: *Self) void {
        std.heap.page_allocator.free(s.slab);
        s.a.free(s.buffers);
    }
};
