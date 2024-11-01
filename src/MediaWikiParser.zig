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
    title: ?[]const u8 = null,
};

pub const WikiLinkCtx = struct {
    pub const WLArg = struct {
        pub const ValueList = std.DoublyLinkedList(MWNode);
        pub const ValueNode = ValueList.Node;

        name: ?[]const u8 = null,
        values: ValueList = ValueList{},
    };

    pub const WLArgList = std.DoublyLinkedList(WLArg);
    pub const WLArgNode = WLArgList.Node;

    pub const Namepace = enum(u8) {
        /// For unknown
        Unknown,
        /// Regular Articles
        Main,
        /// Images and audio files
        File,
        /// Link to Wikitionary
        Wikitionary,

        pub fn fromStr(str: []const u8) Namepace {
            if (std.mem.eql(u8, str, "main")) {
                return .Main;
            } else if (std.mem.eql(u8, str, "File")) {
                return .File;
            } else if (std.mem.eql(u8, str, "wikt")) {
                return .Wikitionary;
            } else {
                return .Unknown;
            }
        }
    };

    /// Actual article to link to
    article: []const u8,
    /// `[[article|<arg>|<arg>]]`
    args: WLArgList = WLArgList{},
    /// File extension if it exists
    ext: ?[]const u8 = null,
    namespace: Namepace = Namepace.Main,
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
    pub const AttrList = std.DoublyLinkedList(HtmlTagAttr);
    pub const AttrNode = AttrList.Node;
    pub const ChildList = std.DoublyLinkedList(MWNode);
    pub const ChildNode = ChildList.Node;

    tag_name: []const u8,
    attrs: AttrList = AttrList{},
    /// Nodes in between \<tag\> and \</tag\>, including text
    children: ChildList = ChildList{},
};

pub const TemplateCtx = struct {
    pub const Arg = struct {
        pub const ValueList = std.DoublyLinkedList(MWNode);
        pub const ValueNode = ValueList.Node;

        name: ?[]const u8 = null,
        values: ValueList = ValueList{},
    };

    pub const ArgList = std.DoublyLinkedList(Arg);
    pub const ArgNode = ArgList.Node;

    name: []const u8,
    args: std.DoublyLinkedList(Arg) = ArgList{},
};

/// Allocates one `N` struct and copies `data` to `N.data`
fn newNode(a: std.mem.Allocator, N: type, data: anytype) !*N {
    const n = try a.create(N);
    n.*.data = data;
    return n;
}

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
        /// Separate from `InvalidHtmlTag` becuase math tags have different parsing
        InvalidMathTag,
        /// Separate from `InvalidHtmlTag` becuase nowiki tags have different parsing
        InvalidNoWikiTag,
        /// encountered closed html tag randomly. indicates invalid parsing earlier
        SpuriousClosedHtmlTag,
        BadExternalLink,
        BadWikiLink,
        IncompleteTable,
        BadTemplate,

        // So this can a global set for MWParser functions
        OutOfMemory,
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

                        i, const t_ctx = self.parseTemplate(i) catch |err| {
                            std.log.debug("{s} Context: '{s}'", .{ @errorName(err), getErrContext(self.raw_wikitext, i) });
                            return err;
                        };

                        try self.nodes.append(.{ .template = t_ctx });

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

                        i, const wkl_ctx = self.parseWikiLink(i) catch |err| {
                            std.log.debug("{s} Context: '{s}'", .{ @errorName(err), getErrContext(self.raw_wikitext, i) });
                            return err;
                        };
                        try self.nodes.append(.{ .wiki_link = wkl_ctx });

                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
                    } else if (nextEql(self.raw_wikitext, "[http", i)) {
                        if (cur_text_node.len > 0)
                            try self.nodes.append(.{ .text = cur_text_node });

                        i, const el_ctx = self.parseExternalLink(i) catch |err| {
                            std.log.debug("{s} Context: '{s}'", .{ @errorName(err), getErrContext(self.raw_wikitext, i) });
                            return err;
                        };
                        try self.nodes.append(.{ .external_link = el_ctx });

                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
                    } else {
                        i += 1;
                        cur_text_node.len += 1;
                    }
                },

                '<' => {
                    if (cur_text_node.len > 0)
                        try self.nodes.append(.{ .text = cur_text_node });

                    if (nextEql(self.raw_wikitext, "!--", i + 1)) {
                        i = self.skipHtmlComment(i) catch |err| {
                            std.log.debug("{s} Context: '{s}'", .{ @errorName(err), getErrContext(self.raw_wikitext, i) });
                            return err;
                        };
                    } else {
                        i, const ht_ctx = self.parseHtmlTag(i) catch |err| {
                            std.log.debug("{s} Context: '{s}'", .{ @errorName(err), getErrContext(self.raw_wikitext, i) });
                            return err;
                        };
                        try self.nodes.append(.{ .html_tag = ht_ctx });
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

                        i = self.parseHeading(i) catch |err| {
                            std.log.debug("{s} Context: '{s}'", .{ @errorName(err), getErrContext(self.raw_wikitext, i) });
                            return err;
                        };

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

    fn parseTemplate(self: *Self, start: usize) ParseError!struct { usize, TemplateCtx } {
        const FAIL = ParseError.BadTemplate;

        var i = start + "{{".len;

        // get template name
        const template_name_start = i;
        i = try skipUntilOneOf(self.raw_wikitext, &.{ '\n', '}', '|' }, i, FAIL);
        const template_name = self.raw_wikitext[template_name_start..i];

        // skip whitespace after template name
        i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n' }, i, FAIL);

        // if template closes, return it
        if (nextEql(self.raw_wikitext, "}}", i)) {
            return .{
                i + "}}".len,
                .{ .name = template_name },
            };
        }

        if (self.raw_wikitext[i] != '|')
            return FAIL;
        i += "|".len;

        // parse args
        var arg_list = TemplateCtx.ArgList{};
        const ArgNode = TemplateCtx.ArgNode;

        while (i < self.raw_wikitext.len) {
            i, const arg, const last = try self.parseTemplateArgument(i);
            arg_list.append(
                try newNode(self.a, ArgNode, arg),
            );

            if (last) {
                return .{ i, .{
                    .name = template_name,
                    .args = arg_list,
                } };
            }
        }

        return FAIL;
    }

    /// Parses template argument with start pointing to the first character
    fn parseTemplateArgument(self: *Self, start: usize) ParseError!struct { usize, TemplateCtx.Arg, bool } {
        const FAIL = ParseError.BadTemplate;
        const ValueNode = TemplateCtx.Arg.ValueNode;

        var arg = TemplateCtx.Arg{};

        var i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n' }, start, FAIL);

        const arg_start = i;
        var arg_name_end_opt: ?usize = null;

        var cur_text_node = self.raw_wikitext[i..];
        cur_text_node.len = 0;

        while (i < self.raw_wikitext.len) {
            switch (self.raw_wikitext[i]) {
                '=' => {
                    arg_name_end_opt = i;
                    i += "=".len;

                    // doi links are raw text
                    if (std.mem.eql(u8, "doi", self.raw_wikitext[arg_start..arg_name_end_opt.?])) {
                        const doi_text_start = i;
                        i = try skipUntilOneOf(self.raw_wikitext, &.{ ' ', '|', ']' }, i, FAIL);
                        const doi_text = self.raw_wikitext[doi_text_start..i];
                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .text = doi_text }),
                        );
                        if (self.raw_wikitext[i] == ' ')
                            i = try skipWhileOneOf(self.raw_wikitext, " \t\n", i, FAIL);
                        const last = self.raw_wikitext[i] == ']';
                        return .{ i + 1, arg, last };
                    }

                    cur_text_node = self.raw_wikitext[i..];
                    cur_text_node.len = 0;
                },
                '<' => {
                    if (nextEql(self.raw_wikitext, "!--", i + 1)) { // comment
                        i = try self.skipHtmlComment(i);
                    } else { // html tag
                        i, const ht_ctx = try self.parseHtmlTag(i);
                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .html_tag = ht_ctx }),
                        );
                    }

                    if (cur_text_node.len > 0)
                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                        );
                    cur_text_node = self.raw_wikitext[i..];
                    cur_text_node.len = 0;
                },
                '}' => {
                    if (nextEql(self.raw_wikitext, "}}", i)) { // done!
                        if (cur_text_node.len > 0)
                            arg.values.append(
                                try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                            );
                        if (arg_name_end_opt) |arg_name_end|
                            arg.name = std.mem.trimRight(u8, self.raw_wikitext[arg_start..arg_name_end], &.{ ' ', '\t', '\n' });
                        return .{ i + "}}".len, arg, true };
                    } else { // continue with } as text
                        i += 1;
                        cur_text_node.len += 1;
                    }
                },
                '{' => {
                    if (nextEql(self.raw_wikitext, "{{", i)) { // nested tag

                        if (cur_text_node.len > 0)
                            arg.values.append(
                                try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                            );

                        i, const t_ctx = try self.parseTemplate(i);

                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .template = t_ctx }),
                        );

                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
                    } else { // continue with { as text
                        i += 1;
                        cur_text_node.len += 1;
                    }
                },
                '|' => { // done!
                    if (cur_text_node.len > 0)
                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                        );
                    if (arg_name_end_opt) |arg_name_end|
                        arg.name = std.mem.trimRight(u8, self.raw_wikitext[arg_start..arg_name_end], &.{ ' ', '\t', '\n' });
                    return .{ i + "|".len, arg, false };
                },
                '[' => { // link
                    if (nextEql(self.raw_wikitext, "[[", i)) {
                        if (cur_text_node.len > 0)
                            arg.values.append(
                                try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                            );

                        i, const wkl_ctx = try self.parseWikiLink(i);
                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .wiki_link = wkl_ctx }),
                        );
                    } else if (nextEql(self.raw_wikitext, "[[http", i)) {
                        if (cur_text_node.len > 0)
                            arg.values.append(
                                try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                            );

                        i, const el_ctx = try self.parseExternalLink(i);
                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .external_link = el_ctx }),
                        );
                    } else {
                        i += 1;
                        cur_text_node.len += 1;
                        continue;
                    }

                    cur_text_node = self.raw_wikitext[i..];
                    cur_text_node.len = 0;
                },
                else => {
                    i += 1;
                    cur_text_node.len += 1;
                },
            }
        }

        return FAIL;
    }

    /// Returns i pointing to after pointer, errors otherwise
    fn parseTable(self: *Self, start: usize) !usize {
        const FAIL = ParseError.IncompleteTable;

        var i = start + "{|".len;

        while (i < self.raw_wikitext.len) {
            i = try skipUntilOneOf(self.raw_wikitext, &.{'|'}, i, FAIL);
            if (nextEql(self.raw_wikitext, "|}", i))
                return i + "|}".len;
            i += "|".len;
        }

        return FAIL;
    }

    fn parseWikiLink(self: *Self, start: usize) ParseError!struct { usize, WikiLinkCtx } {
        const FAIL = ParseError.BadWikiLink;

        // skip [[ and single line whitespace after
        var i = start + "[[".len;
        i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);

        // find end of article
        const article_start = i;
        var namespace_end_opt: ?usize = null;
        i = try skipUntilOneOf(self.raw_wikitext, &.{ '\n', ':', '|', ']' }, i, FAIL);

        // namspaced link, save namespace end
        if (self.raw_wikitext[i] == ':') {
            namespace_end_opt = i;
            i = try skipUntilOneOf(self.raw_wikitext, &.{ '\n', '|', ']' }, i, FAIL);
        }
        try errOnLineBreak(self.raw_wikitext[i], FAIL);

        const article_name = blk: {
            if (namespace_end_opt) |namespace_end| {
                break :blk std.mem.trimRight(u8, self.raw_wikitext[namespace_end + ":".len .. i], " \t");
            } else {
                break :blk std.mem.trimRight(u8, self.raw_wikitext[article_start..i], " \t");
            }
        };
        const namespace = blk: {
            if (namespace_end_opt) |namespace_end| {
                break :blk WikiLinkCtx.Namepace.fromStr(self.raw_wikitext[article_start..namespace_end]);
            } else {
                break :blk WikiLinkCtx.Namepace.Main;
            }
        };

        // skip whitespace after article name
        i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);

        // if link ends return
        if (self.raw_wikitext[i] == ']') {
            if (nextEql(self.raw_wikitext, "]]", i))
                return .{ i + "]]".len, .{ .article = article_name, .namespace = namespace } };
            return FAIL;
        }

        if (self.raw_wikitext[i] != '|')
            return FAIL;

        i += "|".len;

        // parse args
        var arg_list = WikiLinkCtx.WLArgList{};
        const ArgNode = WikiLinkCtx.WLArgNode;

        while (i < self.raw_wikitext.len) {
            i, const arg, const last = try self.parseWikiLinkArgument(i);
            arg_list.append(
                try newNode(self.a, ArgNode, arg),
            );

            if (last) {
                return .{ i, .{
                    .article = article_name,
                    .args = arg_list,
                    .namespace = namespace,
                } };
            }
        }

        return FAIL;
    }

    fn parseWikiLinkArgument(self: *Self, start: usize) ParseError!struct { usize, WikiLinkCtx.WLArg, bool } {
        const FAIL = ParseError.BadTemplate;
        const ValueNode = WikiLinkCtx.WLArg.ValueNode;

        var arg = WikiLinkCtx.WLArg{};

        var i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n' }, start, FAIL);

        const arg_start = i;
        var arg_name_end_opt: ?usize = null;

        var cur_text_node = self.raw_wikitext[i..];
        cur_text_node.len = 0;

        while (i < self.raw_wikitext.len) {
            switch (self.raw_wikitext[i]) {
                '=' => {
                    arg_name_end_opt = i;
                    i += 1;
                    cur_text_node = self.raw_wikitext[i..];
                    cur_text_node.len = 0;
                },
                '<' => {
                    if (cur_text_node.len > 0)
                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                        );

                    if (nextEql(self.raw_wikitext, "!--", i + 1)) { // comment
                        i = try self.skipHtmlComment(i);
                    } else { // html tag
                        i, const ht_ctx = try self.parseHtmlTag(i);
                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .html_tag = ht_ctx }),
                        );
                    }

                    cur_text_node = self.raw_wikitext[i..];
                    cur_text_node.len = 0;
                },
                ']' => {
                    if (nextEql(self.raw_wikitext, "]]", i)) { // done!
                        if (cur_text_node.len > 0)
                            arg.values.append(
                                try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                            );

                        if (arg_name_end_opt) |arg_name_end|
                            arg.name = std.mem.trimRight(u8, self.raw_wikitext[arg_start..arg_name_end], &.{ ' ', '\t', '\n' });

                        return .{ i + "}}".len, arg, true };
                    } else {
                        return FAIL;
                    }
                },
                '{' => {
                    if (nextEql(self.raw_wikitext, "{{", i)) { // nested tag
                        if (cur_text_node.len > 0)
                            arg.values.append(
                                try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                            );

                        i, const t_ctx = try self.parseTemplate(i);

                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .template = t_ctx }),
                        );

                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
                    } else { // continue with { as text
                        i += 1;
                        cur_text_node.len += 1;
                    }
                },
                '|' => { // done!
                    if (cur_text_node.len > 0)
                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                        );

                    if (arg_name_end_opt) |arg_name_end|
                        arg.name = std.mem.trimRight(u8, self.raw_wikitext[arg_start..arg_name_end], &.{ ' ', '\t', '\n' });

                    return .{ i + "|".len, arg, false };
                },
                '[' => { // link

                    if (nextEql(self.raw_wikitext, "[[", i)) {
                        if (cur_text_node.len > 0)
                            arg.values.append(
                                try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                            );

                        i, const wkl_ctx = try self.parseWikiLink(i);
                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .wiki_link = wkl_ctx }),
                        );
                    } else if (nextEql(self.raw_wikitext, "[[http", i)) {
                        if (cur_text_node.len > 0)
                            arg.values.append(
                                try newNode(self.a, ValueNode, .{ .text = cur_text_node }),
                            );

                        i, const el_ctx = try self.parseExternalLink(i);
                        arg.values.append(
                            try newNode(self.a, ValueNode, .{ .external_link = el_ctx }),
                        );
                    } else {
                        i += 1;
                        cur_text_node.len += 1;
                        continue;
                    }

                    cur_text_node = self.raw_wikitext[i..];
                    cur_text_node.len = 0;
                },
                else => {
                    i += 1;
                    cur_text_node.len += 1;
                },
            }
        }

        return FAIL;
    }

    fn parseExternalLink(self: *Self, start: usize) ParseError!struct { usize, ExternalLinkCtx } {
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
        if (self.raw_wikitext[i] == ']')
            return .{ i + 1, .{ .url = url } };

        // get display name
        const name_start = i;
        i = try skipUntilOneOf(self.raw_wikitext, &.{ '\n', ']' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);
        const name = self.raw_wikitext[name_start..i];

        if (self.raw_wikitext[i] != ']')
            return FAIL;

        return .{ i + 1, .{ .url = url, .title = name } };
    }

    /// `i` should point to the opening `<`
    fn parseHtmlTag(self: *Self, start: usize) ParseError!struct { usize, HtmlTagCtx } {
        const FAIL = ParseError.InvalidHtmlTag;

        var i = try advance(start, "<".len, self.raw_wikitext, FAIL);
        if (isWhiteSpace(self.raw_wikitext[i]))
            return FAIL;
        if (self.raw_wikitext[i] == '/')
            return ParseError.SpuriousClosedHtmlTag;

        const tag_name_start = i;
        i = try skipUntilOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n', '/', '>' }, i, FAIL);
        if (i == tag_name_start)
            return FAIL;
        const tag_name = self.raw_wikitext[tag_name_start..i];

        // skip whitespace after tag name
        i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n' }, i, FAIL);

        const attribute_name_pred = struct {
            /// Stops on ' ', '\n', '\r', '\t', '/', '>', '='
            fn attribute_name_pred(ch: u8) bool {
                switch (ch) {
                    ' ', '\n', '\r', '\t', '/', '>', '=' => return false,
                    else => return true,
                }
            }
        }.attribute_name_pred;

        // attempt to find attributes
        var attrs = HtmlTagCtx.AttrList{};
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
            i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n' }, i, FAIL);

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
                '\'' => i = try skipUntilOneOf(self.raw_wikitext, &.{'\''}, i, FAIL),
                '"' => i = try skipUntilOneOf(self.raw_wikitext, &.{'"'}, i, FAIL),
                0 => i = try skipUntilOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n', '/', '>' }, i, FAIL),
                else => unreachable,
            }
            const attr_value = self.raw_wikitext[attr_value_start..i];

            // skip quote if it existed
            if (quote != 0)
                i += 1;

            attrs.append(
                try newNode(self.a, HtmlTagCtx.AttrNode, .{ .name = attr_name, .value = attr_value }),
            );

            // skip whitespace after attr name
            i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n' }, i, FAIL);
        }

        // Handle self closing tag
        if (self.raw_wikitext[i] == '/') {
            if (i + 1 < self.raw_wikitext.len and self.raw_wikitext[i + 1] == '>')
                return .{ i + "/>".len, .{ .tag_name = tag_name, .attrs = attrs } };
            return FAIL;
        }

        // skip closing '>'
        if (self.raw_wikitext[i] != '>')
            return FAIL;
        i += ">".len;

        if (forbiddenClosingTag(tag_name))
            return .{ i, .{ .tag_name = tag_name, .attrs = attrs } };

        var children = HtmlTagCtx.ChildList{};

        // math tags are special and everything is fair game until </math>
        // nowiki means discard all parsing, same effect
        if (std.mem.eql(u8, tag_name, "math")) {
            const latex_content_start = i;
            while (i < self.raw_wikitext.len - "</math".len) : (i += 1) {
                if (std.mem.eql(u8, self.raw_wikitext[i .. i + "</math".len], "</math")) {
                    const latex_content = self.raw_wikitext[latex_content_start..i];
                    children.append(
                        try newNode(self.a, HtmlTagCtx.ChildNode, .{ .text = latex_content }),
                    );

                    i += "</math".len;
                    i = try skipWhileOneOf(self.raw_wikitext, " \t\n", i, ParseError.InvalidMathTag);
                    if (self.raw_wikitext[i] != '>')
                        return ParseError.InvalidMathTag;

                    return .{ i + ">".len, .{ .tag_name = tag_name, .attrs = attrs, .children = children } };
                }
            }
        }
        if (std.mem.eql(u8, tag_name, "nowiki")) {
            const escaped_content_start = i;
            while (i < self.raw_wikitext.len - "</nowiki".len) : (i += 1) {
                if (std.mem.eql(u8, self.raw_wikitext[i .. i + "</nowiki".len], "</nowiki")) {
                    const escaped_content = self.raw_wikitext[escaped_content_start..i];
                    children.append(
                        try newNode(self.a, HtmlTagCtx.ChildNode, .{ .text = escaped_content }),
                    );

                    i += "</nowiki".len;
                    i = try skipWhileOneOf(self.raw_wikitext, " \t\n", i, ParseError.InvalidMathTag);
                    if (self.raw_wikitext[i] != '>')
                        return ParseError.InvalidMathTag;

                    return .{ i + ">".len, .{ .tag_name = tag_name, .attrs = attrs, .children = children } };
                }
            }
        }

        var cur_text_node = self.raw_wikitext[i..];
        cur_text_node.len = 0;
        while (i < self.raw_wikitext.len) {
            if (nextEql(self.raw_wikitext, "</", i)) { // if tag ends, end it!
                i += "</".len;

                // get close tag name
                const close_tag_name_start = i;
                i = try skipUntilOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n', '/', '>' }, i, FAIL);
                const close_tag_name = self.raw_wikitext[close_tag_name_start..i];

                // validate
                if (!std.mem.eql(u8, close_tag_name, tag_name))
                    return FAIL;

                // skip whitespace after tag name
                i = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n' }, i, FAIL);
                if (self.raw_wikitext[i] != '>')
                    return FAIL;

                children.append(
                    try newNode(self.a, HtmlTagCtx.ChildNode, .{ .text = cur_text_node }),
                );

                return .{
                    i + 1,
                    .{
                        .tag_name = tag_name,
                        .attrs = attrs,
                        .children = children,
                    },
                };
            } else if (nextEql(self.raw_wikitext, "<!--", i)) { // comment ... skip it!
                if (cur_text_node.len > 0)
                    children.append(
                        try newNode(self.a, HtmlTagCtx.ChildNode, .{ .text = cur_text_node }),
                    );

                i = try self.skipHtmlComment(i);

                cur_text_node = self.raw_wikitext[i..];
                cur_text_node.len = 0;
            } else if (self.raw_wikitext[i] == '<') { // another html tag
                if (cur_text_node.len > 0)
                    children.append(
                        try newNode(self.a, HtmlTagCtx.ChildNode, .{ .text = cur_text_node }),
                    );

                i, const ht_ctx = try self.parseHtmlTag(i);
                children.append(
                    try newNode(self.a, HtmlTagCtx.ChildNode, .{ .html_tag = ht_ctx }),
                );

                cur_text_node = self.raw_wikitext[i..];
                cur_text_node.len = 0;
            } else if (nextEql(self.raw_wikitext, "{{", i)) { // template
                if (cur_text_node.len > 0)
                    children.append(
                        try newNode(self.a, HtmlTagCtx.ChildNode, .{ .text = cur_text_node }),
                    );

                i, const t_ctx = try self.parseTemplate(i);
                children.append(
                    try newNode(self.a, HtmlTagCtx.ChildNode, .{ .template = t_ctx }),
                );

                cur_text_node = self.raw_wikitext[i..];
                cur_text_node.len = 0;
            } else {
                i += 1;
                cur_text_node.len += 1;
            }
        }

        return FAIL;
    }

    /// moves to `i` to after the comment,
    /// or returns `ParseError.UnclosedHtmlComment` if none is found
    ///
    /// `i` should point to the first char of `<!--`
    fn skipHtmlComment(self: *Self, start: usize) !usize {
        const FAIL = ParseError.UnclosedHtmlComment;

        var i = start + "<!--".len;
        while (i <= self.raw_wikitext.len - "-->".len) : (i += 1) {
            if (std.mem.eql(u8, self.raw_wikitext[i .. i + "-->".len], "-->"))
                return i + "-->".len;
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
    ///
    /// Skips inline html elements
    fn parseHeading(self: *Self, start: usize) ParseError!usize {
        const FAIL = ParseError.IncompleteHeading;

        var i: usize = start;

        // parse leading =, remembering how many
        var level: usize = 0;
        while (i < self.raw_wikitext.len) : (i += 1) {
            const ch = self.raw_wikitext[i];
            switch (ch) {
                '=' => level += 1,
                '\n' => return FAIL,
                else => break,
            }
        }

        const text_start = try skipWhileOneOf(self.raw_wikitext, &.{ ' ', '\t', '\n' }, i, FAIL);
        try errOnLineBreak(self.raw_wikitext[i], FAIL);

        var cur_text_node = self.raw_wikitext[i..];
        cur_text_node.len = 0;

        while (i < self.raw_wikitext.len) {
            const ch = self.raw_wikitext[i];
            switch (ch) {
                '<' => { // skip html tag
                    if (nextEql(self.raw_wikitext, "<!--", i)) {
                        i = try self.skipHtmlComment(i);
                    } else {
                        i, _ = try self.parseHtmlTag(i);
                    }
                },
                '=' => { // end of heading
                    const text = std.mem.trimRight(u8, self.raw_wikitext[text_start..i], &.{ ' ', '\t' });
                    if (text.len == 0)
                        return FAIL;

                    if (!nextEqlCount(self.raw_wikitext, '=', level, i))
                        return FAIL;

                    try self.nodes.append(.{ .heading = .{ .heading = text, .level = level } });
                    return i + level * "=".len;
                },
                '\n' => return FAIL,
                else => i += 1,
            }
        }

        return FAIL;
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
inline fn skipWhileOneOf(buf: []const u8, comptime continues: []const u8, i: usize, E: MWParser.ParseError) MWParser.ParseError!usize {
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
inline fn skipUntilOneOf(buf: []const u8, comptime stops: []const u8, i: usize, E: MWParser.ParseError) MWParser.ParseError!usize {
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
inline fn skip(buf: []const u8, continue_pred: fn (u8) bool, _i: usize, E: MWParser.ParseError) MWParser.ParseError!usize {
    var i = _i;
    while (i < buf.len) : (i += 1) {
        if (!@call(.always_inline, continue_pred, .{buf[i]})) {
            return i;
        }
    }
    return E;
}

/// Safely advance buffer index `i` by count
///
/// Returns `error.AdvanceBeyondBuffer` if i+count goes out of bounds
inline fn advance(i: usize, count: usize, buf: []const u8, E: MWParser.ParseError) MWParser.ParseError!usize {
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

/// Must this tag be self closed?
///
/// Also checks if it supports `<tag_name>` syntax in addition to `<tag_name/>`
inline fn forbiddenClosingTag(tag_name: []const u8) bool {
    const forbiddenClosingTagNames = [_][]const u8{ "area", "base", "basefont", "br", "col", "frame", "hr", "img", "input", "isindex", "link", "meta", "param" };

    for (forbiddenClosingTagNames) |fctn| {
        if (std.mem.eql(u8, fctn, tag_name))
            return true;
    }

    return false;
}

/// returns `E` if `ch` is `\n`
inline fn errOnLineBreak(ch: u8, E: MWParser.ParseError) MWParser.ParseError!void {
    if (ch == '\n')
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

test "HEADING rejects malformed headings" {
    const unclosed1: []const u8 =
        \\== Anarchism
        \\
    ;
    const unclosed2: []const u8 =
        \\== Anarchism=
        \\
    ;
    // not considered an error anymore
    //const overclosed: []const u8 =
    //    \\== Anarchism===
    //    \\
    //;
    const bad_line_break: []const u8 =
        \\== Anarchism
        \\==
        \\
    ;
    const weird: []const u8 =
        \\= = =
        \\
    ;
    const cases = [_][]const u8{ unclosed1, unclosed2, bad_line_break, weird };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var wp = MWParser.init(a, case);
        const e = wp.parse();
        try std.testing.expectError(MWParser.ParseError.IncompleteHeading, e);
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

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 2);

    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[0]), "heading");
    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[1]), "text");

    switch (wp.nodes.items[0]) {
        .heading => |h| {
            try std.testing.expectEqualStrings("Blah Blah Blah", h.heading);
            try std.testing.expect(h.level == 1);
        },
        else => unreachable,
    }

    switch (wp.nodes.items[1]) {
        .text => |text| try std.testing.expectEqualStrings("\nBlah Blah Blah\nSome more Blah\n", text),
        else => unreachable,
    }
}

test "HEADING embedded html with attributes" {
    const wikitext =
        \\=== Computing <span class="anchor" id="Computing codes"></span> ===
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 2);

    switch (wp.nodes.items[0]) {
        .heading => |h| {
            try std.testing.expect(h.level == 3);
            try std.testing.expectEqualStrings("Computing <span class=\"anchor\" id=\"Computing codes\"></span>", h.heading);
        },
        else => unreachable,
    }

    switch (wp.nodes.items[1]) {
        .text => |t| {
            try std.testing.expectEqualStrings("\n", t);
        },
        else => unreachable,
    }
}

test "HEADING parses correctly with following html comment" {
    const wikitext = "===Molecular geometry===<!-- This section is linked from [[Nylon]] -->";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);
    switch (wp.nodes.items[0]) {
        .heading => |h| {
            try std.testing.expect(h.level == 3);
            try std.testing.expectEqualStrings("Molecular geometry", h.heading);
        },
        else => unreachable,
    }
}

// TODO: The comment should be skipped, for now it goes into the heading text
test "HEADING parses correctly with inline html comment" {
    const wikitext = "==Scientific viewpoints<!--linked from 'Evolution of morality'-->==";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);
    switch (wp.nodes.items[0]) {
        .heading => |h| {
            try std.testing.expect(h.level == 2);
            try std.testing.expectEqualStrings("Scientific viewpoints<!--linked from 'Evolution of morality'-->", h.heading);
        },
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

test "COMMENT fails on unclosed" {
    const wikitext = "<!-- Blah --";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    const e = wp.parse();

    try std.testing.expectError(MWParser.ParseError.UnclosedHtmlComment, e);
}

test "COMMENT correct" {
    const wikitext = "<!-- Blah Blah -->";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 0);
}

test "COMMENT skips enclosed '-' and embedded tags" {
    const wikitext =
        \\<!--In aquatic amphibians, the liver plays only a small role in processing nitrogen for excretion, and [[ammonia]] is diffused mainly through the skin. The liver of terrestrial amphibians converts ammonia to urea, a less toxic, water-soluble nitrogenous compound, as a means of water conservation. In some species, urea is further converted into [[uric acid]]. [[Bile]] secretions from the liver collect in the gall bladder and flow into the small intestine. In the small intestine, enzymes digest carbohydrates, fats, and proteins. Salamanders lack a valve separating the small intestine from the large intestine. Salt and water absorption occur in the large intestine, as well as mucous secretion to aid in the transport of faecal matter, which is passed out through the [[cloaca]].<ref name="Anatomy" />---Omitting this until a more reliable source can be found.--->
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 0);
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

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 3);

    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[0]), "heading");
    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[1]), "text");
    try std.testing.expectEqualStrings(@tagName(wp.nodes.items[2]), "text");

    switch (wp.nodes.items[0]) {
        .heading => |h| {
            try std.testing.expectEqualStrings("Blah Blah Blah", h.heading);
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

test "HTML_TAG Trivial Correct" {
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
            try std.testing.expect(t.children.len == 1);
            switch (t.children.first.?.data) {
                .text => |txt| try std.testing.expectEqualStrings("Hello", txt),
                else => unreachable,
            }
        },
        else => unreachable,
    }
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

        var wp = MWParser.init(a, case);
        try wp.parse();

        try std.testing.expect(wp.nodes.items.len == 1);

        switch (wp.nodes.items[0]) {
            .html_tag => |t| {
                try std.testing.expectEqualStrings("ref", t.tag_name);
                try std.testing.expect(t.children.len == 1);
                switch (t.children.first.?.data) {
                    .text => |txt| try std.testing.expectEqualStrings("Hello", txt),
                    else => unreachable,
                }
            },
            else => unreachable,
        }
    }
}

test "HTML_TAG decodes attributes correctly" {
    const wikitext = "<ref kind='web'>citation</ref>";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    switch (wp.nodes.items[0]) {
        .html_tag => |t| {
            try std.testing.expect(t.attrs.len == 1);
            try std.testing.expectEqualStrings("kind", t.attrs.first.?.data.name);
            try std.testing.expectEqualStrings("web", t.attrs.first.?.data.value);
            try std.testing.expectEqualStrings("ref", t.tag_name);
            try std.testing.expect(t.children.len == 1);
            switch (t.children.first.?.data) {
                .text => |txt| try std.testing.expectEqualStrings("citation", txt),
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "HTML_TAG decodes attribute without quotes" {
    const wikitext = "<ref name=Maine />";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    switch (wp.nodes.items[0]) {
        .html_tag => |t| {
            try std.testing.expect(t.attrs.len == 1);
            try std.testing.expect(t.children.len == 0);
            try std.testing.expectEqualStrings("name", t.attrs.first.?.data.name);
            try std.testing.expectEqualStrings("Maine", t.attrs.first.?.data.value);
            try std.testing.expectEqualStrings("ref", t.tag_name);
        },
        else => unreachable,
    }
}

test "HTML_TAG decodes with nested comment" {
    const wikitext = "<ref kind='web'>cit<!-- Skip Me -->ation</ref>";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    switch (wp.nodes.items[0]) {
        .html_tag => |t| {
            try std.testing.expect(t.attrs.len == 1);
            try std.testing.expectEqualStrings("kind", t.attrs.first.?.data.name);
            try std.testing.expectEqualStrings("web", t.attrs.first.?.data.value);
            try std.testing.expectEqualStrings("ref", t.tag_name);
            try std.testing.expect(t.children.len == 2);
            switch (t.children.first.?.data) {
                .text => |txt| try std.testing.expectEqualStrings("cit", txt),
                else => unreachable,
            }
            switch (t.children.first.?.next.?.data) {
                .text => |txt| try std.testing.expectEqualStrings("ation", txt),
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "HTML_TAG decodes nested tags" {
    const wikitext = "<div>Start<div>Middle</div>End</div>";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);

    switch (wp.nodes.items[0]) {
        .html_tag => |t| {
            try std.testing.expect(t.attrs.len == 0);
            try std.testing.expectEqualStrings("div", t.tag_name);
            try std.testing.expect(t.children.len == 3);

            var n = t.children.first.?;
            switch (n.*.data) {
                .text => |txt| try std.testing.expectEqualStrings("Start", txt),
                else => unreachable,
            }
            n = n.next.?;
            switch (n.*.data) {
                .html_tag => |_t| {
                    try std.testing.expectEqualStrings("div", _t.tag_name);
                    try std.testing.expect(_t.attrs.len == 0);
                    try std.testing.expect(_t.children.len == 1);
                    switch (_t.children.first.?.data) {
                        .text => |txt| try std.testing.expectEqualStrings("Middle", txt),
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
            n = n.next.?;
            switch (n.*.data) {
                .text => |txt| try std.testing.expectEqualStrings("End", txt),
                else => unreachable,
            }
        },
        else => unreachable,
    }
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

    var wp = MWParser.init(a, wikitext);
    try wp.parse();
}

test "HTML_TAG <math> ignores '{' and '}'" {
    const wikitext =
        \\<math display="block">F = \frac{MS_\text{Treatments}}{MS_\text{Error}} = {{SS_\text{Treatments} / (I-1)} \over {SS_\text{Error} / (n_T-I)}}</math
        \\>
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    switch (wp.nodes.items[0]) {
        .html_tag => |ht| {
            const c1 = ht.children.first.?.data;
            switch (c1) {
                .text => |txt| try std.testing.expectEqualStrings(
                    \\F = \frac{MS_\text{Treatments}}{MS_\text{Error}} = {{SS_\text{Treatments} / (I-1)} \over {SS_\text{Error} / (n_T-I)}}
                , txt),
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "HTML_TAG <math> ignores '<'" {
    const wikitext =
        \\<math>\hat{\sigma}_\text{OC} < 0.1</math>
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    switch (wp.nodes.items[0]) {
        .html_tag => |ht| {
            const c1 = ht.children.first.?.data;
            switch (c1) {
                .text => |txt| try std.testing.expectEqualStrings(
                    \\\hat{\sigma}_\text{OC} < 0.1
                , txt),
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "HTML_TAG nowiki is respected" {
    const wikitext =
        \\<nowiki> "#$%&'()*+,-./0123456789:;<=>?</nowiki>
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    switch (wp.nodes.items[0]) {
        .html_tag => |ht| {
            const c1 = ht.children.first.?.data;
            switch (c1) {
                .text => |txt| try std.testing.expectEqualStrings(
                    \\ "#$%&'()*+,-./0123456789:;<=>?
                , txt),
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "HTML_TAG br, hr must be self closed" {
    const wikitextPass = "<br ><br /><br name='hi'><hr>";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitextPass);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 4);

    switch (wp.nodes.items[2]) {
        .html_tag => |ht| {
            try std.testing.expect(ht.attrs.len == 1);
            const a1 = ht.attrs.first.?.data;
            try std.testing.expectEqualStrings("name", a1.name);
            try std.testing.expectEqualStrings("hi", a1.value);
        },
        else => unreachable,
    }
}

test "EXTERNAL_LINK no title" {
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

test "EXTERNAL_LINK title" {
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

test "WIKILINK no title" {
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

test "WIKILINK title" {
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
            try std.testing.expect(wl.args.len == 1);
            const arg1 = wl.args.first.?.data;
            try std.testing.expect(arg1.values.len == 1);
            switch (arg1.values.first.?.data) {
                .text => |t| try std.testing.expectEqualStrings("Spanish border", t),
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "WIKILINK wikitionary namespace" {
    const wikitext = "[[wikt:phantasm|phantasm]]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    switch (wp.nodes.items[0]) {
        .wiki_link => |wl| {
            try std.testing.expect(wl.namespace == .Wikitionary);
            try std.testing.expectEqualStrings("phantasm", wl.article);
        },
        else => unreachable,
    }
}

test "WIKILINK image multiple args" {
    const wikitext = "[[File:Paolo Monti - Servizio fotografico (Napoli, 1969) - BEIC 6353768.jpg|thumb|upright=.7|[[Zeno of Citium]] ({{Circa|334|262 BC}}), whose *[[Republic (Zeno)|Republic]]* inspired [[Peter Kropotkin]]{{Sfn|Marshall|1993|p=70}}]]";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);
    switch (wp.nodes.items[0]) {
        .wiki_link => |wl| {
            try std.testing.expect(wl.namespace == .File);
            try std.testing.expectEqualStrings("Paolo Monti - Servizio fotografico (Napoli, 1969) - BEIC 6353768.jpg", wl.article);
            try std.testing.expect(wl.args.len == 3);

            const arg1 = wl.args.first.?;
            const arg1Values = arg1.data.values;
            switch (arg1Values.first.?.data) {
                .text => |txt| try std.testing.expectEqualStrings("thumb", txt),
                else => unreachable,
            }

            const arg2 = arg1.next.?;
            try std.testing.expectEqualStrings("upright", arg2.data.name.?);
            const arg2Values = arg2.data.values;
            switch (arg2Values.first.?.data) {
                .text => |txt| try std.testing.expectEqualStrings(".7", txt),
                else => unreachable,
            }

            const arg3 = arg2.next.?;
            const arg3Value1 = arg3.data.values.first.?;
            switch (arg3Value1.data) {
                .wiki_link => |_wl| try std.testing.expectEqualStrings("Zeno of Citium", _wl.article),
                else => unreachable,
            }
            const arg3Value2 = arg3Value1.next.?;
            switch (arg3Value2.data) {
                .text => |txt| try std.testing.expectEqualStrings(" (", txt),
                else => unreachable,
            }
            const arg3Value3 = arg3Value2.next.?;
            switch (arg3Value3.data) {
                .template => |tmpl| {
                    try std.testing.expectEqualStrings("Circa", tmpl.name);
                    try std.testing.expect(tmpl.args.len == 2);
                },
                else => unreachable,
            }
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

test "TEMPLATE no args" {
    const wikitext = "{{Anarchism sidebar}}";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);

    switch (wp.nodes.items[0]) {
        .template => |t| {
            try std.testing.expectEqualStrings("Anarchism sidebar", t.name);
            try std.testing.expect(t.args.len == 0);
        },
        else => unreachable,
    }
}

test "TEMPLATE text argument no name" {
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
            try std.testing.expect(temp.args.len == 1);
            const arg1 = temp.args.first.?.data;
            try std.testing.expect(arg1.name == null);
            const arg1_value1 = arg1.values.first.?.data;
            switch (arg1_value1) {
                .text => |txt| try std.testing.expectEqualStrings("Definition of anarchism and libertarianism", txt),
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "TEMPLATE child as arg" {
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

            const arg1 = t.args.first.?.data;
            try std.testing.expect(arg1.name == null);
            try std.testing.expect(arg1.values.len == 1);

            const arg1_value1 = arg1.values.first.?.data;
            switch (arg1_value1) {
                .template => |tmpl| {
                    try std.testing.expect(tmpl.args.len == 0);
                    try std.testing.expectEqualStrings("Definition of anarchism and libertarianism", tmpl.name);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "TEMPLATE parses with KV arg" {
    const wikitext = "{{Main|date=May 2023}}";

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

            const arg1 = t.args.first.?.data;
            try std.testing.expectEqualStrings("date", arg1.name.?);
            try std.testing.expect(arg1.values.len == 1);

            const arg1_value1 = arg1.values.first.?.data;
            switch (arg1_value1) {
                .text => |txt| try std.testing.expectEqualStrings("May 2023", txt),
                else => unreachable,
            }
        },
        else => unreachable,
    }
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

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);

    switch (wp.nodes.items[0]) {
        .template => |tmpl| {
            try std.testing.expect(tmpl.args.len == 3);

            const arg2 = tmpl.args.first.?.next.?;
            try std.testing.expectEqualStrings("bird", arg2.data.name.?);
            try std.testing.expect(arg2.data.values.len == 5);

            const value1 = arg2.data.values.first.?;
            switch (value1.data) {
                .text => |txt| try std.testing.expectEqualStrings(" ", txt),
                else => unreachable,
            }

            const value2 = value1.next.?;
            switch (value2.data) {
                .wiki_link => |wl_ctx| {
                    try std.testing.expectEqualStrings("Northern flicker", wl_ctx.article);
                    try std.testing.expect(wl_ctx.args.len == 1);
                    switch (wl_ctx.args.first.?.data.values.first.?.data) {
                        .text => |txt| try std.testing.expectEqualStrings("Yellowhammer", txt),
                        else => unreachable,
                    }
                },
                else => unreachable,
            }

            const value4 = value2.next.?.next.?;
            switch (value4.data) {
                .wiki_link => |wl_ctx| {
                    try std.testing.expectEqualStrings("wild turkey", wl_ctx.article);
                    try std.testing.expect(wl_ctx.args.len == 0);
                },
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

test "TEMPLATE doi link is escaped from parsing" {
    const wikitext =
        \\<ref name="Winston">{{cite journal| first=Jay |last=Winston |title=The Annual Course of Zonal Mean Albedo as Derived From ESSA 3 and 5 Digitized Picture Data |journal=Monthly Weather Review |volume=99 |pages=818–827| bibcode=1971MWRv...99..818W| date=1971| doi=10.1175/1520-0493(1971)099<0818:TACOZM>2.3.CO;2| issue=11|doi-access=free}}</ref>"
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();
}

// TODO: grab html entity
// trim text
test "TEMPLATE '[' treated as text" {
    const wikitext = "{{cite web |url=http://lcweb2.loc.gov/diglib/ihas/loc.natlib.ihas.100010615/full.html |title=Materna (O Mother Dear, Jerusalem) / Samuel Augustus Ward [hymnal&#93;: Print Material Full Description: Performing Arts Encyclopedia, Library of Congress |publisher=Lcweb2.loc.gov |date=2007-10-30 |access-date=2011-08-20 |url-status=live |archive-url=https://web.archive.org/web/20110605020952/http://lcweb2.loc.gov/diglib/ihas/loc.natlib.ihas.100010615/full.html |archive-date=June 5, 2011}}";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);
    switch (wp.nodes.items[0]) {
        .template => |tmpl| {
            const arg2 = tmpl.args.first.?.next.?.data;
            const arg2Value1 = arg2.values.first.?.data;
            switch (arg2Value1) {
                .text => |txt| try std.testing.expectEqualStrings("Materna (O Mother Dear, Jerusalem) / Samuel Augustus Ward [hymnal&#93;: Print Material Full Description: Performing Arts Encyclopedia, Library of Congress ", txt),
                else => unreachable,
            }
        },
        else => unreachable,
    }
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
    const arg_names = [_][]const u8{ "conventional_long_name", "common_name", "native_name", "image_flag", "image_coat", "symbol_type", "national_motto", "national_anthem", "image_map", "map_caption", "image_map2", "capital", "coordinates", "largest_city", "official_languages", "ethnic_groups", "ethnic_groups_year", "religion", "religion_year", "religion_ref", "demonym", "government_type", "leader_title1", "leader_name1", "leader_title2", "leader_name2", "leader_title3", "leader_name3", "leader_title4", "leader_name4", "legislature", "sovereignty_type", "established_event1", "established_date1", "established_event2", "established_date2", "established_event3", "established_date3", "area_km2", "area_rank", "area_sq_mi", "percent_water", "population_estimate", "population_estimate_rank", "population_estimate_year", "population_census_year", "population_density_km2", "population_density_sq_mi", "population_density_rank", "GDP_PPP", "GDP_PPP_year", "GDP_PPP_rank", "GDP_PPP_per_capita", "GDP_PPP_per_capita_rank", "GDP_nominal", "GDP_nominal_year", "GDP_nominal_rank", "GDP_nominal_per_capita", "GDP_nominal_per_capita_rank", "Gini", "Gini_year", "Gini_ref", "HDI", "HDI_year", "HDI_change", "HDI_ref", "HDI_rank", "currency", "currency_code", "time_zone", "utc_offset", "utc_offset_DST", "time_zone_DST", "date_format", "drives_on", "calling_code", "cctld", "today" };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var wp = MWParser.init(a, wikitext);
    try wp.parse();

    try std.testing.expect(wp.nodes.items.len == 1);

    switch (wp.nodes.items[0]) {
        .template => |tmpl| {
            try std.testing.expect(tmpl.args.len == arg_names.len);

            var it = tmpl.args.first;
            var i: usize = 0;
            while (it) |node| {
                try std.testing.expectEqualStrings(arg_names[i], node.data.name.?);
                it = node.next;
                i += 1;
            }
        },
        else => unreachable,
    }
}
