const std = @import("std");

pub fn TestTrace(ErrorSet: type) type {
    return struct {
        const Self = @This();
        pub fn err(_: *const Self, E: ErrorSet) ErrorSet {
            return E;
        }
        pub fn begin(_: *const Self, _: usize) void {}
        pub fn success(_: *const Self) !void {}
    };
}

pub fn StdoutTrace(ErrorSet: type) type {
    return struct {
        const Self = @This();
        doc_id: usize,
        pub fn err(s: *const Self, E: ErrorSet) ErrorSet {
            const stdout = std.io.getStdOut().writer();
            stdout.print("[MediaWiki Parsing] DOC {}: Err({}) {s}\n", .{ s.doc_id, @intFromError(E), @errorName(E) }) catch @panic("STDOUT PRINT FAILED");
            return E;
        }
        pub fn begin(_: *const Self, _: usize) void {}
    };
}

const c = @cImport(@cInclude("duck_tracer.h"));

pub const DucktraceError = error{
    DatabaseOpenFailed,
    DatabaseConnectionFailed,
    SchemaCreationFailed,
    AppenderCreateFailed,

    DocAppendDataFailed,
    FailureAppendDataFailed,

    AppenderFlushFailed,
};

fn cerrToZigErr(err_code: c_uint) DucktraceError {
    switch (err_code) {
        c.DatabaseOpenFailed => return DucktraceError.DatabaseOpenFailed,
        c.DatabaseConnectionFailed => return DucktraceError.DatabaseConnectionFailed,
        c.SchemaCreationFailed => return DucktraceError.SchemaCreationFailed,
        c.AppenderCreateFailed => return DucktraceError.AppenderCreateFailed,

        c.DocAppendDataFailed => return DucktraceError.DocAppendDataFailed,
        c.FailureAppendDataFailed => return DucktraceError.FailureAppendDataFailed,

        c.AppenderFlushFailed => return DucktraceError.AppenderFlushFailed,
        else => unreachable,
    }
}

pub const DuckTrace = struct {
    const Self = @This();

    internal: c.ducktrace_state = std.mem.zeroes(c.ducktrace_state),

    pub fn DuckTraceInstance(ErrorSet: type) type {
        return struct {
            const Inst = @This();

            doc_id: usize,
            text: []const u8,
            /// start pos in `text` of the current parsing step
            pos: usize,
            internal: *c.ducktrace_state,
            section: enum { Parsing, Generating },

            pub fn err(s: *const Inst, E: ErrorSet) ErrorSet {
                const res = c.insert_doc(s.internal, @intCast(s.doc_id), s.section == .Parsing, s.section == .Generating);
                if (res != c.DucktraceOk)
                    @panic("Insert Doc Failed");

                if (s.section == .Parsing) {
                    const err_ctx = getLineFromPos(s.text, s.pos);
                    const res2 = c.insert_failure(s.internal, @intCast(s.doc_id), @intFromError(E), @errorName(E), err_ctx.ptr, err_ctx.len);
                    if (res2 != c.DucktraceOk)
                        @panic("Insert Failure Failed");
                }

                return E;
            }

            pub fn begin(s: *Inst, start_pos: usize) void {
                s.pos = start_pos;
            }

            pub fn success(s: *const Inst) !void {
                const res = c.insert_doc(s.internal, @intCast(s.doc_id), false, false);
                if (res != c.DucktraceOk) {
                    return cerrToZigErr(res);
                }
            }
        };
    }

    pub fn newInstance(s: *Self, doc_id: usize, text: []const u8, ErrorSet: type) DuckTraceInstance(ErrorSet) {
        return .{
            .doc_id = doc_id,
            .text = text,
            .pos = 0,
            .internal = &s.internal,
            .section = .Parsing,
        };
    }

    pub fn init(db_path: [*:0]const u8) DucktraceError!Self {
        var s: Self = .{};
        const res = c.ducktrace_init(&s.internal, db_path);
        if (res == c.DucktraceOk) {
            return s;
        } else {
            return cerrToZigErr(res);
        }
    }

    pub fn deinit(s: *Self) void {
        c.ducktrace_deinit(&s.internal);
    }
};

fn getLineFromPos(text: []const u8, pos: usize) []const u8 {
    if (pos >= text.len)
        return "";

    const line_start = blk: {
        if (std.mem.lastIndexOfScalar(u8, text[0..pos], '\n')) |line_start|
            break :blk line_start + "\n".len;
        break :blk 0;
    };

    const line_end = blk: {
        if (std.mem.indexOfScalar(u8, text[pos..], '\n')) |line_end|
            break :blk line_end + pos;
        break :blk text.len;
    };

    return text[line_start..line_end];
}
