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
    level: u8,
};

pub const WikiPage = struct {
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
                        if (i == self.raw_wikitext.len) {
                            break;
                        }

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

                    i += 1;
                },

                // html entity that could be &lt;
                '&' => {
                    if (nextEql(self.raw_wikitext, "&lt;", i)) {
                        if (nextEql(self.raw_wikitext, "!--", i + "&lt;".len)) {
                            // skip html comment
                        } else {
                            // parse html tag
                        }
                    } else {
                        // parse html entity
                    }

                    i += 1;
                },

                // headings
                '=' => {
                    if (nextEql(self.raw_wikitext, "==", i)) {
                        // parse heading
                    }

                    i += 1;
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
fn nextEql(buf: []const u8, needle: []const u8, i: usize) bool {
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

    var wp = WikiPage.init(a, wikitext);

    const e = wp.parse();
    try std.testing.expectError(WikiPage.ParseError.IncompleteArgument, e);
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

    var wp = WikiPage.init(a, wikitext);
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
