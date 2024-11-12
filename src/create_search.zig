const std = @import("std");

pub fn main() !void {
    const old_f = try std.fs.cwd().openFile(std.mem.sliceTo(std.os.argv[1], 0), .{});
    defer old_f.close();
    var oldBR = std.io.bufferedReader(old_f.reader());
    const reader = oldBR.reader();

    const new_f = try std.fs.cwd().createFile("./out.index", .{});
    defer new_f.close();
    var newBW = std.io.bufferedWriter(new_f.writer());
    const writer = newBW.writer();
    try writer.writeByte(0);

    var lineBuf: [256]u8 = undefined;

    var doc_id: usize = 0;
    while (true) : (doc_id += 1) {
        var title = try reader.readUntilDelimiterOrEof(&lineBuf, '\n') orelse break;

        if (std.mem.indexOfScalar(u8, title, '&') != null) {
            var replaceBuf1: [256]u8 = undefined;
            var replaceBuf2: [256]u8 = undefined;
            const n_subs = std.mem.replace(u8, title, "&amp;", "&", &replaceBuf1);
            const n_subs2 = std.mem.replace(u8, (&replaceBuf1)[0 .. title.len - "amp;".len - n_subs], "&quot;", "\"", &replaceBuf2);

            title.len -= ("amp;".len * n_subs + "quot;".len * n_subs2);

            @memcpy(title, replaceBuf2[0..title.len]);
        }

        try writer.writeAll(title);
        try writer.writeByte(0);
        try writer.writeInt(u24, @intCast(doc_id), .big);
        try writer.writeByte(0);
    }
}
