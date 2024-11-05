pub fn TestTrace(ErrorSet: type) type {
    return struct {
        const Self = @This();
        pub fn err(_: *const Self, E: ErrorSet) ErrorSet {
            return E;
        }
    };
}

pub fn StdoutTrace(ErrorSet: type) type {
    return struct {
        const Self = @This();
        doc_id: usize,
        pub fn err(s: *const Self, E: ErrorSet) ErrorSet {
            const std = @import("std");

            const stdout = std.io.getStdOut().writer();
            stdout.print("[MediaWiki Parsing] DOC {}: Err({}) {s}\n", .{ s.doc_id, @intFromError(E), @errorName(E) }) catch @panic("STDOUT PRINT FAILED");

            return E;
        }
    };
}
