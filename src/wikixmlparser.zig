const std = @import("std");

/// Gets <page>[content]</page> from wikidump stream.
/// Returns `error.EndOfStream` for EOF.
pub fn nextPageAlloc(a: std.mem.Allocator, reader: anytype) ![]const u8 {
    var al = std.ArrayList(u8).init(a);

    // Find opening Tag
    while (true) {
        const b: u8 = try reader.readByte();
        if (b == '<') {
            var nextBytes: ["page>".len]u8 = undefined;
            _ = try reader.read(&nextBytes);
            if (std.mem.eql(u8, &nextBytes, "page>")) {
                try al.appendSlice("<page>");
                break;
            }
        }
    }

    // Find closing tag, while reading data in the middle
    // TODO: transfer page content in one call
    while (true) {
        const b: u8 = try reader.readByte();
        if (b == '<') {
            var nextBytes: ["/page>".len]u8 = undefined;
            _ = try reader.read(&nextBytes);
            if (std.mem.eql(u8, &nextBytes, "/page>")) {
                break;
            } else {
                try al.append('<');
                try al.appendSlice(&nextBytes);
            }
        } else {
            try al.append(b);
        }
    }

    try al.appendSlice("</page>");
    try al.append(0);

    return al.items;
}

const c = @cImport(@cInclude("wikixmlparser.h"));
const WikiParseResult = c.WikiParseResult;
const cParsePage = c.cParsePage;

const WikiArticle = struct {
    title: []const u8,
    article: []const u8,
};

/// Extract page content if the page is not a redirect.
/// Takes single <page></page> entry **null terminated**!
pub fn parsePage(pageRawXml: []const u8) ?WikiArticle {
    const cRes: WikiParseResult = cParsePage(pageRawXml.ptr);
    if (cRes.article == null or cRes.article_title == null) {
        // LOG THIS, error ocurred
        return null;
    }
    if (cRes.is_redirect) {
        return null;
    }
    const article: []const u8 = cRes.article[0..cRes.article_size];
    const title: []const u8 = cRes.article_title[0..cRes.article_title_size];

    return .{
        .title = title,
        .article = article,
    };
}

test "Simple Redirect No Content" {
    try std.testing.expect(parsePage("<page> <redirect title=\"blah\" /> <revision><text>#REDIRECT=blah</text></revision> </page>") == null);
}

test "Trivial Correct Page" {
    const correctPage =
        \\<page>
        \\<title>Correct</title>
        \\<ns>0</ns>
        \\<revision>
        \\<text>Some Text!</text>
        \\</revision>
        \\</page>
    ;

    const a_opt = parsePage(correctPage);
    if (a_opt) |a| {
        try std.testing.expectEqualStrings("Correct", a.title);
        try std.testing.expectEqualStrings("Some Text!", a.article);
    } else {
        try std.testing.expect(a_opt != null); // fail
    }
}

test "Invalid XML" {
    const invalidXML =
        \\<page>
        \\<title>Correct</title>
        \\<revision>
        \\<text>Some Text!</text>
        \\</revision
        \\</page>
    ;

    try std.testing.expect(parsePage(invalidXML) == null);
}

test "Page Streaming" {
    const onePage: []const u8 =
        \\<page>
        \\<title>Correct</title>
        \\<revision>
        \\<text>Some Text!</text>
        \\</revision
        \\</page>
    ;
    const threePages: []const u8 = onePage ** 3;

    var fbs = std.io.fixedBufferStream(threePages);
    const r = fbs.reader();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const first = try nextPageAlloc(alloc, r);
    try std.testing.expectEqualStrings(onePage, first[0 .. first.len - 1]);
    try std.testing.expect(first[first.len - 1] == 0);

    const second = try nextPageAlloc(alloc, r);
    try std.testing.expectEqualStrings(onePage, second[0 .. second.len - 1]);
    try std.testing.expect(second[second.len - 1] == 0);

    const third = try nextPageAlloc(alloc, r);
    try std.testing.expectEqualStrings(onePage, third[0 .. third.len - 1]);
    try std.testing.expect(third[third.len - 1] == 0);

    // eof
    const hello = nextPageAlloc(alloc, r);
    try std.testing.expectError(error.EndOfStream, hello);
}
