const std = @import("std");

pub const MWNodeType = enum {
    template, // {{}}
    wiki_link, // [[]]
    external_link, // [https://example.com Example] or [https://example.com]
    heading, // like == References ==
    html_tag, // <ref> or other html tags
    html_entity, // i.e. &qout;
    argument, // {{{arg}}} I don't know what this does
    text,
    table, // {|\n ... |}.
};

pub const MWNode = union(MWNodeType) {
    template: []const u8,
    wiki_link: []const u8,
    external_link: ExternalLinkCtx,
    heading: HeadingCtx,
    html_tag: HtmlTagCtx,
    html_entity: []const u8,
    argument: []const u8,
    text: []const u8,
    table: []const u8,
};

pub const ExternalLinkCtx = struct {
    url: []const u8,
    title: ?[]const u8,
};

pub const HeadingCtx = struct {
    heading: []const u8,
    level: usize,
};

pub const HtmlTagCtx = struct {
    pub const HtmlTagAttr = struct {
        name: []const u8,
        value: []const u8,
    };

    tag_name: []const u8,
    text: ?[]const u8,
    attrs: ?[]HtmlTagAttr,
    children: ?[]HtmlTagCtx,
};

pub const MWParser = struct {
    /// Contains list of nodes which will eventually contain parsed information
    nodes: std.ArrayList(MWNode),
    raw_wikitext: []const u8,
    /// This must be arena, ideally wrapping a fixed buffer allocator
    a: std.mem.Allocator,

    const Self = @This();

    pub fn init(a: std.mem.Allocator, wikitext: []const u8) Self {
        return .{
            .nodes = std.ArrayList(MWNode).init(a),
            .raw_wikitext = wikitext,
            .a = a,
        };
    }

    const ParseError = error{
        IncompleteArgument,
        IncompleteHeading,
        IncompleteHtmlEntity,
        UnclosedHtmlComment,
        InvalidHtmlTag,
    };

    /// iterates through characters and dispatches to node specific parsing functions
    ///
    /// HTML entities `&lt;` and `&gt;` must be replaced with `<` and `>` to be interpreted as html tags.
    ///
    /// anything starting with `&` is assumed to be an HTML entity. Use `&amp;` instead.
    pub fn parse(self: *Self) !void {
        var i: usize = 0;
        var cur_text_node = self.raw_wikitext;
        cur_text_node.len = 0;
        while (i < self.raw_wikitext.len) {
            const ch = self.raw_wikitext[i];
            switch (ch) {
                // could be a tag or an argument or just text
                '{' => {
                    if (nextEql(self.raw_wikitext, "{{{", i)) {
                        if (cur_text_node.len > 0) {
                            try self.nodes.append(.{ .text = cur_text_node });
                        }

                        i = try self.parseArgument(i);

                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
                        // we don't increment i becuase parseArgument already did
                    } else if (nextEql(self.raw_wikitext, "{{", i)) {
                        // dispatch to template parser
                        i += 1;
                    } else if (nextEql(self.raw_wikitext, "{|", i)) {
                        // table
                        i += 1;
                    } else {
                        cur_text_node.len += 1;
                        i += 1;
                    }
                },

                // wikilink or external link
                '[' => {
                    if (nextEql(self.raw_wikitext, "[[", i)) {
                        // wikilink
                    } else {
                        // external link
                    }
                },

                '<' => {
                    if (cur_text_node.len > 0) {
                        try self.nodes.append(.{ .text = cur_text_node });
                    }

                    if (nextEql(self.raw_wikitext, "!--", i + 1)) {
                        i = try self.skipHtmlComment(i + "<!--".len);
                    } else {
                        i = try self.parseHtmlTag(i);
                    }

                    cur_text_node = self.raw_wikitext[i..];
                    cur_text_node.len = 0;
                },

                // html entity
                '&' => {
                    if (cur_text_node.len > 0) {
                        try self.nodes.append(.{ .text = cur_text_node });
                    }

                    i = try self.parseHtmlEntity(i);

                    cur_text_node = self.raw_wikitext[i..];
                    cur_text_node.len = 0;
                },

                // headings
                '=' => {
                    // article or line start with an equals is expected to be a heading
                    if (i == 0 or (i > 0 and self.raw_wikitext[i - 1] == '\n')) {
                        if (cur_text_node.len > 0) {
                            try self.nodes.append(.{ .text = cur_text_node });
                        }
                        i = try self.parseHeading(i);
                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
                    } else {
                        cur_text_node.len += 1;
                        i += 1;
                    }
                },

                // continue adding to text node
                else => {
                    cur_text_node.len += 1;
                    i += 1;
                },
            }
        }

        if (cur_text_node.len > 0) {
            try self.nodes.append(.{ .text = cur_text_node });
        }
    }

    /// **Internal WIP**
    ///
    /// `i` should point to the opening `<`
    ///
    /// TODO: handle nesting. Errors right now!
    fn parseHtmlTag(self: *Self, start: usize) !usize {
        var i = try advance(start, "<".len, self.raw_wikitext);
        if (isWhiteSpace(self.raw_wikitext[i]))
            return ParseError.InvalidHtmlTag;

        const tag_name_start = i;
        i = skip(self.raw_wikitext, node_name_pred, i) orelse return ParseError.InvalidHtmlTag;
        if (i == tag_name_start)
            return ParseError.InvalidHtmlTag;
        const tag_name = self.raw_wikitext[tag_name_start..i];

        i = skip(self.raw_wikitext, whitespace_pred, i) orelse return ParseError.InvalidHtmlTag;

        // attempt to find attributes
        var attrs = std.ArrayList(HtmlTagCtx.HtmlTagAttr).init(self.a);
        while (attribute_name_pred(self.raw_wikitext[i])) {
            if (i >= self.raw_wikitext.len)
                return ParseError.InvalidHtmlTag;

            // extract attr name
            const attr_name_start = i;
            i = skip(self.raw_wikitext, attribute_name_pred, i) orelse return ParseError.InvalidHtmlTag;
            if (attr_name_start == i)
                return ParseError.InvalidHtmlTag;
            const attr_name = self.raw_wikitext[attr_name_start..i];

            // skip whitespace after attr name
            i = skip(self.raw_wikitext, whitespace_pred, i) orelse return ParseError.InvalidHtmlTag;

            // skip '='
            if (self.raw_wikitext[i] != '=')
                return ParseError.InvalidHtmlTag;
            i = try advance(i, "=".len, self.raw_wikitext);

            // skip whitespace after =
            i = skip(self.raw_wikitext, whitespace_pred, i) orelse return ParseError.InvalidHtmlTag;

            // skip quote and remember if it was ' or "
            const quote = self.raw_wikitext[i];
            if (i + 1 == self.raw_wikitext.len or (quote != '\'' and quote != '"'))
                return ParseError.InvalidHtmlTag;
            i = try advance(i, 1, self.raw_wikitext);

            // get attr value
            const attr_value_start = i;
            switch (quote) {
                '\'' => i = skip(self.raw_wikitext, attribute_value_single_quote_pred, i) orelse return ParseError.InvalidHtmlTag,
                '"' => i = skip(self.raw_wikitext, attribute_value_double_quote_pred, i) orelse return ParseError.InvalidHtmlTag,
                else => unreachable,
            }
            const attr_value = self.raw_wikitext[attr_value_start..i];

            // skip last quote
            i = try advance(i, 1, self.raw_wikitext);

            try attrs.append(.{ .name = attr_name, .value = attr_value });

            // skip whitespace after attr name
            i = skip(self.raw_wikitext, whitespace_pred, i) orelse return ParseError.InvalidHtmlTag;
        }
        if (i + 1 >= self.raw_wikitext.len)
            return ParseError.InvalidHtmlTag;

        // Handle self closing tag
        if (self.raw_wikitext[i] == '/') {
            if (self.raw_wikitext[i + 1] != '>') {
                return ParseError.InvalidHtmlTag;
            }
            if (attrs.items.len > 0) {
                try self.nodes.append(.{ .html_tag = .{
                    .tag_name = tag_name,
                    .text = null,
                    .children = null,
                    .attrs = try attrs.toOwnedSlice(),
                } });
            } else {
                try self.nodes.append(.{ .html_tag = .{
                    .tag_name = tag_name,
                    .text = null,
                    .children = null,
                    .attrs = null,
                } });
            }
            return try advance(i, "/>".len, self.raw_wikitext);
        }

        // skip closing '>'
        if (self.raw_wikitext[i] != '>')
            return ParseError.InvalidHtmlTag;
        i = try advance(i, 1, self.raw_wikitext);

        const content_start = i;

        while (i < self.raw_wikitext.len) : (i += 1) {
            const ch = self.raw_wikitext[i];
            switch (ch) {
                '<' => {
                    // end content
                    const content_end = i;

                    // skip '>'
                    i = try advance(i, 1, self.raw_wikitext);
                    if (self.raw_wikitext[i] != '/')
                        return ParseError.InvalidHtmlTag;
                    // skip '/'
                    i = try advance(i, 1, self.raw_wikitext);

                    // get close tag name
                    const close_tag_name_start = i;
                    i = skip(self.raw_wikitext, node_name_pred, i) orelse return ParseError.InvalidHtmlTag;
                    const close_tag_name = self.raw_wikitext[close_tag_name_start..i];

                    // validate
                    if (!std.mem.eql(u8, close_tag_name, tag_name))
                        return ParseError.InvalidHtmlTag;

                    i = skip(self.raw_wikitext, whitespace_pred, i) orelse return ParseError.InvalidHtmlTag;
                    if (self.raw_wikitext[i] != '>')
                        return ParseError.InvalidHtmlTag;

                    if (attrs.items.len == 0) {
                        try self.nodes.append(.{ .html_tag = .{
                            .tag_name = tag_name,
                            .text = self.raw_wikitext[content_start..content_end],
                            .attrs = null,
                            .children = null,
                        } });
                    } else {
                        try self.nodes.append(.{ .html_tag = .{
                            .tag_name = tag_name,
                            .text = self.raw_wikitext[content_start..content_end],
                            .attrs = try attrs.toOwnedSlice(),
                            .children = null,
                        } });
                    }

                    return i + 1;
                },
                else => {},
            }
        }

        return ParseError.InvalidHtmlTag;
    }

    /// moves to i to after the comment,
    /// or returns `ParseError.UnclosedHtmlComment` if none is found
    fn skipHtmlComment(self: *Self, start: usize) !usize {
        var i = start;
        while (i < self.raw_wikitext.len) : (i += 1) {
            const ch = self.raw_wikitext[i];
            if (ch == '-') {
                if (nextEql(self.raw_wikitext, "-->", i)) {
                    return i + "-->".len;
                }
            }
        }
        return ParseError.UnclosedHtmlComment;
    }

    /// attempts to find html entity from '&' start character
    ///
    /// Returns `null` if not found
    fn parseHtmlEntity(self: *Self, start: usize) !usize {
        var i: usize = start + 1;

        if (self.raw_wikitext[i] == '#') {
            i += 1;
            // numeric, at least 2-4 digits
            var n_digits: usize = 0;
            while (i < self.raw_wikitext.len) : (i += 1) {
                const ch = self.raw_wikitext[i];
                if (ch == ';') {
                    if (2 <= n_digits and n_digits <= 4) {
                        try self.nodes.append(.{ .html_entity = self.raw_wikitext[start .. i + 1] });
                        return i + 1;
                    } else {
                        return ParseError.IncompleteHtmlEntity;
                    }
                }

                if (ch < 48 or ch > 57) {
                    return ParseError.IncompleteHtmlEntity;
                } else {
                    n_digits += 1;
                }
            }
        } else {
            while (i < self.raw_wikitext.len) : (i += 1) {
                const ch = self.raw_wikitext[i];
                if (ch == ';') {
                    try self.nodes.append(.{ .html_entity = self.raw_wikitext[start .. i + 1] });
                    return i + 1;
                }
            }
        }

        return ParseError.IncompleteHtmlEntity;
    }

    fn parseHeading(self: *Self, start: usize) !usize {
        var i: usize = start;
        var level: usize = 0;
        while (i < self.raw_wikitext.len) : (i += 1) {
            const ch = self.raw_wikitext[i];
            switch (ch) {
                '=' => level += 1,
                '\n' => return ParseError.IncompleteHeading,
                else => break,
            }
        }
        if (i == self.raw_wikitext.len) {
            return ParseError.IncompleteHeading;
        }

        const text_start = i; // we assume one space
        var text_size: usize = 0;
        while (i < self.raw_wikitext.len) : (i += 1) {
            const ch = self.raw_wikitext[i];
            switch (ch) {
                '=' => break,
                '\n' => return ParseError.IncompleteHeading,
                else => text_size += 1,
            }
        }
        if (i == self.raw_wikitext.len) {
            return ParseError.IncompleteHeading;
        }

        var _level = level;

        while (i < self.raw_wikitext.len) : (i += 1) {
            if (_level == 0) { // avoid overflow
                break;
            }

            const ch = self.raw_wikitext[i];
            switch (ch) {
                '=' => _level -= 1,
                else => break,
            }
        }
        if (i == self.raw_wikitext.len or _level != 0) {
            return ParseError.IncompleteHeading;
        }
        if (self.raw_wikitext[i] != '\n') {
            return ParseError.IncompleteHeading;
        }

        try self.nodes.append(.{ .heading = .{ .heading = self.raw_wikitext[text_start .. text_start + text_size], .level = level } });

        return i + 1; // push past newline
    }

    /// Returns size of the node
    ///
    /// Does not handle nesting!
    ///
    /// Returns `ParseError.IncompleteArgument` if unclosed
    fn parseArgument(self: *Self, start: usize) !usize {
        var i: usize = start + "{{{".len;
        while (i < self.raw_wikitext.len) {
            const ch = self.raw_wikitext[i];

            if (ch == '}') {
                if (nextEql(self.raw_wikitext, "}}}", i)) {
                    const end = i + "}}}".len;
                    const text = self.raw_wikitext[start..end];
                    try self.nodes.append(.{ .argument = text });
                    return end;
                }
            }

            i += 1;
        }

        return ParseError.IncompleteArgument;
    }
};

/// Advances `i` until `continue_pred` returns false
///
/// If end of `buf` is reached, returns `null`
///
/// Predicate calls are inlined for performance
fn skip(buf: []const u8, continue_pred: fn (u8) bool, _i: usize) ?usize {
    var i = _i;
    while (i < buf.len) : (i += 1) {
        if (!@call(.always_inline, continue_pred, .{buf[i]})) {
            return i;
        }
    }
    return null;
}

/// Stops on ' ', '\n', '\r', '\t', '/', '>', '?', '\0'
fn node_name_pred(ch: u8) bool {
    switch (ch) {
        ' ', '\n', '\r', '\t', '/', '>', '?', 0 => return false,
        else => return true,
    }
}

/// Continues on ' ', '\t', '\n', '\r'
fn whitespace_pred(ch: u8) bool {
    switch (ch) {
        ' ', '\t', '\n', '\r' => return true,
        else => return false,
    }
}

/// Stops on ' ', '\n', '\r', '\t', '/', '>', '?', '\0', '='
fn attribute_name_pred(ch: u8) bool {
    switch (ch) {
        ' ', '\n', '\r', '\t', '/', '>', '?', 0, '=' => return false,
        else => return true,
    }
}

/// Stops on '\''
fn attribute_value_single_quote_pred(ch: u8) bool {
    return ch != '\'';
}

/// Stops on '"'
fn attribute_value_double_quote_pred(ch: u8) bool {
    return ch != '"';
}

const AdvanceError = error{AdvanceBeyondBuffer};
/// Safely advance buffer index `i` by count
///
/// Returns `error.AdvanceBeyondBuffer` if i+count goes out of bounds
inline fn advance(i: usize, count: usize, buf: []const u8) !usize {
    if (i + count < buf.len) {
        return i + count;
    } else {
        return AdvanceError.AdvanceBeyondBuffer;
    }
}

inline fn isWhiteSpace(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r';
}

/// advance to the first non whitespace
///
/// **`\n` and `\r` are considered whitespace**
inline fn skipWhitespace(buf: []const u8, i: usize) ?usize {
    while (i < buf.len) : (i += 1) {
        switch (buf[i]) {
            ' ', '\t', '\n', '\r' => continue,
            else => return i,
        }
    }

    return null;
}

/// returns `true` if the needle is present starting at i.
///
/// `false` if out of bounds
inline fn nextEql(buf: []const u8, needle: []const u8, i: usize) bool {
    if (i + needle.len <= buf.len) {
        return std.mem.eql(u8, buf[i..][0..needle.len], needle);
    }
    return false;
}

test "Trivial nextEql" {
    const wikitext =
        \\{{{arg}}
        \\
    ;
    try std.testing.expect(nextEql(wikitext, "{{{", 0));
    try std.testing.expect(nextEql(wikitext, "}}\n", 6));
    try std.testing.expect(!nextEql(wikitext, "{{{", 7));
}

test "Errors on unclosed Argument" {
    const wikitext =
        \\{{{arg}}
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);

    const e = wp.parse();
    try std.testing.expectError(MWParser.ParseError.IncompleteArgument, e);
}

test "Parses Well Formed Argument With Some Text" {
    const wikitext =
        \\Blah Blah Text{{{arg}}}
        \\Some more text
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 3);

    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[0]), "text");
    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[1]), "argument");
    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[2]), "text");

    switch (wp.nodes.items[0]) {
        .text => |text| try std.testing.expectEqualStrings("Blah Blah Text", text),
        else => unreachable,
    }

    switch (wp.nodes.items[1]) {
        .argument => |text| try std.testing.expectEqualStrings("{{{arg}}}", text),
        else => unreachable,
    }

    switch (wp.nodes.items[2]) {
        .text => |text| try std.testing.expectEqualStrings("\nSome more text\n", text),
        else => unreachable,
    }
}

test "Rejects Various Malformed Headings" {
    const unclosed1: []const u8 =
        \\== Anarchism
        \\
    ;
    const unclosed2: []const u8 =
        \\== Anarchism=
        \\
    ;
    const overclosed: []const u8 =
        \\== Anarchism===
        \\
    ;
    const bad_line_break: []const u8 =
        \\== Anarchism
        \\==
        \\
    ;
    const wierd: []const u8 =
        \\= = =
        \\
    ;
    const cases = [_][]const u8{ unclosed1, unclosed2, overclosed, bad_line_break, wierd };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var wp = MWParser.init(a, case);
        const e = wp.parse();
        try std.testing.expectError(MWParser.ParseError.IncompleteHeading, e);
    }
}

test "Parses Well Formed Heading With Some Text" {
    const wikitext =
        \\= Blah Blah Blah =
        \\Blah Blah Blah
        \\Some more Blah
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 2);

    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[0]), "heading");
    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[1]), "text");

    switch (wp.nodes.items[0]) {
        .heading => |h| {
            try std.testing.expectEqualStrings(" Blah Blah Blah ", h.heading);
            try std.testing.expect(h.level == 1);
        },
        else => unreachable,
    }

    switch (wp.nodes.items[1]) {
        .text => |text| try std.testing.expectEqualStrings("Blah Blah Blah\nSome more Blah\n", text),
        else => unreachable,
    }
}

test "Rejects various malformed html entities" {
    const non_numerical_num: []const u8 = "&#hello;";
    const too_many_digits: []const u8 = "&#12345;";
    const too_few_digits: []const u8 = "&#1;";
    const unclosed: []const u8 = "&hello";

    const cases = [_][]const u8{ non_numerical_num, too_many_digits, too_few_digits, unclosed };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var wp = MWParser.init(a, case);
        const e = wp.parse();
        try std.testing.expectError(MWParser.ParseError.IncompleteHtmlEntity, e);
    }
}

test "Correctly Parses HTML Entity" {
    const big_num: []const u8 = "&#1234;";
    const sm_num: []const u8 = "&#11;";
    const s_one: []const u8 = "&hello;";
    const s_two: []const u8 = "&quot;";

    const entities = [_][]const u8{ big_num, sm_num, s_one, s_two };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, big_num ++ sm_num ++ s_one ++ s_two);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 4);
    for (0..4) |i| {
        switch (wp.nodes.items[i]) {
            .html_entity => |he| try std.testing.expectEqualStrings(entities[i], he),
            else => unreachable,
        }
    }
}

test "Errors on unclosed html comment" {
    const wikitext = "<!-- Blah --";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    const e = wp.parse();

    try std.testing.expectError(MWParser.ParseError.UnclosedHtmlComment, e);
}

test "Skips HTML Comment" {
    const wikitext = "<!-- Blah Blah -->";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();
}

test "Parses Well Formed Heading With Some Text and a Comment" {
    const wikitext =
        \\= Blah Blah Blah =
        \\Blah <!-- Blah Blah --> Blah Blah
        \\Some more Blah
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 3);

    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[0]), "heading");
    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[1]), "text");
    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[2]), "text");

    switch (wp.nodes.items[0]) {
        .heading => |h| {
            try std.testing.expectEqualStrings(" Blah Blah Blah ", h.heading);
            try std.testing.expect(h.level == 1);
        },
        else => unreachable,
    }

    switch (wp.nodes.items[1]) {
        .text => |text| try std.testing.expectEqualStrings("Blah ", text),
        else => unreachable,
    }

    switch (wp.nodes.items[2]) {
        .text => |text| try std.testing.expectEqualStrings(" Blah Blah\nSome more Blah\n", text),
        else => unreachable,
    }
}

test "HTML Tag Trivial Correct" {
    const wikitext = "<ref>Hello</ref>";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);

    switch (wp.nodes.items[0]) {
        .html_tag => |t| {
            try std.testing.expectEqualStrings("ref", t.tag_name);
            try std.testing.expectEqualStrings("Hello", t.text.?);
        },
        else => unreachable,
    }
}

test "HTML Tag Wierd Spacing" {
    const case1: []const u8 = "<ref>Hello</ref>";
    const case2: []const u8 =
        \\<ref   >Hello</ref>
    ;
    const case3: []const u8 =
        \\<ref   >Hello</ref   >
    ;
    const case4: []const u8 =
        \\<ref   
        \\  >Hello</ref   
        \\>
    ;
    const case5: []const u8 =
        \\<ref       
        \\  >Hello</ref   
        \\>
    ;

    const cases = [_][]const u8{ case1, case2, case3, case4, case5 };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var wp = MWParser.init(a, case);
        try wp.parse();

        try std.testing.expect(wp.nodes.items.len == 1);

        switch (wp.nodes.items[0]) {
            .html_tag => |t| {
                try std.testing.expectEqualStrings("ref", t.tag_name);
                try std.testing.expectEqualStrings("Hello", t.text.?);
            },
            else => unreachable,
        }
    }
}

test "Decodes HTML Tag Attributes Correctly" {
    const wikitext = "<ref kind='web'>citation</ref>";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    switch (wp.nodes.items[0]) {
        .html_tag => |t| {
            try std.testing.expect(t.attrs.?.len == 1);
            try std.testing.expectEqualStrings("kind", t.attrs.?[0].name);
            try std.testing.expectEqualStrings("web", t.attrs.?[0].value);
            try std.testing.expectEqualStrings("ref", t.tag_name);
            try std.testing.expectEqualStrings("citation", t.text.?);
        },
        else => unreachable,
    }
}
