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
} || error{InvalidDataCast};

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
                        n.removeChildAndEndList(child);
                        return;
                    }
                }
            }
        }
    }
}

/// Actions that make the AST possible to work with, no logic
///
/// 1. All html tag names and attribute names are lowercased.
///
/// 2. Template names and argument names are lowered.
pub fn cleanAST(n: *MWAstNode) !void {
    std.debug.assert(n.nodeType() == .document);

    try wmp.traverse(n, .html_tag, ?usize, Error, lowerHtmlTagNameAndAttributes, null);
    try wmp.traverse(n, .template, ?usize, Error, lowerTemplateNamesAndArgNames, null);
}

fn lowerHtmlTagNameAndAttributes(n: *MWAstNode, _: ?usize) Error!void {
    const htag = try n.asHtmlTag();

    const nc_tag_name: []u8 = @constCast(htag.tag_name);

    for (nc_tag_name, 0..) |c, i| nc_tag_name[i] = std.ascii.toLower(c);

    var it = htag.attrs.first;
    while (it) |attr| : (it = attr.next) {
        const nc_attr_name: []u8 = @constCast(attr.data.name);

        for (nc_attr_name, 0..) |c, i| nc_attr_name[i] = std.ascii.toLower(c);
    }
}

fn lowerTemplateNamesAndArgNames(n: *MWAstNode, _: ?usize) Error!void {
    const templ = try n.asTemplate();

    const nc_name: []u8 = @constCast(templ.name);
    for (nc_name, 0..) |c, i| nc_name[i] = std.ascii.toLower(c);
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
///
/// If invoked on a non `.document` node it changes that node to text or removes it
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
        .table => unreachable,
        .document => {
            var it = n.first_child;
            while (it) |child| : (it = child.next) {
                try toText(a, child);
            }
        },
    }
}

pub fn renderHtmlTagToMarkdown(n: *wmp.MWAstNode, a: std.mem.Allocator) Error!void {
    if (n.n_children == 0) {
        n.*.n = .{ .text = "" };
        return;
    }

    const eq = std.mem.eql;

    const htag = try n.asHtmlTag();
    const tag_name = htag.tag_name;
    if (eq(u8, "math", tag_name)) {
        // TODO: throw error
        const latex_src = try n.first_child.?.asText();
        const buf_size = latex_src.len + "$$".len;

        const buf = try a.alloc(u8, buf_size);
        var buf_strm = std.io.fixedBufferStream(buf);
        const buf_wr = buf_strm.writer();

        try buf_wr.writeAll("$");
        try buf_wr.writeAll(latex_src);
        try buf_wr.writeAll("$");

        n.*.n = .{ .text = buf };
    } else if (eq(u8, "nowiki", tag_name)) {
        if (n.first_child) |fc| {
            n.*.n = .{ .text = try fc.asText() };
        } else {
            n.*.n = .{ .text = "" };
        }
    } else if (eq(u8, "sup", tag_name) or eq(u8, "sub", tag_name)) {
        var buf_size = "<></>".len + tag_name.len * 2;
        var it = n.first_child;

        while (it) |child| : (it = child.next) {
            try toText(a, child);
            switch (child.n) {
                .text => |txt| buf_size += txt.len,
                else => continue,
            }
        }

        const buf = try a.alloc(u8, buf_size);
        var buf_strm = std.io.fixedBufferStream(buf);
        const buf_wtr = buf_strm.writer();

        try buf_wtr.writeByte('<');
        try buf_wtr.writeAll(tag_name);
        try buf_wtr.writeByte('>');

        while (it) |child| : (it = child.next) {
            switch (child.n) {
                .text => |txt| try buf_wtr.writeAll(txt),
                else => continue,
            }
        }

        try buf_wtr.writeAll("</");
        try buf_wtr.writeAll(tag_name);
        try buf_wtr.writeByte('>');

        n.*.n = .{ .text = buf };
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
        .Main, .Wikitionary => {
            // TODO: log this more efficiently
            //if (n.n_children > 1) {
            //    std.debug.print("Link with {} children\n", .{n.n_children});
            //}

            var buf_size: usize = "[[]]".len + wl.article.len;
            if (wl.namespace == .Wikitionary)
                buf_size += "wikt:".len;

            const caption_arg_node_opt = n.last_child;
            if (caption_arg_node_opt) |caption_arg_node| {
                std.debug.assert(caption_arg_node.n_children > 0);

                buf_size += "|".len;

                var it = caption_arg_node.first_child;
                while (it) |child| : (it = child.next) {
                    try toText(a, child);
                    switch (child.n) {
                        .text => |txt| buf_size += txt.len,
                        else => continue,
                    }
                }
            }

            const buf = try a.alloc(u8, buf_size);
            var buf_strm = std.io.fixedBufferStream(buf);
            const buf_wrtr = buf_strm.writer();

            try buf_wrtr.writeAll("[[");
            if (wl.namespace == .Wikitionary)
                try buf_wrtr.writeAll("wikt:");
            try buf_wrtr.writeAll(wl.article);

            const caption_arg_node_opt2 = n.last_child;
            if (caption_arg_node_opt2) |caption_arg_node| {
                try buf_wrtr.writeByte('|');

                var it = caption_arg_node.first_child;
                while (it) |child| : (it = child.next) {
                    switch (child.n) {
                        .text => |txt| try buf_wrtr.writeAll(txt),
                        else => continue,
                    }
                }
            }

            try buf_wrtr.writeAll("]]");

            n.*.n = .{ .text = buf };
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
        .Image, .File => {
            // TODO: render dummy image with caption.
            n.*.n = .{ .text = "" };
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
