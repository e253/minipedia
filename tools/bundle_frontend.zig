const std = @import("std");

const import_prefix: []const u8 = "./frontend-files";

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len != 2) fatal("not enough args, found {}", .{args.len});
    const output_file_path = args[1];

    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();
    const out_file_writer = output_file.writer();

    var file_paths = try std.ArrayList([]const u8).initCapacity(allocator, 50);

    var dir = try std.fs.cwd().openDir("./frontend/build", .{ .iterate = true });
    defer dir.close();

    var buf: [std.fs.MAX_PATH_BYTES]u8 = std.mem.zeroes([std.fs.MAX_PATH_BYTES]u8);
    var prefix: []u8 = buf[0..0];

    writeDir(allocator, dir, out_file_writer, &prefix, &file_paths);

    try out_file_writer.writeAll("\nconst kv = [_]struct{[]const u8, []const u8}{");

    for (file_paths.items) |file_path| {
        try std.fmt.format(
            out_file_writer,
            \\.{{"{s}", @"{s}"}},
        ,
            .{
                file_path,
                file_path,
            },
        );
    }

    try out_file_writer.writeAll("};\n");
    try out_file_writer.writeAll(
        \\pub const files = @import("std").StaticStringMap([]const u8).initComptime(&kv);
    );
}

fn writeDir(a: std.mem.Allocator, dir: std.fs.Dir, writer: anytype, prefix: *[]u8, file_paths: *std.ArrayList([]const u8)) void {
    var dir_iter = dir.iterate();

    while (dir_iter.next() catch |err| fatal("Dir could not iterate!, Error: '{s}'\n", .{@errorName(err)})) |entry| {
        switch (entry.kind) {
            .file => {
                const path = std.fmt.allocPrint(a, "{s}/{s}", .{ prefix.*, entry.name }) catch @panic("OOM");
                file_paths.append(path) catch @panic("OOM");

                std.fmt.format(writer,
                    \\const @"{s}" = @embedFile("{s}{s}/{s}");
                    \\
                , .{ path, import_prefix, prefix.*, entry.name }) catch |err| fatal("Write error: '{s}'\n", .{@errorName(err)});
            },
            .directory => {
                var prev_len = prefix.len;
                prefix.len += 1;
                prefix.*[prev_len] = '/';
                prev_len += 1;
                prefix.len += entry.name.len;
                @memcpy(prefix.*[prev_len..], entry.name);

                var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                const dir_path = dir.realpath(entry.name, &buf) catch |err| fatal("realpath failed. Error: '{s}'\n", .{@errorName(err)});

                var _dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| fatal("Sub Dir {s} could not be opened. Error: '{s}'\n", .{ dir_path, @errorName(err) });
                defer _dir.close();
                writeDir(a, _dir, writer, prefix, file_paths);

                prefix.len = prev_len - 1;
            },
            else => continue,
        }
    }
}

//fn dupe(a: std.mem.Allocator, in: []const u8) []const u8 {
//    const new = a.alloc(in.len) catch @panic("OOM");
//    @memcpy(new, in);
//    return new;
//}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
