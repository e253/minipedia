const std = @import("std");
const std_options = .{ .log_level = .debug };

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
    wiki_link: WikiLinkCtx,
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

pub const WikiLinkCtx = struct {
    /// actual article to link to
    article: []const u8,
    /// text to display to the user.
    /// `null` when `article` should be displayed directly
    name: ?[]const u8 = null,
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
    name: []const u8,
    args: std.DoublyLinkedList([]const u8) = std.DoublyLinkedList([]const u8){},
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

    pub const ParseError = error{
        IncompleteArgument,
        IncompleteHeading,
        IncompleteHtmlEntity,
        UnclosedHtmlComment,
        InvalidHtmlTag,
        BadExternalLink,
        BadWikiLink,
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

                        const res = self.parseTemplate(i) catch |err| switch (err) {
                            ParseError.BadTemplate => {
                                std.log.debug("{s} Context: '{s}'", .{ @errorName(err), getErrContext(self.raw_wikitext, i) });
                                return err;
                            },
                            else => return err,
                        };

                        try self.nodes.append(.{ .template = res.t_ctx });
                        i = res.offset;

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
                        if (cur_text_node.len > 0)
                            try self.nodes.append(.{ .text = cur_text_node });

                        i = try self.parseWikiLink(i);

                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
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
                        i = self.parseHtmlTag(i) catch |err| switch (err) {
                            error.InvalidHtmlTag => {
                                std.log.debug("{s} Context: '{s}'", .{ @errorName(err), getErrContext(self.raw_wikitext, i) });
                                return err;
                            },
                            else => return err,
                        };
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

    /// skips templates with nesting ...
    /// Used as a fallback for `parseTemplate` becuase it fails on big tags
    fn skipTemplate(self: *Self, start: usize) !usize {
        const FAIL = ParseError.BadTemplate;

        var i = start + "{{".len;

        var depth: usize = 0; // recursion depth

        while (i < self.raw_wikitext.len) {
            switch (self.raw_wikitext[i]) {
                '}' => {
                    if (nextEql(self.raw_wikitext, "{{", i)) {
                        if (depth == 0) {
                            return i + "}}".len;
                        } else {
                            depth -= 1;
                            i += "}}".len;
                            continue;
                        }
                    } else {
                        return FAIL;
                    }
                },
                '{' => {
                    if (nextEql(self.raw_wikitext, "{{", i)) {
                        depth += 1;
                        i += "{{".len;
                        continue;
                    } else {
                        return FAIL;
                    }
                },
                else => i += 1,
            }
        }

        return FAIL;
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
        const template_name = self.raw_wikitext[template_name_start..i];

        // skip whitespace after template name
        i = try skip(self.raw_wikitext, whitespace_pred, i, FAIL);

        // if template closes, return it
        if (nextEql(self.raw_wikitext, "}}", i)) {
            return .{
                .offset = i + "}}".len,
                .t_ctx = .{ .name = template_name },
            };
        }

        const arg_first_pred = struct {
            /// stop on '{', '}', '|'
            pub fn afp(ch: u8) bool {
                switch (ch) {
                    '{', '}', '|' => return false,
                    else => return true,
                }
            }
        }.afp;

        if (self.raw_wikitext[i] != '|')
            return FAIL;

        // parse args
        i += "|".len;

        const AL = std.DoublyLinkedList([]const u8);
        var args = AL{};
        const CL = std.DoublyLinkedList(TemplateCtx);
        var children = CL{};

        var arg_start = i;

        while (i < self.raw_wikitext.len) {
            i = try skip(self.raw_wikitext, arg_first_pred, i, FAIL);

            switch (self.raw_wikitext[i]) {
                '{' => { // attempt to parse argument that is a nested template
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
                '}' => { // template end
                    if (nextEql(self.raw_wikitext, "}}", i)) {
                        if (arg_start == i) { // if child ends template, there's nothing to add
                            return .{
                                .offset = i + "}}".len,
                                .t_ctx = .{
                                    .name = template_name,
                                    .args = args,
                                    .children = children,
                                },
                            };
                        } else {
                            const arg = try self.a.create(AL.Node);
                            const arg_text = self.raw_wikitext[arg_start..i];
                            arg.*.data = arg_text;
                            args.append(arg);

                            return .{
                                .offset = i + "}}".len,
                                .t_ctx = .{
                                    .name = template_name,
                                    .args = args,
                                    .children = children,
                                },
                            };
                        }
                    } else {
                        return FAIL;
                    }
                },
                '|' => { // value only arg end, but more to follow
                    const arg = try self.a.create(AL.Node);
                    arg.*.data = self.raw_wikitext[arg_start..i];
                    args.append(arg);

                    i += "|".len;
                    arg_start = i;
                },
                else => unreachable,
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

    fn parseWikiLink(self: *Self, start: usize) !usize {
        const FAIL = ParseError.BadWikiLink;

        // skip [[ and single line whitespace after
        var i = start + "[[".len;
        i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);

        // find end of article
        const article_start = i;
        i = try skipUntilOneOf(self.raw_wikitext, &.{ '\n', '|', ']' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);
        const article_end = i;

        // skip whitespace after article
        i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);

        // if link ends return
        if (self.raw_wikitext[i] == ']') {
            if (nextEql(self.raw_wikitext, "]]", i)) {
                try self.nodes.append(.{ .wiki_link = .{
                    .article = self.raw_wikitext[article_start..article_end],
                } });
                return i + "]]".len;
            } else {
                return FAIL;
            }
        }

        i += "|".len;

        // find display name end
        const display_name_start = i;
        i = try skipUntilOneOf(self.raw_wikitext, &.{ '\n', ']' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);
        const display_name_end = i;

        // skip whitespace after display name
        i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);

        if (nextEql(self.raw_wikitext, "]]", i)) {
            try self.nodes.append(.{ .wiki_link = .{
                .article = self.raw_wikitext[article_start..article_end],
                .name = self.raw_wikitext[display_name_start..display_name_end],
            } });
            return i + "]]".len;
        }

        return FAIL;
    }

    fn parseExternalLink(self: *Self, start: usize) !usize {
        const FAIL = ParseError.BadExternalLink;

        // skip opening [
        var i = start + "[".len;

        // extract url
        const url_start = i;
        i = try skipUntilOneOf(self.raw_wikitext, &.{ '\n', ' ', '\t', ']' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);
        const url = self.raw_wikitext[url_start..i];

        // skip whitespace after url
        i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);

        // if no name found, return
        if (self.raw_wikitext[i] == ']') {
            try self.nodes.append(.{ .external_link = .{
                .url = url,
                .title = null,
            } });
            return i + 1;
        }

        // get display name
        const name_start = i;
        i = try skipUntilOneOf(self.raw_wikitext, &.{ '\n', ']' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);
        const name = self.raw_wikitext[name_start..i];

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
    /// TODO: handle nesting
    ///
    /// TODO: handle wrapped templates
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
            i += "=".len;

            // skip whitespace after =
            i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n' }, i, FAIL);

            // skip quote and remember if it was ' or " or not present
            var quote: u8 = self.raw_wikitext[i];
            if (quote == '"' or quote == '\'') {
                i += 1;
            } else {
                quote = 0;
            }

            // get attr value
            const attr_value_start = i;
            switch (quote) {
                '\'' => i = try skip(self.raw_wikitext, attribute_value_single_quote_pred, i, FAIL),
                '"' => i = try skip(self.raw_wikitext, attribute_value_double_quote_pred, i, FAIL),
                0 => i = try skipUntilOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n', '/', '>' }, i, FAIL),
                else => unreachable,
            }
            const attr_value = self.raw_wikitext[attr_value_start..i];

            // skip quote if it existed
            if (quote != 0)
                i += 1;

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
            return i + "/>".len;
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

                    if (!nextEql(self.raw_wikitext, "</", i))
                        return FAIL;
                    i += "</".len;

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

/// Skips until `i` exceeds `buf.len` (returning `E`) or a character not in `continues` is found
inline fn skipWhileOneOf(buf: []const u8, comptime continues: []const u8, i: usize, E: anyerror) !usize {
    var _i = i;

    while (_i < buf.len) : (_i += 1) {
        var cont: bool = false;
        inline for (continues) |c|
            cont = cont or buf[_i] == c;
        if (!cont)
            return _i;
    }

    return E;
}

/// Skips until `i` exceeds `buf.len` (returning `E`) or a character in `stops` is found
inline fn skipUntilOneOf(buf: []const u8, comptime stops: []const u8, i: usize, E: anyerror) !usize {
    var _i = i;

    while (_i < buf.len) : (_i += 1) {
        inline for (stops) |stop| {
            if (buf[_i] == stop)
                return _i;
        }
    }

    return E;
}

/// Advances `i` until `continue_pred` returns false
///
/// If end of `buf` is reached, returns error `E`
///
/// Predicate calls are inlined for performance
inline fn skip(buf: []const u8, continue_pred: fn (u8) bool, _i: usize, E: anyerror) !usize {
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

/// get 30 chars before problems and 30 chars after if buf allows
inline fn getErrContext(buf: []const u8, i: usize) []const u8 {
    const start = blk: {
        if (i < 30)
            break :blk 0;
        break :blk i - 30;
    };
    const end = blk: {
        if (i + 30 >= buf.len)
            break :blk buf.len;
        break :blk i + 30;
    };
    return buf[start..end];
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

test "Parses Heading with embedded html with attributes" {
    //const wikitext =
    //    \\=== Computing <span class="anchor" id="Computing codes"></span> ==="
    //;

    //var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    //defer arena.deinit();
    //const a = arena.allocator();

    //var wp = MWParser.init(a, wikitext);
    //try wp.parse();

    return error.SkipZigTest;
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

test "Decodes Tag Attribute without quotes" {
    const wikitext = "<ref name=Maine />";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    switch (wp.nodes.items[0]) {
        .html_tag => |t| {
            try std.testing.expect(t.attrs.?.len == 1);
            try std.testing.expect(t.text == null);
            try std.testing.expectEqualStrings("name", t.attrs.?[0].name);
            try std.testing.expectEqualStrings("Maine", t.attrs.?[0].value);
            try std.testing.expectEqualStrings("ref", t.tag_name);
        },
        else => unreachable,
    }
}

// Needs support for parsing templates as templates within html tags
test "Real Ref Tag 1" {
    //const wikitext =
    //    \\<ref name="Winston">{{cite journal| first=Jay |last=Winston |title=The Annual Course of Zonal Mean Albedo as Derived From ESSA 3 and 5 Digitized Picture Data |journal=Monthly Weather Review |volume=99 |pages=818–827| bibcode=1971MWRv...99..818W| date=1971| doi=10.1175/1520-0493(1971)099<0818:TACOZM>2.3.CO;2| issue=11|doi-access=free}}</ref>"
    //;

    //var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    //defer arena.deinit();
    //const a = arena.allocator();

    //var wp = MWParser.init(a, wikitext);
    //wp.parse() catch {};

    return error.SkipZigTest;
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
    const wikitext = "[http://dwardmac.pitzer.edu Anarchy Archives]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);
    switch (wp.nodes.items[0]) {
        .external_link => |el| {
            try std.testing.expectEqualStrings("http://dwardmac.pitzer.edu", el.url);
            try std.testing.expectEqualStrings("Anarchy Archives", el.title.?);
        },
        else => unreachable,
    }
}

test "Wikilink No Title" {
    const wikitext = "[[Index of Andorra-related articles]]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);
    switch (wp.nodes.items[0]) {
        .wiki_link => |wl| {
            try std.testing.expectEqualStrings("Index of Andorra-related articles", wl.article);
        },
        else => unreachable,
    }
}

test "Wikilink With Title" {
    const wikitext = "[[Andorra–Spain border|Spanish border]]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);
    switch (wp.nodes.items[0]) {
        .wiki_link => |wl| {
            try std.testing.expectEqualStrings("Andorra–Spain border", wl.article);
            try std.testing.expectEqualStrings("Spanish border", wl.name.?);
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
            try std.testing.expectEqualStrings("Definition of anarchism and libertarianism", temp.args.first.?.data);
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
        .template => |t| {
            try std.testing.expectEqualStrings("Main", t.name);
            try std.testing.expect(t.args.len == 1);
            try std.testing.expectEqualStrings("{{Definition of anarchism and libertarianism}}", t.args.first.?.data);
            try std.testing.expect(t.children.len == 1);
            try std.testing.expectEqualStrings("Definition of anarchism and libertarianism", t.children.first.?.data.name);
        },
        else => unreachable,
    }
}

test "Parses Template With KV Arg" {
    const wikitext = "{{Main|date=May 2023}}";

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
            try std.testing.expectEqualStrings("date=May 2023", temp.args.first.?.data);
        },
        else => unreachable,
    }
}

test "Skips unparseable (for now) template" {
    const wikitext =
        \\{{Infobox country
        \\| conventional_long_name = Principality of Andorra<ref name="constitution">{{cite web|url=https://www.wipo.int/edocs/lexdocs/laws/en/ad/ad001en.pdf|title=Constitution of the Principality of Andorra|url-status=live|archive-url=https://web.archive.org/web/20190516152108/https://www.wipo.int/edocs/lexdocs/laws/en/ad/ad001en.pdf|archive-date=16 May 2019}}</ref>
        \\| common_name            = Andorra
        \\| native_name            = {{native name|ca|Principat d'Andorra}}
        \\| image_flag             = Flag of Andorra.svg
        \\| image_coat             = Coat of arms of Andorra.svg
        \\| symbol_type            = Coat of arms
        \\| national_motto         = {{lang-la|Virtus Unita Fortior|label=none}}  ([[Latin]])<br />"United virtue is stronger"<ref>{{cite web|url=https://www.worldatlas.com/webimage/countrys/europe/andorra/adsymbols.htm|title=Andorran Symbols|date=29 March 2021|publisher=WorldAtlas}}</ref>
        \\| national_anthem        = {{native name|ca|[[El Gran Carlemany]]}}<br />"The Great [[Charlemagne]]"<div style="display:inline-block;margin-top:0.4em;">{{center|[[File:El Gran Carlemany.ogg]]}}</div>
        \\| image_map              = Location Andorra Europe.png
        \\| map_caption            = {{map caption |location_color=centre of green circle |region=Europe |region_color=dark grey}}
        \\| image_map2             =
        \\| capital                = [[Andorra la Vella]]
        \\| coordinates            = {{coord|42|30|23|N|1|31|17|E|type:city_region:AD|display=inline}}
        \\| largest_city           = capital
        \\| official_languages     = [[Catalan language|Catalan]]<ref name="constitution"/> <br />
        \\| ethnic_groups          = {{plainlist|
        \\* 48.3% [[Demographics of Andorra|Andorrans]]
        \\* 24.8% [[Spaniards]]
        \\* 11.2% [[Portuguese people|Portuguese]]
        \\* 4.5% [[French people|French]]
        \\* 1.4% [[Argentines]]
        \\* 9.8% others
        \\}}
        \\| ethnic_groups_year     = 2021<ref name="cia"/>
        \\| religion               = {{unbulleted list
        \\|{{Tree list}}
        \\* 90.8% Christianity
        \\** 85.5% [[Catholic Church in Andorra|Catholicism]] ([[State religion|official]])<ref>{{cite book|first1=Jeroen|last1= Temperman|title=State–Religion Relationships and Human Rights Law: Towards a Right to Religiously Neutral Governance|publisher=BRILL|year=2010|isbn=9789004181496|quote=...&nbsp;guarantees the Roman Catholic Church free and public exercise of its activities and the preservation of the relations of special co-operation with the state in accordance with the Andorran tradition. The Constitution recognizes the full legal capacity of the bodies of the Roman Catholic Church which have legal status in accordance with their own rules.}}</ref>
        \\** 5.3% other [[List of Christian denominations|Christian]]
        \\{{Tree list/end}}
        \\ | 6.9% [[Irreligion|no religion]]
        \\ | 2.3% others
        \\ }}
        \\| religion_year          = 2020
        \\| religion_ref           = <ref>{{Cite web|url=https://www.thearda.com/world-religion/national-profiles?u=6c|title=National Profiles &amp;#124; World Religion|website=www.thearda.com}}</ref>
        \\| demonym                = [[List of Andorrans|Andorran]]
        \\| government_type        = Unitary [[Parliamentary system|parliamentary diarchic]] constitutional [[Coregency#Andorra|co-principality]]
        \\| leader_title1          = [[Co-Princes of Andorra|Co-Princes]]
        \\| leader_name1           = {{plainlist|
        \\* [[Joan Enric Vives Sicília]]
        \\* [[Emmanuel Macron]]}}
        \\| leader_title2          = [[List of Representatives of the Co-Princes of Andorra|Representatives]]
        \\| leader_name2           = {{plainlist|
        \\* [[Josep Maria Mauri]]
        \\* [[Patrick Strzoda]]}}
        \\| leader_title3          = [[Head of Government of Andorra|Prime Minister]]
        \\| leader_name3           = [[Xavier Espot Zamora]]
        \\| leader_title4          = [[List of General Syndics of the General Council|General Syndic]]
        \\| leader_name4           = [[Carles Enseñat Reig]]
        \\| legislature            = [[General Council (Andorra)|General Council]]
        \\| sovereignty_type       = Independence
        \\| established_event1     = from the [[Crown of Aragon]]
        \\| established_date1      = [[Paréage of Andorra (1278)|8 September 1278]]<ref>{{cite web | url=https://www.cultura.ad/historia-d-andorra |title = Història d'Andorra|language=ca|website=Cultura.ad|access-date=26 March 2019}}</ref><ref>{{cite web | url=https://www.enciclopedia.cat/EC-GEC-0003858.xml |title = Andorra|language=ca|website=Enciclopèdia.cat|access-date=26 March 2019}}</ref>
        \\| established_event2     = from the [[Sègre (department)|French Empire]]
        \\| established_date2      = 1814
        \\| established_event3     = [[Constitution of Andorra|Constitution]]
        \\| established_date3      = 2 February 1993
        \\| area_km2               = 467.63
        \\| area_rank              = 178th
        \\| area_sq_mi             = 180.55
        \\| percent_water          = 0.26 (121.4 [[hectares|ha]]<!-- Not including areas of rivers -->){{efn|{{in lang|fr|cap=yes}} Girard P &amp; Gomez P (2009), Lacs des Pyrénées: Andorre.<ref>{{cite web |url=http://www.estadistica.ad/serveiestudis/publicacions/CD/Anuari/cat/pdf/xifres.PDF |archive-url=https://web.archive.org/web/20091113203301/http://www.estadistica.ad/serveiestudis/publicacions/CD/Anuari/cat/pdf/xifres.PDF |url-status = dead|archive-date=13 November 2009 |title=Andorra en xifres 2007: Situació geogràfica, Departament d'Estadística, Govern d'Andorra |access-date=26 August 2012 }}</ref>}}
        \\| population_estimate    = {{increase}} 85,863<ref>{{cite web |url=https://www.estadistica.ad/portal/apps/sites/#/estadistica-ca|title=Departament d'Estadística
        \\|access-date=8 July 2024}}</ref>
        \\| population_estimate_rank = 185th
        \\| population_estimate_year = 2023
        \\| population_census_year = 2021
        \\| population_density_km2 = 179.8
        \\| population_density_sq_mi = 465.7
        \\| population_density_rank = 71st
        \\| GDP_PPP                = {{increase}} $6.001&nbsp;billion<ref name="IMFWEO.AD">{{cite web |url=https://www.imf.org/en/Publications/WEO/weo-database/2024/April/weo-report?c=111,&amp;s=NGDPD,PPPGDP,NGDPDPC,PPPPC,&amp;sy=2022&amp;ey=2027&amp;ssm=0&amp;scsm=1&amp;scc=0&amp;ssd=1&amp;ssc=0&amp;sic=0&amp;sort=country&amp;ds=.&amp;br=1 |title=Report for Selected Countries and Subjects: April 2024|publisher=[[International Monetary Fund]]|website=imf.org}}</ref>
        \\| GDP_PPP_year           = 2024
        \\| GDP_PPP_rank           = 168th
        \\| GDP_PPP_per_capita     = {{increase}} $69,146<ref name="IMFWEO.AD" />
        \\| GDP_PPP_per_capita_rank = 18th
        \\| GDP_nominal            = {{increase}} $3.897&nbsp;billion<ref name="IMFWEO.AD" />
        \\| GDP_nominal_year       = 2024
        \\| GDP_nominal_rank       = 159th
        \\| GDP_nominal_per_capita = {{increase}} $44,900<ref name="IMFWEO.AD" />
        \\| GDP_nominal_per_capita_rank = 24th
        \\| Gini                   = 27.21
        \\| Gini_year              = 2003
        \\| Gini_ref               = {{efn|Informe sobre l'estat de la pobresa i la desigualtat al Principal d'Andorra (2003)<ref>{{cite web |url=http://www.estadistica.ad/serveiestudis/publicacions/Publicacions/Pobresa.pdf |title=Informe sobre l'estat de la pobresa i la desigualtat al Principal d'Andorra (2003) |publisher=Estadistica.ad |access-date=25 November 2012 |archive-url=https://web.archive.org/web/20130810122415/http://www.estadistica.ad/serveiestudis/publicacions/Publicacions/Pobresa.pdf |archive-date=10 August 2013 |url-status = dead}}</ref>}}
        \\| HDI                    = 0.884<!-- number only -->
        \\| HDI_year               = 2022 <!-- Please use the year to which the data refers, not the publication year -->
        \\| HDI_change             = increase<!-- increase/decrease/steady -->
        \\| HDI_ref                = <ref name="UNHDR">{{cite web|url=https://hdr.undp.org/system/files/documents/global-report-document/hdr2023-24reporten.pdf|title=Human Development Report 2023/24|language=en|publisher=[[United Nations Development Programme]]|date=13 March 2024|access-date=13 March 2024}}</ref>
        \\| HDI_rank               = 35th
        \\| currency               = [[Euro]] ([[Euro sign|€]]){{efn|Before 1999, the [[French franc]] and [[Spanish peseta]]; the coins and notes of both currencies, however, remained legal tender until 2002. Small amounts of [[Andorran diner]]s (divided into 100 centim) were minted after 1982.}}
        \\| currency_code          = EUR
        \\| time_zone              = [[Central European Time|CET]]
        \\| utc_offset             = +01
        \\| utc_offset_DST         = +02
        \\| time_zone_DST          = [[Central European Summer Time|CEST]]
        \\| date_format            = dd/mm/yyyy
        \\| drives_on              = right<ref name="DRIVESIDE">{{cite web |url=http://whatsideofroad.com/ad/ |title=What side of the road do they drive on in Andorra |access-date=19 March 2019 }}{{Dead link|date=September 2019 |bot=InternetArchiveBot |fix-attempted=yes }}</ref>
        \\| calling_code           = [[Telephone numbers in Andorra|+376]]
        \\| cctld                  = [[.ad]]{{efn|Also [[.cat]], shared with [[Països Catalans|Catalan-speaking territories]].}}
        \\| today                  =
        \\}}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);

    switch (wp.nodes.items[0]) {
        .template => |t| {
            // arguments don't always parse correclty with current logic
            //try std.testing.expectEqualStrings(
            //    " conventional_long_name = Principality of Andorra<ref name="constitution">{{cite web|url=https://www.wipo.int/edocs/lexdocs/laws/en/ad/ad001en.pdf|title=Constitution of the Principality of Andorra|url-status=live|archive-url=https://web.archive.org/web/20190516152108/https://www.wipo.int/edocs/lexdocs/laws/en/ad/ad001en.pdf|archive-date=16 May 2019}}</ref>\n",
            //    t.args.first.?.data,
            //);
            try std.testing.expectEqualStrings("Infobox country", t.name);
        },
        else => unreachable,
    }
}
