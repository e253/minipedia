const std = @import("std");
const a = std.heap.c_allocator;
const MinidumpReader = @import("lib/minidump_reader.zig");

pub fn main() !void {
    const args = try Args.parse();

    const mdr = try MinidumpReader.init(a, args.minidump_rel_path);
    defer mdr.deinit();
    const mkdwn = try mdr.markdown(args.article_id) orelse {
        try std.io.getStdOut().writer().print("Article {} could not be found\n", .{args.article_id});
        return;
    };

    try std.io.getStdOut().writeAll(mkdwn);
}

pub const Args = struct {
    article_id: u64,
    minidump_rel_path: []const u8,

    const ParseError = error{ TooManyArgs, NotEnoughArgs };

    pub fn parse() !Args {
        const sT = std.mem.sliceTo;

        const help =
            \\
            \\Usage:
            \\  {s} [minidump relative path (str)] [article_id (int)]
            \\
            \\Example:
            \\  {s} ./out.minidump 0
            \\
            \\
        ;

        const argv0 = sT(std.os.argv[0], 0);

        if (std.os.argv.len < 3) {
            std.debug.print(help, .{ argv0, argv0 });
            return ParseError.NotEnoughArgs;
        }

        if (std.os.argv.len == 3) {
            return .{
                .minidump_rel_path = sT(std.os.argv[1], 0),
                .article_id = try std.fmt.parseInt(u64, sT(std.os.argv[2], 0), 10),
            };
        }

        std.debug.print(help, .{ argv0, argv0 });
        return ParseError.TooManyArgs;
    }
};
