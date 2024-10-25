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
    html_tag: []const u8,
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

pub const MWParser = struct {
    /// Contains list of nodes which will eventually contain parsed information
    nodes: std.ArrayList(MWNode),
    raw_wikitext: []const u8,
    /// Slices of text we want, these are referenced within each node
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
    };

    /// iterates through characters and dispatches to node specific parsing functions
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

                // html entity that could be &lt;
                '&' => {
                    if (nextEql(self.raw_wikitext, "&lt;", i)) {
                        if (nextEql(self.raw_wikitext, "!--", i + "&lt;".len)) {
                            // skip html comment
                            i += 1;
                        } else {
                            // parse html tag
                            i += 1;
                        }
                    } else {
                        // places entity in text becuase I suspect the failure could false trigger on regular text
                        if (cur_text_node.len > 0) {
                            try self.nodes.append(.{ .text = cur_text_node });
                        }

                        i = try self.parseHtmlEntity(i);

                        cur_text_node = self.raw_wikitext[i..];
                        cur_text_node.len = 0;
                    }
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

/// returns `true` if the needle is present starting at i.
///
/// `false` if out of bounds
inline fn nextEql(buf: []const u8, needle: []const u8, i: usize) bool {
    if (i + needle.len < buf.len) {
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
