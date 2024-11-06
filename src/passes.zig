const std = @import("std");
const wmp = @import("MediaWikiParser.zig");
const MWAstNode = wmp.MWAstNode;
const tracing = @import("tracing.zig");

///////////////////////////////////////////////////////////////////////
// Ast Passes.

pub const Error = error{
    SpuriousArgumentNode,

    OutOfMemory,
    NoSpaceLeft,
} || wmp.Error;

pub fn removeReferences(n: *MWAstNode) !void {
    std.debug.assert(n.nodeType() == .document);

    var it = n.first_child;
    while (it) |child| : (it = child.next) {
        if (child.nodeType() == .heading) {
            const h = try child.asHeading();
            if (h.level != 2)
                continue;
            if (child.first_child) |fc| {
                if (fc.nodeType() == .text) {
                    if (std.mem.eql(u8, (try fc.asText()), "References")) {
                        // TODO: safety check
                        const prev = child.prev.?;
                        // TODO: accurately update n_children
                        n.last_child = prev;
                        prev.next = null;
                    }
                }
            }
        }
    }
}

pub fn textSize(n: *MWAstNode) !usize {
    std.debug.assert(n.nodeType() == .document);

    var sz: usize = 0;

    var it = n.first_child;
    while (it) |child| : (it = child.next) {
        sz += (try child.asText()).len;
    }

    return sz;
}

pub fn writeText(n: *MWAstNode, writer: anytype) !void {
    std.debug.assert(n.nodeType() == .document);

    var it = n.first_child;
    while (it) |child| : (it = child.next) {
        try writer.writeAll(try child.asText());
    }
}

/// Traverses AST and replaces node with markdown text
pub fn toText(a: std.mem.Allocator, n: *MWAstNode) Error!void {
    switch (n.n) {
        .template => try renderTemplateToMarkdown(n, a),
        .wiki_link => try renderWikiLinkToMarkdown(n, a),
        .external_link => try renderExternalLinkToMarkdown(n, a),
        .heading => try renderHeadingToMarkdown(n, a),
        .html_tag => try renderHtmlTagToMarkdown(n, a),
        .html_entity => try renderHtmlEntity(n, a),
        .argument => return Error.SpuriousArgumentNode,
        .text => return,
        .table => return,
        .document => {
            var it = n.first_child;
            while (it) |child| : (it = child.next) {
                try toText(a, child);
            }
        },
    }
}

pub fn renderHtmlTagToMarkdown(n: *wmp.MWAstNode, a: std.mem.Allocator) Error!void {
    const htag = try n.asHtmlTag();
    if (std.mem.eql(u8, "math", htag.tag_name)) {
        // TODO: throw error
        const latex_src = try n.first_child.?.asText();
        const text_size = latex_src.len + "$$".len * 2;

        const text = try a.alloc(u8, text_size);
        var text_strm = std.io.fixedBufferStream(text);
        const text_wr = text_strm.writer();

        try text_wr.writeAll("$$");
        try text_wr.writeAll(latex_src);
        try text_wr.writeAll("$$");

        n.*.n = .{ .text = text };
    } else if (std.mem.eql(u8, "nowiki", htag.tag_name)) {
        if (n.first_child) |fc| {
            n.*.n = .{ .text = try fc.asText() };
        } else {
            // TODO log this
            n.*.n = .{ .text = "" };
        }
    } else {
        n.*.n = .{ .text = "" };
    }
}

pub fn renderHtmlEntity(n: *wmp.MWAstNode, a: std.mem.Allocator) Error!void {
    _ = a;
    n.*.n = .{ .text = try n.asHtmlEntity() };
}

pub fn renderTemplateToMarkdown(n: *wmp.MWAstNode, a: std.mem.Allocator) Error!void {
    _ = a;
    n.*.n = .{ .text = "" };
}

pub fn renderExternalLinkToMarkdown(n: *wmp.MWAstNode, a: std.mem.Allocator) Error!void {
    const el = try n.asExternalLink();

    if (el.title) |title| {
        const link_size = "[]()".len + el.url.len + title.len;
        const link_buf = try a.alloc(u8, link_size);

        var link_buf_stream = std.io.fixedBufferStream(link_buf);
        const link_buf_writer = link_buf_stream.writer();

        try link_buf_writer.writeByte('[');
        try link_buf_writer.writeAll(title);
        try link_buf_writer.writeByte(']');

        try link_buf_writer.writeByte('(');
        try link_buf_writer.writeAll(el.url);
        try link_buf_writer.writeByte(')');

        n.*.n = .{ .text = link_buf };
    } else {
        n.*.n = .{ .text = el.url };
    }
}

pub fn renderWikiLinkToMarkdown(n: *wmp.MWAstNode, a: std.mem.Allocator) Error!void {
    const wl = try n.asWikiLink();

    switch (wl.namespace) {
        .Main => {
            var link_name_size: usize = 0;

            if (n.n_children > 1) {
                std.debug.print("Link with {} children\n", .{n.n_children});
            }

            const caption_arg_node_opt = n.last_child;
            if (caption_arg_node_opt) |caption_arg_node| {
                var it = caption_arg_node.first_child;
                while (it) |child| : (it = child.next) {
                    if (child.nodeType() == .text) {
                        link_name_size += (try child.asText()).len;
                    } else {
                        if (child.nodeType() == .html_tag) {
                            std.debug.print("<{s}>\n", .{(try child.asHtmlTag()).tag_name});
                        } else {
                            std.debug.print("Child of type {s} under caption arg\n", .{child.nodeTypeStr()});
                        }
                    }
                }
            }

            const link_buf = try a.alloc(u8, wl.article.len + link_name_size + "[](/)".len);
            var link_buf_stream = std.io.fixedBufferStream(link_buf);
            const link_buf_writer = link_buf_stream.writer();

            try link_buf_writer.writeByte('[');
            if (link_name_size != 0) {
                var it = n.last_child.?.first_child;
                while (it) |child| : (it = child.next) {
                    if (child.nodeType() == .text)
                        try link_buf_writer.writeAll(try child.asText());
                }
            }
            try link_buf_writer.writeAll("](");
            try link_buf_writer.writeByte('/');
            try link_buf_writer.writeAll(wl.article);
            try link_buf_writer.writeByte(')');

            std.mem.replaceScalar(u8, link_buf["[](/".len + link_name_size ..], ' ', '_');

            n.*.n = .{ .text = link_buf };
        },
        .Image, .File => {
            // TODO: render dummy image with caption.
            n.*.n = .{ .text = "" };
        },
        .Wikitionary => {
            const wikitionary_base: []const u8 = "https://en.wikitionary.org/wiki/";
            const link_buf_size = "[".len + wl.article.len + "]".len + "(".len + wikitionary_base.len + wl.article.len + ")".len;

            const link_buf = try a.alloc(u8, link_buf_size);
            var link_buf_stream = std.io.fixedBufferStream(link_buf);
            const link_buf_writer = link_buf_stream.writer();

            try link_buf_writer.writeByte('[');
            try link_buf_writer.writeAll(wl.article);
            try link_buf_writer.writeByte(']');

            try link_buf_writer.writeByte('(');
            try link_buf_writer.writeAll(wikitionary_base);
            try link_buf_writer.writeAll(wl.article);
            try link_buf_writer.writeByte(')');

            n.*.n = .{ .text = link_buf };
        },
        .Unknown => {
            const link_buf_size = wl.article.len + "[](/bad)".len;

            const link_buf = try a.alloc(u8, link_buf_size);
            var link_buf_stream = std.io.fixedBufferStream(link_buf);
            const link_buf_writer = link_buf_stream.writer();

            try link_buf_writer.writeByte('[');
            try link_buf_writer.writeAll(wl.article);
            try link_buf_writer.writeByte(']');
            try link_buf_writer.writeAll("(/bad)");

            n.*.n = .{ .text = link_buf };
        },
    }
}

/// must be called with `traverse`
pub fn renderHeadingToMarkdown(n: *wmp.MWAstNode, a: std.mem.Allocator) Error!void {
    const h = try n.asHeading();

    const markdown_overhead = "#".len * (h.level + 1) + " ".len + "\n".len;

    var text_size = markdown_overhead;

    var it = n.first_child;
    while (it) |node| : (it = node.next) {
        if (node.nodeType() == .text)
            text_size += (try node.asText()).len;
    }

    const rendered_heading = try a.alloc(u8, text_size);
    var rh_buffered_stream = std.io.fixedBufferStream(rendered_heading);
    const rh_writer = rh_buffered_stream.writer();

    for (0..h.level + 1) |_| {
        try rh_writer.writeByte('#');
    }
    try rh_writer.writeByte(' ');

    it = n.first_child;
    while (it) |node| : (it = node.next) {
        if (node.nodeType() == .text)
            try rh_writer.writeAll(try node.asText());
    }
    try rh_writer.writeByte('\n');

    n.*.n = .{ .text = rendered_heading };
}

///////////////////////////////////////////////////////////////////////
// Ast Pass Tests.

test "TO_STR_HEADING converts to markdown" {
    const wikitext =
        \\= Blah Blah Blah =
        \\Blah Blah Blah
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try wmp.parseDocument(a, wikitext, tracing.TestTrace(wmp.Error){});

    try std.testing.expect(doc.n_children == 2);

    try wmp.traverse(&doc, .heading, std.mem.Allocator, renderHeadingToMarkdown, a);

    const heading_text = try doc.first_child.?.asText();
    try std.testing.expectEqualStrings("## Blah Blah Blah\n", heading_text);
}

test "TO_STR_WIKILINK no title" {
    const wikitext = "[[Index of Andorra-related articles]]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try wmp.parseDocument(a, wikitext, tracing.TestTrace(wmp.Error){});
    try std.testing.expect(doc.n_children == 1);

    try wmp.traverse(&doc, .wiki_link, std.mem.Allocator, renderWikiLinkToMarkdown, a);

    const link_text = try doc.first_child.?.asText();
    try std.testing.expectEqualStrings("[](/Index_of_Andorra-related_articles)", link_text);
}

test "TO_STR_WIKILINK title" {
    const wikitext = "[[Andorra-Spain border|Spanish border]]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try wmp.parseDocument(a, wikitext, tracing.TestTrace(wmp.Error){});

    try std.testing.expect(doc.n_children == 1);

    try wmp.traverse(&doc, .wiki_link, std.mem.Allocator, renderWikiLinkToMarkdown, a);

    const link_text = try doc.first_child.?.asText();
    try std.testing.expectEqualStrings("[Spanish border](/Andorra-Spain_border)", link_text);
}

test "TO_STR_WIKILINK wikitionary namespace" {
    const wikitext = "[[wikt:phantasm|phantasm]]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try wmp.parseDocument(a, wikitext, tracing.TestTrace(wmp.Error){});
    try std.testing.expect(doc.n_children == 1);

    try wmp.traverse(&doc, .wiki_link, std.mem.Allocator, renderWikiLinkToMarkdown, a);

    const link_text = try doc.first_child.?.asText();
    try std.testing.expectEqualStrings("[phantasm](https://en.wikitionary.org/wiki/phantasm)", link_text);
}
