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
    template: TemplateCtx,
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

pub const TemplateCtx = struct {
    pub const TemplateArg = struct {
        key: ?[]const u8,
        value: []const u8,
    };

    name: []const u8,
    args: std.DoublyLinkedList(TemplateArg) = std.DoublyLinkedList(TemplateArg){},
    children: std.DoublyLinkedList(TemplateCtx) = std.DoublyLinkedList(TemplateCtx){},
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
        BadExternalLink,
        IncompleteTable,
        BadTemplate,
    };

    /// iterates through characters and dispatches to node specific parsing functions
    ///
    /// HTML entities `&lt;` and `&gt;` must be replaced with `<` and `>` to be interpreted as html tags.
    ///
    /// anything starting with `&` is assumed to be an HTML entity. Use `&amp;` instead.
    ///
    /// All carriage returns, '\r', will be interpreted as text. Remove them before using.
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
                        if (cur_text_node.len > 0)
                            try self.nodes.append(.{ .text = cur_text_node });

                        i = try self.parseArgument(i);

                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
                    } else if (nextEql(self.raw_wikitext, "{{", i)) {
                        if (cur_text_node.len > 0)
                            try self.nodes.append(.{ .text = cur_text_node });

                        const res = try self.parseTemplate(i);
                        try self.nodes.append(.{ .template = res.t_ctx });
                        i += res.offset;

                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
                    } else if (nextEql(self.raw_wikitext, "{|", i)) {
                        if (cur_text_node.len > 0)
                            try self.nodes.append(.{ .text = cur_text_node });

                        i = try self.parseTable(i);

                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
                    } else {
                        cur_text_node.len += 1;
                        i += 1;
                    }
                },

                // wikilink or external link
                '[' => {
                    if (nextEql(self.raw_wikitext, "[[", i)) {
                        cur_text_node.len += 1;
                        i += 1;
                    } else {
                        if (cur_text_node.len > 0)
                            try self.nodes.append(.{ .text = cur_text_node });

                        i = try self.parseExternalLink(i);

                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
                    }
                },

                '<' => {
                    if (cur_text_node.len > 0)
                        try self.nodes.append(.{ .text = cur_text_node });

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
                    if (cur_text_node.len > 0)
                        try self.nodes.append(.{ .text = cur_text_node });

                    i = try self.parseHtmlEntity(i);

                    cur_text_node = self.raw_wikitext[i..];
                    cur_text_node.len = 0;
                },

                // headings
                '=' => {
                    // article or line start with an equals is expected to be a heading
                    if (i == 0 or (i > 0 and self.raw_wikitext[i - 1] == '\n')) {
                        if (cur_text_node.len > 0)
                            try self.nodes.append(.{ .text = cur_text_node });

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

        if (cur_text_node.len > 0)
            try self.nodes.append(.{ .text = cur_text_node });
    }

    fn parseTemplate(self: *Self, start: usize) !struct { offset: usize, t_ctx: TemplateCtx } {
        const FAIL = ParseError.BadTemplate;

        const template_name_pred = struct {
            /// stop on '\n', '}', '|'
            pub fn tnp(ch: u8) bool {
                switch (ch) {
                    '\n', '}', '|' => return false,
                    else => return true,
                }
            }
        }.tnp;

        var i = start + "{{".len;

        // get template name
        const template_name_start = i;
        i = try skip(self.raw_wikitext, template_name_pred, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);
        const template_name = self.raw_wikitext[template_name_start..i];

        // skip whitespace after template name
        i = try skip(self.raw_wikitext, single_line_whitespace_pred, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);

        // if template closes, return it
        if (nextEql(self.raw_wikitext, "}}", i)) {
            return .{
                .offset = i + "}}".len,
                .t_ctx = .{ .name = template_name },
            };
        }

        const arg_first_pred = struct {
            /// stop on '\n', '=', '{', '}'
            pub fn afp(ch: u8) bool {
                switch (ch) {
                    '\n', '=', '{', '}' => return false,
                    else => return true,
                }
            }
        }.afp;

        // if args exist to parse, parse them
        if (self.raw_wikitext[i] == '|') {
            i += "|".len;

            const TL = std.DoublyLinkedList(TemplateCtx.TemplateArg);
            var args = TL{};
            const CL = std.DoublyLinkedList(TemplateCtx);
            var children = CL{};
            while (i < self.raw_wikitext.len) {
                const arg_start = i;

                i = try skip(self.raw_wikitext, arg_first_pred, i, FAIL);

                switch (self.raw_wikitext[i]) {
                    '=' => return FAIL,
                    '{' => {
                        if (nextEql(self.raw_wikitext, "{{", i)) {
                            const res = try self.parseTemplate(i);
                            const child = try self.a.create(CL.Node);
                            child.* = .{ .data = res.t_ctx };
                            children.append(child);
                            i = res.offset;
                        } else {
                            return FAIL;
                        }
                    },
                    '}' => {
                        if (nextEql(self.raw_wikitext, "}}", i)) {
                            if (arg_start == i) {
                                return .{
                                    .offset = i + "}}".len,
                                    .t_ctx = .{ .name = template_name, .args = args, .children = children },
                                };
                            }

                            const arg = try self.a.create(TL.Node);
                            arg.*.data = .{
                                .key = null,
                                .value = self.raw_wikitext[arg_start..i],
                            };
                            args.append(arg);

                            return .{
                                .offset = i + "}}".len,
                                .t_ctx = .{ .name = template_name, .args = args, .children = children },
                            };
                        } else {
                            return FAIL;
                        }
                    },
                    '\n' => return FAIL,
                    else => return FAIL,
                }
            }
        }
        return FAIL;
    }

    /// Returns i pointing to after pointer, errors otherwise
    fn parseTable(self: *Self, start: usize) !usize {
        const FAIL = ParseError.IncompleteTable;

        var i = start + "{|".len;

        while (i < self.raw_wikitext.len) {
            i = try skip(self.raw_wikitext, table_pred, i, FAIL);
            if (nextEql(self.raw_wikitext, "|}", i)) {
                return i + "|}".len;
            }
            i += 1;
        }

        return FAIL;
    }

    fn parseExternalLink(self: *Self, start: usize) !usize {
        const FAIL = ParseError.BadExternalLink;

        // skip opening [
        var i = try advance(start, "[".len, self.raw_wikitext, FAIL);

        // extract url
        const url_start = i;
        i = try skip(self.raw_wikitext, external_link_text_pred, i, FAIL);
        if (self.raw_wikitext[i] == '\n' or self.raw_wikitext[i] == '\r')
            return FAIL;
        const url = self.raw_wikitext[url_start..i];

        // skip whitespace after url
        i = try skip(self.raw_wikitext, single_line_whitespace_pred, i, FAIL);
        if (self.raw_wikitext[i] == '\n' or self.raw_wikitext[i] == '\r')
            return FAIL;

        // if no name found, return
        if (self.raw_wikitext[i] == ']') {
            try self.nodes.append(.{ .external_link = .{
                .url = url,
                .title = null,
            } });
            return i + 1;
        }

        const name_start = i;
        i = try skip(self.raw_wikitext, external_link_text_pred, i, FAIL);
        if (self.raw_wikitext[i] == '\n' or self.raw_wikitext[i] == '\r')
            return FAIL;
        const name = self.raw_wikitext[name_start..i];

        i = try skip(self.raw_wikitext, single_line_whitespace_pred, i, FAIL);
        if (self.raw_wikitext[i] != ']')
            return FAIL;

        try self.nodes.append(.{ .external_link = .{
            .url = url,
            .title = name,
        } });
        return i + 1;
    }

    /// **Internal WIP**
    ///
    /// `i` should point to the opening `<`
    ///
    /// TODO: handle nesting. Errors right now!
    fn parseHtmlTag(self: *Self, start: usize) !usize {
        const FAIL = ParseError.InvalidHtmlTag;

        var i = try advance(start, "<".len, self.raw_wikitext, FAIL);
        if (isWhiteSpace(self.raw_wikitext[i]))
            return FAIL;

        const tag_name_start = i;
        i = try skip(self.raw_wikitext, node_name_pred, i, FAIL);
        if (i == tag_name_start)
            return FAIL;
        const tag_name = self.raw_wikitext[tag_name_start..i];

        i = try skip(self.raw_wikitext, whitespace_pred, i, FAIL);

        // attempt to find attributes
        var attrs = std.ArrayList(HtmlTagCtx.HtmlTagAttr).init(self.a);
        while (attribute_name_pred(self.raw_wikitext[i])) {
            if (i >= self.raw_wikitext.len)
                return FAIL;

            // extract attr name
            const attr_name_start = i;
            i = try skip(self.raw_wikitext, attribute_name_pred, i, FAIL);
            if (attr_name_start == i)
                return FAIL;
            const attr_name = self.raw_wikitext[attr_name_start..i];

            // skip whitespace after attr name
            i = try skip(self.raw_wikitext, whitespace_pred, i, FAIL);

            // skip '='
            if (self.raw_wikitext[i] != '=')
                return FAIL;
            i = try advance(i, "=".len, self.raw_wikitext, FAIL);

            // skip whitespace after =
            i = try skip(self.raw_wikitext, whitespace_pred, i, FAIL);

            // skip quote and remember if it was ' or "
            const quote = self.raw_wikitext[i];
            if (i + 1 == self.raw_wikitext.len or (quote != '\'' and quote != '"'))
                return FAIL;
            i = try advance(i, 1, self.raw_wikitext, FAIL);

            // get attr value
            const attr_value_start = i;
            switch (quote) {
                '\'' => i = try skip(self.raw_wikitext, attribute_value_single_quote_pred, i, FAIL),
                '"' => i = try skip(self.raw_wikitext, attribute_value_double_quote_pred, i, FAIL),
                else => unreachable,
            }
            const attr_value = self.raw_wikitext[attr_value_start..i];

            // skip last quote
            i = try advance(i, 1, self.raw_wikitext, FAIL);

            try attrs.append(.{ .name = attr_name, .value = attr_value });

            // skip whitespace after attr name
            i = try skip(self.raw_wikitext, whitespace_pred, i, FAIL);
        }

        if (i + 1 >= self.raw_wikitext.len)
            return FAIL;

        // Handle self closing tag
        if (self.raw_wikitext[i] == '/') {
            if (self.raw_wikitext[i + 1] != '>')
                return FAIL;
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
            return try advance(i, "/>".len, self.raw_wikitext, FAIL);
        }

        // skip closing '>'
        if (self.raw_wikitext[i] != '>')
            return FAIL;
        i = try advance(i, 1, self.raw_wikitext, FAIL);

        const content_start = i;

        while (i < self.raw_wikitext.len) : (i += 1) {
            const ch = self.raw_wikitext[i];
            switch (ch) {
                '<' => {
                    // end content
                    const content_end = i;

                    // skip '>'
                    i = try advance(i, 1, self.raw_wikitext, FAIL);
                    if (self.raw_wikitext[i] != '/')
                        return FAIL;
                    // skip '/'
                    i = try advance(i, 1, self.raw_wikitext, FAIL);

                    // get close tag name
                    const close_tag_name_start = i;
                    i = try skip(self.raw_wikitext, node_name_pred, i, FAIL);
                    const close_tag_name = self.raw_wikitext[close_tag_name_start..i];

                    // validate
                    if (!std.mem.eql(u8, close_tag_name, tag_name))
                        return FAIL;

                    i = try skip(self.raw_wikitext, whitespace_pred, i, FAIL);
                    if (self.raw_wikitext[i] != '>')
                        return FAIL;

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

        return FAIL;
    }

    /// moves to i to after the comment,
    /// or returns `ParseError.UnclosedHtmlComment` if none is found
    fn skipHtmlComment(self: *Self, start: usize) !usize {
        const FAIL = ParseError.UnclosedHtmlComment;

        var i = start;
        while (i < self.raw_wikitext.len) : (i += 1) {
            const ch = self.raw_wikitext[i];
            if (ch == '-') {
                if (nextEql(self.raw_wikitext, "-->", i)) {
                    return i + "-->".len;
                } else if (nextEql(self.raw_wikitext, "--", i)) {
                    return FAIL;
                }
            }
        }

        return FAIL;
    }

    /// attempts to find html entity from '&' start character
    ///
    /// Returns `ParseError.IncompleteHtmlEntity` if not found
    fn parseHtmlEntity(self: *Self, start: usize) !usize {
        const FAIL = ParseError.IncompleteHtmlEntity;

        var i: usize = try advance(start, "&".len, self.raw_wikitext, FAIL);

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
                        return FAIL;
                    }
                }

                if (isDigit(ch)) {
                    n_digits += 1;
                } else {
                    return FAIL;
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

        return FAIL;
    }

    /// called on `start` pointing to '=' at the start of the line
    /// or start of an article.
    fn parseHeading(self: *Self, start: usize) !usize {
        const FAIL = ParseError.IncompleteHeading;

        var i: usize = start;

        // parse leading =, remembering how many
        var level: usize = 0;
        while (i < self.raw_wikitext.len) : (i += 1) {
            const ch = self.raw_wikitext[i];
            switch (ch) {
                '=' => level += 1,
                '\n', '\r' => return FAIL,
                else => break,
            }
        }

        const text_start = i;

        // find next '='
        i = try skip(self.raw_wikitext, heading_name_pred, i, FAIL);
        if (self.raw_wikitext[i] == '\n' or self.raw_wikitext[i] == '\r')
            return FAIL;

        // verify heading is closed by `level` `=` chars
        if (!nextEqlCount(self.raw_wikitext, '=', level, i))
            return FAIL;

        const text = self.raw_wikitext[text_start..i];

        // skip '=', test if followed by '\n'
        i = try advance(i, level, self.raw_wikitext, FAIL);
        if (self.raw_wikitext[i] != '\n')
            return FAIL;

        try self.nodes.append(.{ .heading = .{ .heading = text, .level = level } });

        return i;
    }

    /// Returns size of the node
    ///
    /// Does not handle nesting!
    ///
    /// Returns `ParseError.IncompleteArgument` if unclosed
    fn parseArgument(self: *Self, start: usize) !usize {
        const FAIL = ParseError.IncompleteArgument;

        var i: usize = start + "{{{".len;
        while (i < self.raw_wikitext.len) {
            const ch = self.raw_wikitext[i];

            if (ch == '}') {
                if (nextEql(self.raw_wikitext, "}}}", i)) {
                    const end = i + "}}}".len;
                    const text = self.raw_wikitext[start..end];
                    try self.nodes.append(.{ .argument = text });
                    return end;
                } else {
                    return FAIL;
                }
            }

            i += 1;
        }

        return FAIL;
    }
};

/// Advances `i` until `continue_pred` returns false
///
/// If end of `buf` is reached, returns error `E`
///
/// Predicate calls are inlined for performance
fn skip(buf: []const u8, continue_pred: fn (u8) bool, _i: usize, E: anyerror) !usize {
    var i = _i;
    while (i < buf.len) : (i += 1) {
        if (!@call(.always_inline, continue_pred, .{buf[i]})) {
            return i;
        }
    }
    return E;
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

/// Continues on ' ' or '\t'
fn single_line_whitespace_pred(ch: u8) bool {
    switch (ch) {
        ' ', '\t' => return true,
        else => return false,
    }
}

/// Stops on ' ', '\n', '\r', '\t', '/', '>', '='
fn attribute_name_pred(ch: u8) bool {
    switch (ch) {
        ' ', '\n', '\r', '\t', '/', '>', '=' => return false,
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

/// Stops on '\n', '\r', '='
fn heading_name_pred(ch: u8) bool {
    switch (ch) {
        '\n', '\r', '=' => return false,
        else => return true,
    }
}

/// Stops on ' ', '\n', '\r', '\t', ']'
fn external_link_text_pred(ch: u8) bool {
    switch (ch) {
        ' ', '\t', '\n', '\r', ']' => return false,
        else => return true,
    }
}

/// Stops on '|'
fn table_pred(ch: u8) bool {
    switch (ch) {
        '|' => return false,
        else => return true,
    }
}

/// Safely advance buffer index `i` by count
///
/// Returns `error.AdvanceBeyondBuffer` if i+count goes out of bounds
inline fn advance(i: usize, count: usize, buf: []const u8, E: anyerror) !usize {
    if (i + count < buf.len) {
        return i + count;
    } else {
        return E;
    }
}

inline fn isWhiteSpace(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r';
}

/// true if `ch` is a printable ascii digit dec 48 <--> 57
inline fn isDigit(ch: u8) bool {
    return 48 <= ch and ch <= 57;
}

/// returns `E` if `ch` is `\n`
inline fn errOnLineBreak(ch: u8, E: anyerror) !void {
    if (ch == '\n')
        return E;
}

/// returns `true` if the needle is present starting at i.
///
/// `false` if out of bounds
inline fn nextEql(buf: []const u8, needle: []const u8, i: usize) bool {
    if (i + needle.len <= buf.len)
        return std.mem.eql(u8, buf[i..][0..needle.len], needle);
    return false;
}

/// returns `true` if `count` occurences of `ch` are found in succession start at `i`
inline fn nextEqlCount(buf: []const u8, ch: u8, count: usize, _i: usize) bool {
    var i = _i;

    if (i + count > buf.len)
        return false;

    var found: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == ch) {
            found += 1;
            if (found == count)
                return true;
        } else {
            return false;
        }
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

test "Trivial nextEqlCount" {
    const wikitext =
        \\{{{arg}}
        \\
    ;
    try std.testing.expect(nextEqlCount(wikitext, '{', 3, 0));
    try std.testing.expect(nextEqlCount(wikitext, '}', 2, 6));
    try std.testing.expect(!nextEqlCount(wikitext, '{', 3, 7));
    try std.testing.expect(!nextEqlCount("== Anarchism=\n", '=', 2, 12));
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
    const weird: []const u8 =
        \\= = =
        \\
    ;
    const cases = [_][]const u8{ unclosed1, unclosed2, overclosed, bad_line_break, weird };

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
        .text => |text| try std.testing.expectEqualStrings("\nBlah Blah Blah\nSome more Blah\n", text),
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
        .text => |text| try std.testing.expectEqualStrings("\nBlah ", text),
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

test "External Link No Title" {
    const wikitext = "[https://example.com]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);
    switch (wp.nodes.items[0]) {
        .external_link => |el| {
            try std.testing.expect(el.title == null);
            try std.testing.expectEqualStrings("https://example.com", el.url);
        },
        else => unreachable,
    }
}

test "External Link With Title" {
    const wikitext = "[https://example.com Example]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);
    switch (wp.nodes.items[0]) {
        .external_link => |el| {
            try std.testing.expectEqualStrings("https://example.com", el.url);
            try std.testing.expectEqualStrings("Example", el.title.?);
        },
        else => unreachable,
    }
}

test "Skips Table" {
    const wikitext =
        \\Very Nice Table!
        \\{|class="wikitable" style="border: none; background: none; float: right;"
        \\|+ Anarchist vs. statist perspectives on education<br/>{{Small|Ruth Kinna (2019){{Sfn|Kinna|2019|p=97}}}}
        \\|-
        \\!scope="col"|
        \\!scope="col"|Anarchist education
        \\!scope="col"|State education
        \\|-
        \\|Concept || Education as self-mastery || Education as service
        \\|-
        \\|Management || Community based || State run
        \\|-
        \\|Methods || Practice-based learning || Vocational training
        \\|-
        \\|Aims || Being a critical member of society || Being a productive member of society
        \\|}
        \\Glad the table is over!
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 2);

    switch (wp.nodes.items[0]) {
        .text => |t| try std.testing.expectEqualStrings("Very Nice Table!\n", t),
        else => unreachable,
    }

    switch (wp.nodes.items[1]) {
        .text => |t| try std.testing.expectEqualStrings("\nGlad the table is over!", t),
        else => unreachable,
    }
}

test "Parses Template No Args" {
    const wikitext = "{{Anarchism sidebar}}";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);

    switch (wp.nodes.items[0]) {
        .template => |temp| {
            try std.testing.expectEqualStrings("Anarchism sidebar", temp.name);
            try std.testing.expect(temp.children.len == 0);
            try std.testing.expect(temp.args.len == 0);
        },
        else => unreachable,
    }
}

test "Parses Template Non Keyed Argument" {
    const wikitext = "{{Main|Definition of anarchism and libertarianism}}";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);

    switch (wp.nodes.items[0]) {
        .template => |temp| {
            try std.testing.expectEqualStrings("Main", temp.name);
            try std.testing.expect(temp.children.len == 0);
            try std.testing.expect(temp.args.len == 1);
            try std.testing.expect(temp.args.first.?.data.key == null);
            try std.testing.expectEqualStrings("Definition of anarchism and libertarianism", temp.args.first.?.data.value);
        },
        else => unreachable,
    }
}

test "Parses Template With Child as Arg" {
    const wikitext = "{{Main|{{Definition of anarchism and libertarianism}}}}";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);

    switch (wp.nodes.items[0]) {
        .template => |temp| {
            try std.testing.expectEqualStrings("Main", temp.name);
            try std.testing.expect(temp.args.len == 0);
            try std.testing.expect(temp.children.len == 1);
            try std.testing.expectEqualStrings("Definition of anarchism and libertarianism", temp.children.first.?.data.name);
        },
        else => unreachable,
    }
}
