const std = @import("std");
const TestTrace = @import("tracing.zig").TestTrace;

pub const ExternalLink = struct {
    url: []const u8,
    title: ?[]const u8 = null,
};

pub const WikiLink = struct {
    pub const Namepace = enum(u8) {
        Unknown,
        Main,
        File,
        Image,
        Wikitionary,

        pub fn fromStr(str: []const u8) Namepace {
            if (std.mem.eql(u8, str, "main")) {
                return .Main;
            } else if (std.mem.eql(u8, str, "File")) {
                return .File;
            } else if (std.mem.eql(u8, str, "wikt")) {
                return .Wikitionary;
            } else if (std.mem.eql(u8, str, "Image")) {
                return .Image;
            } else {
                return .Unknown;
            }
        }
    };

    /// Actual article to link to
    article: []const u8,
    /// File extension if it exists (always null for now)
    ext: ?[]const u8 = null,
    /// link namespce, not included in `article`
    namespace: Namepace = Namepace.Main,
};

pub const Heading = struct {
    level: usize,
};

pub const HtmlTag = struct {
    pub const HtmlTagAttr = struct {
        name: []const u8,
        value: []const u8,
    };
    pub const AttrList = std.DoublyLinkedList(HtmlTagAttr);
    pub const AttrNode = AttrList.Node;

    tag_name: []const u8 = "",
    attrs: AttrList = AttrList{},
};

pub const Template = struct {
    name: []const u8,
};

pub const Argument = struct {
    key: ?[]const u8 = null,
};

pub const MWAstNode = struct {
    const Self = @This();
    pub const NodeType = enum {
        /// {{}}
        template,
        /// [[]]
        wiki_link,
        /// [https://example.com Example] or [https://example.com]
        external_link,
        /// like == References ==
        heading,
        /// <ref> or other html tags
        html_tag,
        /// i.e. &qout;
        html_entity,
        /// {{{arg}}} I don't know what this does
        argument,
        text,
        /// {|\n ... |}.
        table,
        /// no data, parent, or siblings, just children
        document,
    };
    pub const NodeData = union(NodeType) {
        template: Template,
        wiki_link: WikiLink,
        external_link: ExternalLink,
        heading: Heading,
        html_tag: HtmlTag,
        html_entity: []const u8,
        argument: Argument,
        text: []const u8,
        table: []const u8,
        document: ?void,
    };

    a: std.mem.Allocator,

    parent: ?*MWAstNode = null,
    /// previous adjacent node
    prev: ?*MWAstNode = null,
    /// next adjacent node
    next: ?*MWAstNode = null,
    /// first child node
    first_child: ?*MWAstNode = null,
    /// last child node
    last_child: ?*MWAstNode = null,
    /// number of children
    n_children: usize = 0,
    n: NodeData = .{ .document = null },

    pub fn nodeType(s: Self) NodeType {
        return s.n;
    }

    pub fn nodeTypeStr(s: Self) []const u8 {
        return @tagName(s.n);
    }

    pub fn getArgByKey(s: *const Self, key: []const u8) !?*MWAstNode {
        var it = s.first_child;
        while (it) |node| : (it = node.next) {
            switch (node.n) {
                .argument => |arg| {
                    if (arg.key) |_key| {
                        if (std.mem.eql(u8, key, _key))
                            return node;
                    }
                },
                else => return Error.InvalidDataCast,
            }
        }
        return null;
    }

    pub fn firstNode(s: *const Self, nt: NodeType) ?*MWAstNode {
        var it = s.first_child;
        while (it) |node| : (it = node.next) {
            if (node.nodeType() == nt)
                return node;
        }
        return null;
    }

    pub fn asText(s: *Self) error{InvalidDataCast}![]const u8 {
        switch (s.n) {
            .text => |d| return d,
            else => return error.InvalidDataCast,
        }
    }

    pub fn asTemplate(s: *Self) error{InvalidDataCast}!Template {
        switch (s.n) {
            .template => |t| return t,
            else => return error.InvalidDataCast,
        }
    }

    pub fn asArg(s: *Self) error{InvalidDataCast}!Argument {
        switch (s.n) {
            .argument => |a| return a,
            else => return error.InvalidDataCast,
        }
    }

    pub fn asExternalLink(s: *Self) error{InvalidDataCast}!ExternalLink {
        switch (s.n) {
            .external_link => |el| return el,
            else => return error.InvalidDataCast,
        }
    }

    pub fn asWikiLink(s: *Self) error{InvalidDataCast}!WikiLink {
        switch (s.n) {
            .wiki_link => |wl| return wl,
            else => return error.InvalidDataCast,
        }
    }

    pub fn asHtmlTag(s: *Self) error{InvalidDataCast}!HtmlTag {
        switch (s.n) {
            .html_tag => |ht| return ht,
            else => return error.InvalidDataCast,
        }
    }

    pub fn asHtmlEntity(s: *Self) error{InvalidDataCast}![]const u8 {
        switch (s.n) {
            .html_entity => |he| return he,
            else => return error.InvalidDataCast,
        }
    }

    pub fn asHeading(s: *Self) error{InvalidDataCast}!Heading {
        switch (s.n) {
            .heading => |heading| return heading,
            else => return error.InvalidDataCast,
        }
    }

    pub fn createChildNode(s: *Self, n: NodeData) error{OutOfMemory}!*MWAstNode {
        const new_node = try s.a.create(Self);
        new_node.* = .{ .a = s.a, .parent = s, .n = n };
        return new_node;
    }

    pub fn insertChildAfter(s: *Self, node: *MWAstNode, new_node: *MWAstNode) void {
        new_node.prev = node;
        if (node.next) |next_node| {
            // Intermediate node.
            new_node.next = next_node;
            next_node.prev = new_node;
        } else {
            // Last element of the list.
            new_node.next = null;
            s.last_child = new_node;
        }
        node.next = new_node;

        s.n_children += 1;
    }

    pub fn insertChildBefore(s: *Self, node: *MWAstNode, new_node: *MWAstNode) void {
        new_node.next = node;
        if (node.prev) |prev_node| {
            // Intermediate node.
            new_node.prev = prev_node;
            prev_node.next = new_node;
        } else {
            // First element of the list.
            new_node.prev = null;
            s.first_child = new_node;
        }
        node.prev = new_node;

        s.n_children += 1;
    }

    pub fn appendChild(s: *Self, new_node: *MWAstNode) void {
        if (s.last_child) |last_child| {
            // Insert after last.
            s.insertChildAfter(last_child, new_node);
        } else {
            // Empty list.
            s.prependChild(new_node);
        }
    }

    pub fn prependChild(s: *Self, new_node: *MWAstNode) void {
        if (s.first_child) |first_child| {
            // Insert before first.
            s.insertChildBefore(first_child, new_node);
        } else {
            // Empty list.
            s.first_child = new_node;
            s.last_child = new_node;
            new_node.prev = null;
            new_node.next = null;

            s.n_children = 1;
        }
    }

    pub fn removeChild(s: *Self, node: *MWAstNode) void {
        if (node.prev) |prev_node| {
            // Intermediate node.
            prev_node.next = node.next;
        } else {
            // First element of the list.
            s.first_child = node.next;
        }

        if (node.next) |next_node| {
            // Intermediate node.
            next_node.prev = node.prev;
        } else {
            // Last element of the list.
            s.last_child = node.prev;
        }

        s.n_children -= 1;
        std.debug.assert(s.n_children == 0 or (s.first_child != null and s.last_child != null));
    }

    /// Removes `node` and all elements afterward
    pub fn removeChildAndEndList(s: *Self, node: *MWAstNode) void {
        if (node.prev) |prev_node| {
            // Not element of list.
            s.last_child = prev_node;
            prev_node.next = null;

            var n_nodes_removed: usize = 1;
            var it = node.next;
            while (it) |_node| : (it = _node.next) {
                n_nodes_removed += 1;
            }

            std.debug.assert(s.n_children - n_nodes_removed >= 0);
            s.n_children -= n_nodes_removed;
        } else {
            // First element of the list.
            s.first_child = null;
            s.last_child = null;
            s.n_children = 0;
        }
    }
};

pub const Error = error{
    IncompleteArgument,
    IncompleteHeading,
    IncompleteHtmlEntity,
    InvalidHtmlTag,
    InvalidMathTag,
    InvalidNoWikiTag,
    BadExternalLink,
    BadWikiLink,
    BadTemplate,
    BadTemplateArg,
    BadWikiLinkArg,
    IncompleteTable,
    UnclosedHtmlComment,
    SpuriousClosedHtmlTag,

    /// using `asText` on a template node
    InvalidDataCast,

    OutOfMemory,
    NoSpaceLeft,
};

pub fn parseDocument(a: std.mem.Allocator, text: []const u8, t: anytype) !MWAstNode {
    var doc: MWAstNode = .{ .a = a };

    var i: usize = 0;

    // chars are text by default
    var cur_text_node = text[i..];
    cur_text_node.len = 0;

    while (i < text.len) {
        const ch = text[i];
        switch (ch) {
            '{' => {
                if (nextEql(text, "{", i + 1)) {
                    // Template.
                    try createAndAppendTextNodeIfNotEmpty(&doc, cur_text_node);

                    i = try parseTemplate(&doc, text, i, t);

                    cur_text_node = text[i..];
                    cur_text_node.len = 0;
                } else if (nextEql(text, "|", i + 1)) {
                    // Table.
                    try createAndAppendTextNodeIfNotEmpty(&doc, cur_text_node);

                    i = try skipTable(text, i, t);

                    cur_text_node = text[i..];
                    cur_text_node.len = 0;
                } else {
                    // Text.
                    cur_text_node.len += 1;
                    i += 1;
                }
            },

            '[' => {
                if (nextEql(text, "[", i + 1)) {
                    // Wikilink.
                    try createAndAppendTextNodeIfNotEmpty(&doc, cur_text_node);

                    i = try parseWikiLink(&doc, text, i, t);

                    cur_text_node = text[i..];
                    cur_text_node.len = 0;
                } else if (nextEql(text, "http", i + 1)) {
                    // External Link.
                    try createAndAppendTextNodeIfNotEmpty(&doc, cur_text_node);

                    i = try parseExternalLink(&doc, text, i, t);

                    cur_text_node = text[i..];
                    cur_text_node.len = 0;
                } else {
                    // Text.
                    i += 1;
                    cur_text_node.len += 1;
                }
            },

            '<' => {
                try createAndAppendTextNodeIfNotEmpty(&doc, cur_text_node);

                if (nextEql(text, "!--", i + 1)) {
                    // HTML Comment.
                    i = try skipHtmlComment(text, i, t);
                } else {
                    // HTML Tag.
                    i = try parseHtmlTag(&doc, text, i, t);
                }

                cur_text_node = text[i..];
                cur_text_node.len = 0;
            },

            '&' => {
                i, const html_entity_node = parseHtmlEntity(&doc, text, i) catch |err| switch (err) {
                    Error.IncompleteHtmlEntity => {
                        // Failover to text.
                        i += 1;
                        cur_text_node.len += 1;
                        continue;
                    },
                    else => return err,
                };

                try createAndAppendTextNodeIfNotEmpty(&doc, cur_text_node);
                doc.appendChild(html_entity_node);

                cur_text_node = text[i..];
                cur_text_node.len = 0;
            },

            '=' => {
                // An article or line start with an '=' is expected to be a heading.
                if (i == 0 or (i > 0 and text[i - 1] == '\n')) {
                    try createAndAppendTextNodeIfNotEmpty(&doc, cur_text_node);

                    i = try parseHeading(&doc, text, i, t);

                    cur_text_node = text[i..];
                    cur_text_node.len = 0;
                } else {
                    // Text.
                    cur_text_node.len += 1;
                    i += 1;
                }
            },

            else => {
                // Default, text.
                cur_text_node.len += 1;
                i += 1;
            },
        }
    }

    try createAndAppendTextNodeIfNotEmpty(&doc, cur_text_node);

    return doc;
}

///////////////////////////////////////////////////////////////////////
// Node type specific parser functions.

/// `i` should point to the opening `<`
fn parseHtmlTag(parent: *MWAstNode, text: []const u8, start: usize, t: anytype) Error!usize {
    const FAIL = Error.InvalidHtmlTag;
    t.begin(start);

    const html_tag_node = try parent.createChildNode(.{ .html_tag = .{} });
    defer parent.appendChild(html_tag_node);

    // Skip opening '<'.
    var i = try advance(start, "<".len, text, FAIL);
    if (std.ascii.isWhitespace(text[i]))
        return t.err(FAIL);
    if (text[i] == '/')
        return t.err(Error.SpuriousClosedHtmlTag);

    // Find end of the tag name.
    const tag_name_start = i;
    i = try skipUntilOneOf(text, &.{ ' ', '\t', '\n', '/', '>' }, i, FAIL);
    if (i == tag_name_start)
        return t.err(FAIL);
    const tag_name = text[tag_name_start..i];

    // Skip whitespace after tag name.
    i = try skipWhileOneOf(text, &.{ ' ', '\t', '\n' }, i, FAIL);

    // Parse attributes i.e. `<tag attr1=value1 ... />`.
    var attrs = HtmlTag.AttrList{};
    while (std.mem.count(u8, " \n\t/>=", text[i .. i + 1]) == 0) {
        if (i >= text.len)
            return t.err(FAIL);

        // Attribute name.
        const attr_name_start = i;
        i = try skipUntilOneOf(text, " \n\t/>=", i, FAIL);
        if (attr_name_start == i)
            return t.err(FAIL);
        const attr_name = text[attr_name_start..i];

        // Skip whitespace after attr name.
        i = try skipWhileOneOf(text, &.{ ' ', '\t', '\n' }, i, FAIL);

        // Skip '='.
        if (text[i] != '=')
            return t.err(FAIL);
        i += "=".len;

        // Skip whitespace after =.
        i = try skipWhileOneOf(text, &.{ ' ', '\t', '\n' }, i, FAIL);

        // Skip quote and remember if it was ' or " or not present.
        var quote: u8 = text[i];
        if (quote == '"' or quote == '\'') {
            i += 1;
        } else {
            quote = 0;
        }

        // Seek attribute value.
        const attr_value_start = i;
        switch (quote) {
            '\'' => i = try skipUntilOneOf(text, &.{'\''}, i, FAIL),
            '"' => i = try skipUntilOneOf(text, &.{'"'}, i, FAIL),
            0 => i = try skipUntilOneOf(text, &.{ ' ', '\t', '\n', '/', '>' }, i, FAIL),
            else => unreachable,
        }
        const attr_value = text[attr_value_start..i];

        // Skip quote if it existed.
        if (quote != 0)
            i += 1;

        const attr_node = try parent.a.create(HtmlTag.AttrNode);
        attr_node.*.data = .{ .name = attr_name, .value = attr_value };
        attrs.append(attr_node);

        // Skip whitespace after attr name.
        i = try skipWhileOneOf(text, &.{ ' ', '\t', '\n' }, i, FAIL);
    }

    html_tag_node.*.n = .{ .html_tag = .{ .tag_name = tag_name, .attrs = attrs } };

    // Handle self closing tag
    if (text[i] == '/') {
        if (i + 1 < text.len and text[i + 1] == '>')
            return i + "/>".len;
        return t.err(FAIL);
    }

    // Skip closing '>'.
    if (text[i] != '>')
        return t.err(FAIL);
    i += ">".len;

    // These tags must be self closed and support "only open" form like `<br>`
    const forbiddenClosingTagNames = [_][]const u8{ "area", "base", "basefont", "br", "col", "frame", "hr", "img", "input", "isindex", "link", "meta", "param" };
    inline for (forbiddenClosingTagNames) |_tag_name| {
        if (std.mem.eql(u8, _tag_name, tag_name))
            return i;
    }

    // `<nowiki>` and `<math>` do not look for nested wikicode elements.
    if (std.mem.eql(u8, tag_name, "math"))
        return try parseHtmlTagEscaped(html_tag_node, "</math", text, i, Error.InvalidMathTag, t);
    if (std.mem.eql(u8, tag_name, "nowiki")) {
        return try parseHtmlTagEscaped(html_tag_node, "</nowiki", text, i, Error.InvalidMathTag, t);
    }

    var cur_text_node = text[i..];
    cur_text_node.len = 0;
    while (i < text.len) {
        if (nextEql(text, "</", i)) {
            // Tag end.
            i += "</".len;

            try createAndAppendTextNodeIfNotEmpty(html_tag_node, cur_text_node);

            // Get close tag name.
            const close_tag_name_start = i;
            i = try skipUntilOneOf(text, &.{ ' ', '\t', '\n', '/', '>' }, i, FAIL);
            const close_tag_name = text[close_tag_name_start..i];

            // Validate.
            if (!std.mem.eql(u8, close_tag_name, tag_name))
                return t.err(FAIL);

            // Skip whitespace after tag name.
            i = try skipWhileOneOf(text, &.{ ' ', '\t', '\n' }, i, FAIL);
            if (text[i] != '>')
                return t.err(FAIL);

            return i + 1;
        } else if (nextEql(text, "<!--", i)) {
            // HTML comment.
            try createAndAppendTextNodeIfNotEmpty(html_tag_node, cur_text_node);

            i = try skipHtmlComment(text, i, t);

            cur_text_node = text[i..];
            cur_text_node.len = 0;
        } else if (text[i] == '<') {
            // Nested html tag.
            try createAndAppendTextNodeIfNotEmpty(html_tag_node, cur_text_node);

            i = try parseHtmlTag(html_tag_node, text, i, t);

            cur_text_node = text[i..];
            cur_text_node.len = 0;
        } else if (nextEql(text, "{{", i)) {
            // Template.
            try createAndAppendTextNodeIfNotEmpty(html_tag_node, cur_text_node);

            i = try parseTemplate(html_tag_node, text, i, t);

            cur_text_node = text[i..];
            cur_text_node.len = 0;
        } else {
            // Text.
            i += 1;
            cur_text_node.len += 1;
        }
    }

    return t.err(FAIL);
}

/// Finds `end_tag` without looking for nested wikicode elements
///
/// Tag end should have "</" prepended
fn parseHtmlTagEscaped(html_tag_node: *MWAstNode, tag_end: []const u8, text: []const u8, pos: usize, E: Error, t: anytype) Error!usize {
    t.begin(pos);

    const content_start = pos;
    var i = pos;
    while (i < text.len - tag_end.len) : (i += 1) {
        if (std.mem.eql(u8, text[i .. i + tag_end.len], tag_end)) {
            const content_node = try html_tag_node.createChildNode(.{ .text = text[content_start..i] });
            html_tag_node.appendChild(content_node);
            i += tag_end.len;

            i = try skipWhileOneOf(text, " \t\n", i, E);
            if (text[i] != '>')
                return E;

            return i + ">".len;
        }
    }

    return t.err(E);
}

fn parseWikiLink(parent: *MWAstNode, text: []const u8, start: usize, t: anytype) Error!usize {
    const FAIL = Error.BadWikiLink;
    t.begin(start);

    const wiki_link_node = try parent.createChildNode(.{ .wiki_link = .{ .article = "" } });
    defer parent.appendChild(wiki_link_node);

    // Skip [[ and single line whitespace after.
    var i = start + "[[".len;
    i = try skipWhileOneOf(text, &.{ ' ', '\t' }, i, FAIL);
    try errOnLineBreak(text[i], FAIL);

    // Find end of article.
    var article_start = i;
    var namespace: WikiLink.Namepace = .Main;
    i = try skipUntilOneOf(text, &.{ '\n', ':', '|', ']' }, i, FAIL);

    if (text[i] == ':') {
        // Namespaced link. i.e. File:img.png
        namespace = WikiLink.Namepace.fromStr(text[article_start..i]);
        article_start = i + ":".len;
        i = try skipUntilOneOf(text, &.{ '\n', '|', ']' }, i, FAIL);
    }
    try errOnLineBreak(text[i], FAIL);

    const article = std.mem.trimRight(u8, text[article_start..i], " \t");

    // write data to node
    wiki_link_node.*.n = .{ .wiki_link = .{ .article = article, .namespace = namespace } };

    // Skip whitespace after article name.
    i = try skipWhileOneOf(text, &.{ ' ', '\t' }, i, FAIL);
    try errOnLineBreak(text[i], FAIL);

    if (nextEql(text, "]]", i)) {
        // No arguments.
        return i + "]]".len;
    }

    if (text[i] != '|')
        return t.err(FAIL);

    i += "|".len;

    while (i < text.len) {
        i, const last = try parseArgument(wiki_link_node, text, i, Error.BadWikiLinkArg, t);

        if (last)
            return i;
    }

    return t.err(FAIL);
}

fn parseTemplate(parent: *MWAstNode, text: []const u8, start: usize, t: anytype) Error!usize {
    const FAIL = Error.BadTemplate;
    t.begin(start);

    var i = start + "{{".len;

    // Get template name.
    const template_name_start = i;
    i = try skipUntilOneOf(text, &.{ '\n', '}', '|' }, i, FAIL);
    const template_name = text[template_name_start..i];

    const template_node = try parent.createChildNode(.{ .template = .{ .name = template_name } });
    defer parent.appendChild(template_node);

    // Skip whitespace after template name.
    i = try skipWhileOneOf(text, &.{ '\n', ' ', '\t' }, i, FAIL);

    // Template closes.
    if (nextEql(text, "}}", i))
        return i + "}}".len;

    if (text[i] != '|')
        return t.err(FAIL);
    i += "|".len;

    // Parse args.
    while (i < text.len) {
        i, const last = try parseArgument(template_node, text, i, Error.BadTemplateArg, t);
        if (last)
            return i;
    }

    return t.err(FAIL);
}

/// Parses template / wikilink argument with start pointing to the first character
fn parseArgument(parent: *MWAstNode, text: []const u8, start: usize, E: Error, t: anytype) Error!struct { usize, bool } {
    std.debug.assert(parent.nodeType() == .wiki_link or parent.nodeType() == .template);
    t.begin(start);

    var arg_node = try parent.createChildNode(.{ .argument = .{} });
    defer parent.appendChild(arg_node);

    var i = try skipWhileOneOf(text, " \t\n", start, E);

    const arg_start = i;

    var cur_text_node = text[i..];
    cur_text_node.len = 0;

    while (i < text.len) {
        switch (text[i]) {
            '=' => {
                const arg_key = std.mem.trimRight(u8, text[arg_start..i], " \t\n");
                arg_node.*.n = .{ .argument = .{ .key = arg_key } };

                i += "=".len;

                i = try skipWhileOneOf(text, " \t", i, E);

                // DOI links are raw text in templates.
                if (parent.nodeType() == .template and std.mem.eql(u8, "doi", arg_key)) {
                    const doi_text_start = i;
                    i = try skipUntilOneOf(text, &.{ ' ', '|', '}' }, i, E);
                    const doi_text_node = try parent.createChildNode(.{ .text = text[doi_text_start..i] });
                    arg_node.appendChild(doi_text_node);
                    i = try skipWhileOneOf(text, " \t\n", i, E);
                    const last = nextEql(text, "}}", i);
                    return .{ i + "}}".len, last };
                }

                cur_text_node = text[i..];
                cur_text_node.len = 0;
            },
            '<' => {
                try createAndAppendTextNodeIfNotEmpty(arg_node, cur_text_node);

                if (nextEql(text, "!--", i + 1)) {
                    // Comment.
                    i = try skipHtmlComment(text, i, t);
                } else {
                    // Html tag.
                    i = try parseHtmlTag(arg_node, text, i, t);
                }

                cur_text_node = text[i..];
                cur_text_node.len = 0;
            },
            '}' => {
                if (parent.nodeType() == .template and nextEql(text, "}", i + 1)) {
                    // Done. this is the last argument
                    if (cur_text_node.len > 0 and cur_text_node[cur_text_node.len - 1] == '\n')
                        cur_text_node.len -= 1;
                    try createAndAppendTextNodeIfNotEmpty(arg_node, cur_text_node);
                    return .{ i + "}}".len, true };
                } else {
                    // Continue with } as text.
                    i += 1;
                    cur_text_node.len += 1;
                }
            },
            '{' => {
                if (nextEql(text, "{", i + 1)) {
                    // Nested tag.
                    try createAndAppendTextNodeIfNotEmpty(arg_node, cur_text_node);

                    i = try parseTemplate(arg_node, text, i, t);

                    cur_text_node = text[i..];
                    cur_text_node.len = 0;
                } else {
                    // Continue with { as text.
                    i += 1;
                    cur_text_node.len += 1;
                }
            },
            '|' => {
                // Done!
                if (cur_text_node.len > 0 and cur_text_node[cur_text_node.len - 1] == '\n')
                    cur_text_node.len -= 1;
                try createAndAppendTextNodeIfNotEmpty(arg_node, cur_text_node);
                return .{ i + "|".len, false };
            },
            '[' => {
                // Link.
                if (nextEql(text, "[", i + 1)) {
                    // Wikilink.
                    try createAndAppendTextNodeIfNotEmpty(arg_node, cur_text_node);

                    i = try parseWikiLink(arg_node, text, i, t);

                    cur_text_node = text[i..];
                    cur_text_node.len = 0;
                } else if (nextEql(text, "[http", i + 1)) {
                    // External link.
                    try createAndAppendTextNodeIfNotEmpty(arg_node, cur_text_node);

                    i = try parseExternalLink(arg_node, text, i, t);

                    cur_text_node = text[i..];
                    cur_text_node.len = 0;
                } else {
                    i += 1;
                    cur_text_node.len += 1;
                }
            },
            ']' => {
                if (parent.nodeType() == .wiki_link and nextEql(text, "]", i + 1)) {
                    // Done. this is the last argument
                    try createAndAppendTextNodeIfNotEmpty(arg_node, cur_text_node);
                    return .{ i + "]]".len, true };
                } else {
                    // Continue with ] as text.
                    i += 1;
                    cur_text_node.len += 1;
                }
            },
            '&' => {
                i, const html_entity_node = parseHtmlEntity(arg_node, text, i) catch |err| switch (err) {
                    Error.IncompleteHtmlEntity => {
                        // Failover to text.
                        i += 1;
                        cur_text_node.len += 1;
                        continue;
                    },
                    else => return err,
                };

                try createAndAppendTextNodeIfNotEmpty(arg_node, cur_text_node);
                arg_node.appendChild(html_entity_node);

                cur_text_node = text[i..];
                cur_text_node.len = 0;
            },
            else => {
                i += 1;
                cur_text_node.len += 1;
            },
        }
    }

    return E;
}

fn parseExternalLink(parent: *MWAstNode, text: []const u8, start: usize, t: anytype) Error!usize {
    const FAIL = Error.BadExternalLink;
    t.begin(start);

    // skip opening [
    var i = start + "[".len;

    // extract url
    const url_start = i;
    i = try skipUntilOneOf(text, &.{ '\n', ' ', '\t', ']' }, i, FAIL);
    try errOnLineBreak(text[i], FAIL);
    const url = text[url_start..i];

    // skip whitespace after url
    i = try skipWhileOneOf(text, &.{ ' ', '\t' }, i, FAIL);
    try errOnLineBreak(text[i], FAIL);

    // if no name found, return
    if (text[i] == ']') {
        const external_link_node = try parent.createChildNode(.{ .external_link = .{ .url = url } });
        parent.appendChild(external_link_node);
        return i + 1;
    }

    // get display name
    const name_start = i;
    i = try skipUntilOneOf(text, &.{ '\n', ']' }, i, FAIL);
    try errOnLineBreak(text[i], FAIL);
    const name = text[name_start..i];

    if (text[i] != ']')
        return t.err(FAIL);

    const external_link_node = try parent.createChildNode(.{
        .external_link = .{ .url = url, .title = name },
    });
    parent.appendChild(external_link_node);

    return i + 1;
}

/// attempts to find html entity from '&' start character
///
/// Returns `Error.IncompleteHtmlEntity` if not found
fn parseHtmlEntity(parent: *MWAstNode, text: []const u8, start: usize) Error!struct { usize, *MWAstNode } {
    const FAIL = Error.IncompleteHtmlEntity;

    var i: usize = try advance(start, "&".len, text, FAIL);

    const MAX_ENTITY_LEN = blk: {
        if (i + 6 < text.len)
            break :blk i + 6;
        break :blk text.len;
    };

    if (text[i] == '#') {
        // Numeric.
        i += "#".len;
        if (i < text.len and text[i] == 'x') {
            // Hex.
            i += "x".len;
        }
        var n_digits: usize = 0;
        while (i < MAX_ENTITY_LEN) : (i += 1) {
            if (text[i] == ';') {
                if (n_digits < 2)
                    return FAIL;
                const html_entity_node = try parent.createChildNode(.{ .html_entity = text[start .. i + 1] });
                return .{ i + 1, html_entity_node };
            }
            if (std.ascii.isDigit(text[i])) {
                n_digits += 1;
            } else {
                return FAIL;
            }
        }
    } else {
        // Character.
        while (i < MAX_ENTITY_LEN) : (i += 1) {
            if (text[i] == ';') {
                const html_entity_node = try parent.createChildNode(.{ .html_entity = text[start .. i + 1] });
                return .{ i + 1, html_entity_node };
            }
        }
    }

    return FAIL;
}

fn parseHeading(parent: *MWAstNode, text: []const u8, start: usize, t: anytype) Error!usize {
    const FAIL = Error.IncompleteHeading;
    t.begin(start);

    const heading_node = try parent.createChildNode(.{ .heading = .{ .level = 0 } });
    defer parent.appendChild(heading_node);

    var i: usize = start;

    // Parse leading =, remembering how many.
    var level: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '=' => level += 1,
            '\n' => return t.err(FAIL),
            else => break,
        }
    }

    heading_node.*.n = .{ .heading = .{ .level = level } };

    i = try skipWhileOneOf(text, &.{ ' ', '\t', '\n' }, i, FAIL);
    try errOnLineBreak(text[i], FAIL);

    var cur_text_node = text[i..];
    cur_text_node.len = 0;

    while (i < text.len) {
        switch (text[i]) {
            '<' => {
                // Html comment or tag
                cur_text_node = std.mem.trimRight(u8, cur_text_node, &.{ ' ', '\t' });
                try createAndAppendTextNodeIfNotEmpty(heading_node, cur_text_node);

                if (nextEql(text, "<!--", i)) {
                    i = try skipHtmlComment(text, i, t);
                } else {
                    i = try parseHtmlTag(heading_node, text, i, t);
                }

                cur_text_node = text[i..];
                cur_text_node.len = 0;
            },
            '=' => {
                // End of heading.
                if (!nextEqlCount(text, '=', level, i))
                    return t.err(FAIL);

                cur_text_node = std.mem.trimRight(u8, cur_text_node, &.{ ' ', '\t' });

                const txt_node = try parent.createChildNode(.{ .text = cur_text_node });
                heading_node.appendChild(txt_node);

                return i + level * "=".len;
            },
            '\n' => break,
            else => {
                // Text.
                i += 1;
                cur_text_node.len += 1;
            },
        }
    }

    return t.err(FAIL);
}

/// NOTE: This does not add a table node, it just skips after the closing `|}`
///
/// `pos` should point to the opening `{|`
fn skipTable(text: []const u8, pos: usize, t: anytype) !usize {
    t.begin(pos);

    var i = pos + "{|".len;

    while (i < text.len) {
        i = try skipUntilOneOf(text, &.{'|'}, i, Error.IncompleteTable);
        if (nextEql(text, "}", i + 1))
            return i + "|}".len;
        i += "|".len;
    }

    return t.err(Error.IncompleteTable);
}

/// moves to `pos` to after the comment,
/// or returns `Error.UnclosedHtmlComment` if none is found
///
/// `pos` should point to the first char of `<!--`
fn skipHtmlComment(text: []const u8, pos: usize, t: anytype) !usize {
    t.begin(pos);

    var i = pos + "<!--".len;
    while (i <= text.len - "-->".len) : (i += 1) {
        if (std.mem.eql(u8, text[i .. i + "-->".len], "-->"))
            return i + "-->".len;
    }
    return t.err(Error.UnclosedHtmlComment);
}

///////////////////////////////////////////////////////////////////////
// AstMatching Functions.

/// Runs `callback` on all nodes of type `target`
pub fn traverse(doc: *MWAstNode, target: MWAstNode.NodeType, T: type, ErrorSet: type, callback: fn (n: *MWAstNode, state: T) ErrorSet!void, state: T) ErrorSet!void {
    std.debug.assert(doc.nodeType() == .document);

    if (doc.n_children == 0)
        return;

    std.debug.assert(doc.first_child != null and doc.last_child != null);

    try _traverse(doc, target, T, ErrorSet, callback, state);
}

/// if `n` is of type `target`, calls `callback`
///
/// Vists children recursively
fn _traverse(n: *MWAstNode, target: MWAstNode.NodeType, T: type, ErrorSet: type, callback: fn (n: *MWAstNode, state: T) ErrorSet!void, state: T) ErrorSet!void {
    if (n.nodeType() == target)
        try callback(n, state);

    if (n.n_children == 0)
        return;

    var it = n.first_child;
    while (it) |child| : (it = child.next) {
        try _traverse(child, target, T, ErrorSet, callback, state);
    }
}

///////////////////////////////////////////////////////////////////////
// Parser utility functions.

/// allocates and appends text node IF `text.len > 0`
inline fn createAndAppendTextNodeIfNotEmpty(parent: *MWAstNode, text: []const u8) error{OutOfMemory}!void {
    if (text.len == 0)
        return;
    const txt_node = try parent.createChildNode(.{ .text = text });
    parent.appendChild(txt_node);
}

/// Skips until `i` exceeds `buf.len` (returning `E`) or a character in `stops` is found
inline fn skipUntilOneOf(buf: []const u8, comptime stops: []const u8, i: usize, E: Error) Error!usize {
    var _i = i;

    while (_i < buf.len) : (_i += 1) {
        inline for (stops) |stop| {
            if (buf[_i] == stop)
                return _i;
        }
    }

    return E;
}

/// returns `true` if the needle is present starting at i.
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

/// Safely advance buffer index `i` by count
///
/// Returns `error.AdvanceBeyondBuffer` if i+count goes out of bounds
inline fn advance(i: usize, count: usize, buf: []const u8, E: Error) Error!usize {
    if (i + count < buf.len) {
        return i + count;
    } else {
        return E;
    }
}

/// returns `E` if `ch` is `\n`
inline fn errOnLineBreak(ch: u8, E: Error) Error!void {
    if (ch == '\n')
        return E;
}

/// Skips until `i` exceeds `buf.len` (returning `E`) or a character not in `continues` is found
inline fn skipWhileOneOf(buf: []const u8, comptime continues: []const u8, i: usize, E: Error) Error!usize {
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

///////////////////////////////////////////////////////////////////////
// Utility Tests.

test "Trivial nextEql" {
    try std.testing.expect(nextEql("{{{arg}}\n", "{{{", 0));
    try std.testing.expect(nextEql("{{{arg}}\n", "}}\n", 6));
    try std.testing.expect(!nextEql("{{{arg}}\n", "{{{", 7));
}

test "Trivial nextEqlCount" {
    try std.testing.expect(nextEqlCount("{{{arg}}\n", '{', 3, 0));
    try std.testing.expect(nextEqlCount("{{{arg}}\n", '}', 2, 6));
    try std.testing.expect(!nextEqlCount("{{{arg}}\n", '{', 3, 7));
    try std.testing.expect(!nextEqlCount("== Anarchism=\n", '=', 2, 12));
}

///////////////////////////////////////////////////////////////////////
// Parser Tests.

test "TABLE skips" {
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

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 2);

    switch (doc.first_child.?.n) {
        .text => |t| try std.testing.expectEqualStrings("Very Nice Table!\n", t),
        else => unreachable,
    }

    switch (doc.last_child.?.n) {
        .text => |t| try std.testing.expectEqualStrings("\nGlad the table is over!", t),
        else => unreachable,
    }
}

test "COMMENT fails on unclosed" {
    const wikitext = "<!-- Blah --";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const e = parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expectError(Error.UnclosedHtmlComment, e);
}

test "COMMENT correct" {
    const wikitext = "<!-- Blah Blah -->";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 0);
}

test "COMMENT skips enclosed '-' and embedded tags" {
    const wikitext =
        \\<!--In aquatic amphibians, the liver plays only a small role in processing nitrogen for excretion, and [[ammonia]] is diffused mainly through the skin. The liver of terrestrial amphibians converts ammonia to urea, a less toxic, water-soluble nitrogenous compound, as a means of water conservation. In some species, urea is further converted into [[uric acid]]. [[Bile]] secretions from the liver collect in the gall bladder and flow into the small intestine. In the small intestine, enzymes digest carbohydrates, fats, and proteins. Salamanders lack a valve separating the small intestine from the large intestine. Salt and water absorption occur in the large intestine, as well as mucous secretion to aid in the transport of faecal matter, which is passed out through the [[cloaca]].<ref name="Anatomy" />---Omitting this until a more reliable source can be found.--->
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 0);
}

test "HTML_ENTITY fails over malformed" {
    const non_numerical_num: []const u8 = "&#hello;";
    const too_long: []const u8 = "&#12345;";
    const too_few_digits: []const u8 = "&#1;";
    const unclosed: []const u8 = "&hello";

    const cases = [_][]const u8{ non_numerical_num, too_long, too_few_digits, unclosed };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const doc = try parseDocument(a, case, TestTrace(Error){});
        try std.testing.expect(doc.n_children == 1);
        try std.testing.expect(doc.first_child.?.nodeType() == .text);
    }
}

test "HTML_ENTITY correct parse" {
    const big_num: []const u8 = "&#1234;";
    const sm_num: []const u8 = "&#11;";
    const hex_num: []const u8 = "&#x20;";
    const s_one: []const u8 = "&hello;";
    const s_two: []const u8 = "&quot;";

    const entities = [_][]const u8{ big_num, sm_num, hex_num, s_one, s_two };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, big_num ++ sm_num ++ hex_num ++ s_one ++ s_two, TestTrace(Error){});

    try std.testing.expect(doc.n_children == entities.len);

    var child_it = doc.first_child.?;
    for (0..entities.len) |i| {
        try std.testing.expect(child_it.nodeType() == .html_entity);
        switch (child_it.n) {
            .html_entity => |he| try std.testing.expectEqualStrings(entities[i], he),
            else => unreachable,
        }
        if (child_it.next) |next|
            child_it = next;
    }
}

test "EXTERNAL_LINK no title" {
    const wikitext = "[https://example.com]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const el_node = doc.firstNode(.external_link).?;
    const el_data = try el_node.asExternalLink();

    try std.testing.expect(el_data.title == null);
    try std.testing.expectEqualStrings("https://example.com", el_data.url);
}

test "EXTERNAL_LINK title" {
    const wikitext = "[http://dwardmac.pitzer.edu Anarchy Archives]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const el_node = doc.firstNode(.external_link).?;
    const el_data = try el_node.asExternalLink();
    try std.testing.expectEqualStrings("http://dwardmac.pitzer.edu", el_data.url);
    try std.testing.expectEqualStrings("Anarchy Archives", el_data.title.?);
}

test "TEMPLATE no args" {
    const wikitext = "{{Anarchism sidebar}}";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const template_node = doc.firstNode(.template).?;
    try std.testing.expect(template_node.n_children == 0);
    try std.testing.expectEqualStrings("Anarchism sidebar", (try template_node.asTemplate()).name);
}

test "TEMPLATE text argument no name" {
    const wikitext = "{{Main|Definition of anarchism and libertarianism}}";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const template_node = doc.firstNode(.template).?;
    try std.testing.expect(template_node.n_children == 1);
    try std.testing.expectEqualStrings("Main", (try template_node.asTemplate()).name);

    const arg_node = template_node.firstNode(.argument).?;
    try std.testing.expect((try arg_node.asArg()).key == null);

    const arg_text_value = arg_node.firstNode(.text).?;
    try std.testing.expectEqualStrings("Definition of anarchism and libertarianism", try arg_text_value.asText());
}

test "TEMPLATE child as arg" {
    const wikitext = "{{Main|{{Definition of anarchism and libertarianism}}}}";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const template_node = doc.firstNode(.template).?;
    try std.testing.expect(template_node.n_children == 1);
    try std.testing.expectEqualStrings("Main", (try template_node.asTemplate()).name);

    const arg_node = template_node.firstNode(.argument).?;
    try std.testing.expect((try arg_node.asArg()).key == null);

    const nested_template_node = arg_node.firstNode(.template).?;
    const nested_template_data = try nested_template_node.asTemplate();
    try std.testing.expectEqualStrings("Definition of anarchism and libertarianism", nested_template_data.name);
}

test "TEMPLATE parses with KV arg" {
    const wikitext = "{{Main|date=May 2023}}";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const template_node = doc.firstNode(.template).?;
    try std.testing.expect(template_node.n_children == 1);
    try std.testing.expectEqualStrings("Main", (try template_node.asTemplate()).name);

    const arg_node = template_node.firstNode(.argument).?;
    try std.testing.expectEqualStrings("date", (try arg_node.asArg()).key.?);

    const text_arg_value_node = arg_node.firstNode(.text).?;
    try std.testing.expectEqualStrings("May 2023", try text_arg_value_node.asText());
}

test "TEMPLATE doi link is escaped from parsing" {
    const wikitext =
        \\<ref name="Winston">{{cite journal| first=Jay |last=Winston |title=The Annual Course of Zonal Mean Albedo as Derived From ESSA 3 and 5 Digitized Picture Data |journal=Monthly Weather Review |volume=99 |pages=818–827| bibcode=1971MWRv...99..818W| date=1971| doi=10.1175/1520-0493(1971)099<0818:TACOZM>2.3.CO;2| issue=11|doi-access=free}}</ref>
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    const html_tag_node = doc.firstNode(.html_tag).?;
    try std.testing.expect(html_tag_node.n_children == 1);

    const template_node = html_tag_node.firstNode(.template).?;
    const template_node_name = (try template_node.asTemplate()).name;
    try std.testing.expectEqualStrings("cite journal", template_node_name);

    const doi_arg_node = (try template_node.getArgByKey("doi")).?;
    const doi_text_node = doi_arg_node.firstNode(.text).?;
    try std.testing.expectEqualStrings("10.1175/1520-0493(1971)099<0818:TACOZM>2.3.CO;2", try doi_text_node.asText());
}

test "TEMPLATE html comment ends KV arg" {
    const wikitext =
        \\{{Infobox region symbols|country=United States
        \\|bird = [[Northern flicker|Yellowhammer]], [[wild turkey]]<!--State game bird-->
        \\|butterfly= [[Eastern tiger swallowtail]]
        \\}}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const tmpl_node = doc.firstNode(.template).?;
    const bird_arg_node = (try tmpl_node.getArgByKey("bird")).?;
    try std.testing.expect(bird_arg_node.n_children == 3);
    try std.testing.expectEqualStrings("bird", (try bird_arg_node.asArg()).key.?);

    const bird_arg_value1 = bird_arg_node.first_child.?;
    try std.testing.expectEqualStrings("Northern flicker", (try bird_arg_value1.asWikiLink()).article);

    const bird_arg_value2 = bird_arg_value1.next.?;
    try std.testing.expectEqualStrings(", ", try bird_arg_value2.asText());

    const bird_arg_value3 = bird_arg_value2.next.?;
    try std.testing.expectEqualStrings("wild turkey", (try bird_arg_value3.asWikiLink()).article);
}

test "TEMPLATE '[' treated as text" {
    const wikitext = "{{cite web |url=http://lcweb2.loc.gov/diglib/ihas/loc.natlib.ihas.100010615/full.html |title=Materna (O Mother Dear, Jerusalem) / Samuel Augustus Ward [hymnal&#93;: Print Material Full Description: Performing Arts Encyclopedia, Library of Congress |publisher=Lcweb2.loc.gov |date=2007-10-30 |access-date=2011-08-20 |url-status=live |archive-url=https://web.archive.org/web/20110605020952/http://lcweb2.loc.gov/diglib/ihas/loc.natlib.ihas.100010615/full.html |archive-date=June 5, 2011}}";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});
    try std.testing.expect(doc.n_children == 1);

    const tmpl_node = doc.firstNode(.template).?;
    const title_arg_node = (try tmpl_node.getArgByKey("title")).?;
    try std.testing.expect(title_arg_node.n_children == 3);
    const title_text_node = title_arg_node.first_child.?;
    try std.testing.expectEqualStrings("Materna (O Mother Dear, Jerusalem) / Samuel Augustus Ward [hymnal", try title_text_node.asText());

    const title_entity_node = title_text_node.next.?;
    try std.testing.expectEqualStrings("&#93;", try title_entity_node.asHtmlEntity());

    const title_text_node2 = title_entity_node.next.?;
    try std.testing.expectEqualStrings(": Print Material Full Description: Performing Arts Encyclopedia, Library of Congress ", try title_text_node2.asText());
}

test "WIKILINK no title" {
    const wikitext = "[[Index of Andorra-related articles]]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});
    try std.testing.expect(doc.n_children == 1);

    switch (doc.first_child.?.n) {
        .wiki_link => |wl| {
            try std.testing.expectEqualStrings("Index of Andorra-related articles", wl.article);
        },
        else => unreachable,
    }
}

test "WIKILINK title" {
    const wikitext = "[[Andorra–Spain border|Spanish border]]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const link_node = doc.firstNode(.wiki_link).?;
    const article = (try link_node.asWikiLink()).article;
    try std.testing.expectEqualStrings("Andorra–Spain border", article);

    const arg_node = link_node.firstNode(.argument).?;
    const arg_value_text_node = arg_node.firstNode(.text).?;
    try std.testing.expectEqualStrings("Spanish border", try arg_value_text_node.asText());
}

test "WIKILINK wikitionary namespace" {
    const wikitext = "[[wikt:phantasm|phantasm]]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});
    try std.testing.expect(doc.n_children == 1);

    const link_node = doc.firstNode(.wiki_link).?;
    const link_data = try link_node.asWikiLink();

    try std.testing.expect(link_data.namespace == .Wikitionary);
    try std.testing.expectEqualStrings("phantasm", link_data.article);
}

test "WIKILINK image multiple args" {
    const wikitext = "[[File:Paolo Monti - Servizio fotografico (Napoli, 1969) - BEIC 6353768.jpg|thumb|upright=.7|[[Zeno of Citium]] ({{Circa|334|262 BC}}), whose *[[Republic (Zeno)|Republic]]* inspired [[Peter Kropotkin]]{{Sfn|Marshall|1993|p=70}}]]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const wl_node = doc.firstNode(.wiki_link).?;
    const wl_data = try wl_node.asWikiLink();

    try std.testing.expect(wl_data.namespace == .File);
    try std.testing.expectEqualStrings("Paolo Monti - Servizio fotografico (Napoli, 1969) - BEIC 6353768.jpg", wl_data.article);
    try std.testing.expect(wl_node.n_children == 3);

    const arg1_node = wl_node.firstNode(.argument).?;
    const arg1_text = arg1_node.firstNode(.text).?;
    try std.testing.expectEqualStrings("thumb", try arg1_text.asText());

    const arg2_node = arg1_node.next.?;
    try std.testing.expect(arg2_node.nodeType() == .argument);
    try std.testing.expectEqualStrings("upright", (try arg2_node.asArg()).key.?);
    const arg2_text = arg2_node.firstNode(.text).?;
    try std.testing.expectEqualStrings(".7", try arg2_text.asText());

    const arg3_node = arg2_node.next.?;
    try std.testing.expect(arg2_node.nodeType() == .argument);
    const arg3_wiki_link = arg3_node.firstNode(.wiki_link).?;
    try std.testing.expectEqualStrings("Zeno of Citium", (try arg3_wiki_link.asWikiLink()).article);
    const arg3_text = arg3_wiki_link.next.?;
    try std.testing.expectEqualStrings(" (", try arg3_text.asText());
    const arg3_template = arg3_text.next.?;
    try std.testing.expectEqualStrings("Circa", (try arg3_template.asTemplate()).name);
}

test "HTML_TAG Trivial Correct" {
    const wikitext = "<ref>Hello</ref>";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});
    try std.testing.expect(doc.n_children == 1);

    const html_tag_node = doc.firstNode(.html_tag).?;
    const html_tag_data = try html_tag_node.asHtmlTag();
    try std.testing.expectEqualStrings("ref", html_tag_data.tag_name);
    try std.testing.expect(html_tag_node.n_children == 1);

    const tag_text = html_tag_node.firstNode(.text).?;
    try std.testing.expectEqualStrings("Hello", try tag_text.asText());
}

test "HTML_TAG Wierd Spacing" {
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

        const doc = try parseDocument(a, case, TestTrace(Error){});

        try std.testing.expect(doc.n_children == 1);

        const html_tag_node = doc.firstNode(.html_tag).?;
        const html_tag_data = try html_tag_node.asHtmlTag();
        try std.testing.expectEqualStrings("ref", html_tag_data.tag_name);
        try std.testing.expect(html_tag_node.n_children == 1);

        const tag_text = html_tag_node.firstNode(.text).?;
        try std.testing.expectEqualStrings("Hello", try tag_text.asText());
    }
}

test "HTML_TAG decodes attributes correctly" {
    const wikitext = "<ref kind='web'>citation</ref>";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    const html_tag_node = doc.firstNode(.html_tag).?;
    const html_tag_data = try html_tag_node.asHtmlTag();
    const tag_attrs = html_tag_data.attrs;

    try std.testing.expect(tag_attrs.len == 1);
    try std.testing.expectEqualStrings("kind", tag_attrs.first.?.data.name);
    try std.testing.expectEqualStrings("web", tag_attrs.first.?.data.value);

    const tag_text_node = html_tag_node.firstNode(.text).?;
    try std.testing.expectEqualStrings("citation", try tag_text_node.asText());
}

test "HTML_TAG decodes attribute without quotes" {
    const wikitext = "<ref name=Maine />";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    const html_tag_node = doc.firstNode(.html_tag).?;
    const html_tag_data = try html_tag_node.asHtmlTag();
    try std.testing.expectEqualStrings("ref", html_tag_data.tag_name);
    try std.testing.expect(html_tag_node.n_children == 0);

    const tag_attrs = html_tag_data.attrs;
    try std.testing.expect(tag_attrs.len == 1);
    try std.testing.expectEqualStrings("name", tag_attrs.first.?.data.name);
    try std.testing.expectEqualStrings("Maine", tag_attrs.first.?.data.value);
}

test "HTML_TAG decodes with nested comment" {
    const wikitext = "<ref kind='web'>cit<!-- Skip Me -->ation</ref>";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});
    try std.testing.expect(doc.n_children == 1);

    const html_tag_node = doc.firstNode(.html_tag).?;
    const html_tag_data = try html_tag_node.asHtmlTag();
    try std.testing.expectEqualStrings("ref", html_tag_data.tag_name);
    try std.testing.expect(html_tag_node.n_children == 2);

    const tag_attrs = html_tag_data.attrs;
    try std.testing.expect(tag_attrs.len == 1);
    try std.testing.expectEqualStrings("kind", tag_attrs.first.?.data.name);
    try std.testing.expectEqualStrings("web", tag_attrs.first.?.data.value);

    const tag_text1 = html_tag_node.firstNode(.text).?;
    try std.testing.expectEqualStrings("cit", try tag_text1.asText());

    const tag_text2 = tag_text1.next.?;
    try std.testing.expectEqualStrings("ation", try tag_text2.asText());
}

test "HTML_TAG decodes nested tags" {
    const wikitext = "<div>Start<div>Middle</div>End</div>";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const html_tag_node = doc.firstNode(.html_tag).?;
    const html_tag_data = try html_tag_node.asHtmlTag();
    try std.testing.expectEqualStrings("div", html_tag_data.tag_name);
    try std.testing.expect(html_tag_node.n_children == 3);

    const tag_attrs = html_tag_data.attrs;
    try std.testing.expect(tag_attrs.len == 0);

    const start_text_node = html_tag_node.firstNode(.text).?;
    try std.testing.expectEqualStrings("Start", try start_text_node.asText());

    const nested_html_tag_node = start_text_node.next.?;
    const nested_html_tag_data = try nested_html_tag_node.asHtmlTag();
    try std.testing.expect(nested_html_tag_data.attrs.len == 0);
    try std.testing.expect(nested_html_tag_node.n_children == 1);
    try std.testing.expectEqualStrings("div", nested_html_tag_data.tag_name);
    const nested_text = nested_html_tag_node.firstNode(.text).?;
    try std.testing.expectEqualStrings("Middle", try nested_text.asText());

    const end_text_node = nested_html_tag_node.next.?;
    try std.testing.expectEqualStrings("End", try end_text_node.asText());
}

test "HTML_TAG decodes wrapped template" {
    const wikitext =
        \\<div>
        \\{{Anarchism sidebar}}
        \\</div>
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});
    try std.testing.expect(doc.n_children == 1);
}

test "HTML_TAG <math> ignores '{' and '}'" {
    const wikitext =
        \\<math display="block">F = \frac{MS_\text{Treatments}}{MS_\text{Error}} = {{SS_\text{Treatments} / (I-1)} \over {SS_\text{Error} / (n_T-I)}}</math
        \\>
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    const html_tag_node = doc.firstNode(.html_tag).?;
    const tag_content = html_tag_node.firstNode(.text).?;
    try std.testing.expectEqualStrings(
        \\F = \frac{MS_\text{Treatments}}{MS_\text{Error}} = {{SS_\text{Treatments} / (I-1)} \over {SS_\text{Error} / (n_T-I)}}
    , try tag_content.asText());
}

test "HTML_TAG <math> ignores '<'" {
    const wikitext =
        \\<math>\hat{\sigma}_\text{OC} < 0.1</math>
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    const html_tag_node = doc.firstNode(.html_tag).?;
    const tag_content = html_tag_node.firstNode(.text).?;

    try std.testing.expectEqualStrings(
        \\\hat{\sigma}_\text{OC} < 0.1
    , try tag_content.asText());
}

test "HTML_TAG nowiki is respected" {
    const wikitext =
        \\<nowiki> "#$%&'()*+,-./0123456789:;<=>?</nowiki>
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    const html_tag_node = doc.firstNode(.html_tag).?;
    const tag_content = html_tag_node.firstNode(.text).?;

    try std.testing.expectEqualStrings(
        \\ "#$%&'()*+,-./0123456789:;<=>?
    , try tag_content.asText());
}

test "HTML_TAG br, hr must be self closed" {
    const wikitext = "<br ><br /><br name='hi'><hr>";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 4);
}

test "HEADING rejects malformed headings" {
    const unclosed1: []const u8 =
        \\== Anarchism
        \\
    ;
    const unclosed2: []const u8 =
        \\== Anarchism=
        \\
    ;
    const bad_line_break: []const u8 =
        \\== Anarchism
        \\==
        \\
    ;
    const cases = [_][]const u8{ unclosed1, unclosed2, bad_line_break };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const e = parseDocument(a, case, TestTrace(Error){});
        try std.testing.expectError(Error.IncompleteHeading, e);
    }
}

test "HEADING well formed with some text" {
    const wikitext =
        \\= Blah Blah Blah =
        \\Blah Blah Blah
        \\Some more Blah
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 2);

    const heading_node = doc.first_child.?;
    try std.testing.expect((try heading_node.asHeading()).level == 1);
    const heading_text_node = heading_node.first_child.?;
    try std.testing.expectEqualStrings("Blah Blah Blah", try heading_text_node.asText());

    const text_node = heading_node.next.?;
    try std.testing.expectEqualStrings("\nBlah Blah Blah\nSome more Blah\n", try text_node.asText());
}

test "HEADING embedded html with attributes" {
    const wikitext =
        \\=== Computing <span class="anchor" id="Computing codes"></span> ===
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const heading_node = doc.first_child.?;
    try std.testing.expect((try heading_node.asHeading()).level == 3);

    const heading_text_node = heading_node.first_child.?;
    try std.testing.expectEqualStrings("Computing", try heading_text_node.asText());
}

test "HEADING parses correctly with following html comment" {
    const wikitext = "===Molecular geometry===<!-- This section is linked from [[Nylon]] -->";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const heading_node = doc.first_child.?;
    const heading_text_node = heading_node.first_child.?;
    try std.testing.expectEqualStrings("Molecular geometry", try heading_text_node.asText());
}

test "HEADING parses correctly with inline html comment" {
    const wikitext = "==Scientific viewpoints<!--linked from 'Evolution of morality'-->==";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const heading_node = doc.first_child.?;
    const heading_text_node = heading_node.first_child.?;
    try std.testing.expectEqualStrings("Scientific viewpoints", try heading_text_node.asText());
}

test "HEADING COMMENT well formed heading with some text and a comment" {
    const wikitext =
        \\= Blah Blah Blah =
        \\Blah <!-- Blah Blah --> Blah Blah
        \\Some more Blah
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 3);

    const heading_node = doc.first_child.?;
    try std.testing.expect((try heading_node.asHeading()).level == 1);
    const heading_text_node = heading_node.first_child.?;
    try std.testing.expectEqualStrings("Blah Blah Blah", try heading_text_node.asText());

    const text_node1 = heading_node.next.?;
    try std.testing.expectEqualStrings("\nBlah ", try text_node1.asText());

    const text_node2 = text_node1.next.?;
    try std.testing.expectEqualStrings(" Blah Blah\nSome more Blah\n", try text_node2.asText());
}

test "TEMPLATE large country infobox" {
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
    const arg_keys = [_][]const u8{ "conventional_long_name", "common_name", "native_name", "image_flag", "image_coat", "symbol_type", "national_motto", "national_anthem", "image_map", "map_caption", "image_map2", "capital", "coordinates", "largest_city", "official_languages", "ethnic_groups", "ethnic_groups_year", "religion", "religion_year", "religion_ref", "demonym", "government_type", "leader_title1", "leader_name1", "leader_title2", "leader_name2", "leader_title3", "leader_name3", "leader_title4", "leader_name4", "legislature", "sovereignty_type", "established_event1", "established_date1", "established_event2", "established_date2", "established_event3", "established_date3", "area_km2", "area_rank", "area_sq_mi", "percent_water", "population_estimate", "population_estimate_rank", "population_estimate_year", "population_census_year", "population_density_km2", "population_density_sq_mi", "population_density_rank", "GDP_PPP", "GDP_PPP_year", "GDP_PPP_rank", "GDP_PPP_per_capita", "GDP_PPP_per_capita_rank", "GDP_nominal", "GDP_nominal_year", "GDP_nominal_rank", "GDP_nominal_per_capita", "GDP_nominal_per_capita_rank", "Gini", "Gini_year", "Gini_ref", "HDI", "HDI_year", "HDI_change", "HDI_ref", "HDI_rank", "currency", "currency_code", "time_zone", "utc_offset", "utc_offset_DST", "time_zone_DST", "date_format", "drives_on", "calling_code", "cctld", "today" };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const doc = try parseDocument(a, wikitext, TestTrace(Error){});

    try std.testing.expect(doc.n_children == 1);

    const template_node = doc.first_child.?;
    try std.testing.expect(template_node.nodeType() == .template);
    try std.testing.expect(template_node.n_children == arg_keys.len);

    var i: usize = 0;
    var it = template_node.first_child;
    while (it) |node| : (it = node.next) {
        try std.testing.expectEqualStrings(arg_keys[i], (try node.asArg()).key.?);
        i += 1;
    }
}
