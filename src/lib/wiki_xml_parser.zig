const std = @import("std");

/// Gets <page>[content]</page> from wikidump stream.
/// Returns `error.EndOfStream` for EOF.
pub fn readPage(reader: anytype, buf: []u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    while (true) {
        const b: u8 = try reader.readByte();
        if (b == '<') {
            var nextBytes: ["page>".len]u8 = undefined;
            _ = try reader.read(&nextBytes);
            if (std.mem.eql(u8, &nextBytes, "page>")) {
                try writer.writeAll("<page>");
                break;
            }
        }
    }

    while (true) {
        const b: u8 = try reader.readByte();
        if (b == '<') {
            var nextBytes: ["/page>".len]u8 = undefined;
            _ = try reader.read(&nextBytes);
            if (std.mem.eql(u8, &nextBytes, "/page>")) {
                // Found closing tag.
                try writer.writeAll("</page>");
                try writer.writeByte(0);
                return fbs.getWritten();
            } else {
                // Tag found, but not </page>.
                try writer.writeByte('<');
                try writer.writeAll(&nextBytes);
            }
        } else {
            // Not '<'.
            try writer.writeByte(b);
        }
    }
}

const c = @cImport(@cInclude("wikixmlparser.h"));

const WikiArticle = struct {
    title: []const u8,
    article: []const u8,
};

/// Extract page content if the page is not a redirect.
/// Takes single <page></page> entry **null terminated**!
pub fn parsePage(pageRawXml: []const u8) ?WikiArticle {
    const res: c.WikiParseResult = c.parsePage(pageRawXml.ptr);
    if (res.article == null or res.article_title == null)
        return null;
    if (res.is_redirect or res.ns != 0)
        return null;
    const article: []const u8 = res.article[0..res.article_size];
    const title: []const u8 = res.article_title[0..res.article_title_size];

    return .{
        .title = title,
        .article = article,
    };
}

test "Simple Redirect No Content" {
    try std.testing.expect(parsePage("<page> <redirect title=\"blah\" /> <title>Redirect to blah</title> <ns>0</ns> <revision><text>#REDIRECT=blah</text></revision> </page>") == null);
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

test "Page Reading" {
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

    var page_buf: [8000]u8 = undefined;

    const first = try readPage(r, &page_buf);
    try std.testing.expectEqualStrings(onePage, first[0 .. first.len - 1]); // drop null byte
    try std.testing.expect(first[first.len - 1] == 0);

    const second = try readPage(r, &page_buf);
    try std.testing.expectEqualStrings(onePage, second[0 .. second.len - 1]);
    try std.testing.expect(second[second.len - 1] == 0);

    const third = try readPage(r, &page_buf);
    try std.testing.expectEqualStrings(onePage, third[0 .. third.len - 1]);
    try std.testing.expect(third[third.len - 1] == 0);

    // eof
    const hello = readPage(r, &page_buf);
    try std.testing.expectError(error.EndOfStream, hello);
}
