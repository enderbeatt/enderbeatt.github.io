const std = @import("std");
const ts = @import("tree-sitter");
const ts_help = @import("ts_help");

pub const std_options: std.Options = .{
    .log_level = .warn,
};

extern fn tree_sitter_markdown() *ts.Language;
extern fn tree_sitter_markdown_inline() *ts.Language;
extern fn tree_sitter_cpp() *ts.Language;
extern fn tree_sitter_zig() *ts.Language;

// what kind of things do i want?
// 1. I want to be able to do .md -> .html generation
// 2. I want it to watch over changes in .md files.
// 3. I also should be an http server which serves html....
//
// Let's start with http server part.
// I wonder how do they usually serve stuff?
// Do they keep it all in memory or just read from disk each time?
// I think I don't care, I will read them from disk each time.
// At this point, I might even make it a pure function lol.
//
// Okay, what do we do with the .md -> .html?
// We use treesitter!
// So what would be the shape of our html blobs?
// A tree with additional attributes.
// The problem comes when I have to do injections.
// Because I have to somehow find the node with this text and splice it.
// I mean we can get a list of highlight ranges, and then just add them as we go
// through the nodes.
// Basically we would need to check stuff like that in the leaf nodes.
// What is the next thing we need?
// Run queries. And injections. And abstract over that somehow.
// This is a tad bit difficult.
// I mean injections are a diffirent kind of a query.
// Because they always result in another parsed tree.

pub const HtmlDocument = struct {
    elements: std.ArrayList(Element),
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    const Escaper = struct {
        unescaped: []const u8,
        pub fn format(he: Escaper, w: *std.Io.Writer) !void {
            for (he.unescaped) |c| switch (c) {
                '&' => try w.writeAll("&amp;"),
                '<' => try w.writeAll("&lt;"),
                '>' => try w.writeAll("&gt;"),
                '"' => try w.writeAll("&quot;"),
                '\'' => try w.writeAll("&#39;"),
                else => try w.writeByte(c),
            };
        }
    };

    pub const Index = enum(u32) {
        root = 0,
        _,
        pub fn val(self: Index) u32 {
            return @intFromEnum(self);
        }
    };

    pub const Element = struct {
        /// Type of an element
        type: Type,

        /// A tag of an element (used in <tag>)
        /// if type == .text, the tag IS the text.
        tag: []const u8,

        /// Attributes of the HTML element
        attrs: std.array_hash_map.String(Attr) = .empty,

        /// Children of the element
        children: std.ArrayList(Index) = .empty,

        pub const Type = enum {
            text,
            void,
            regular,
            root,
        };

        pub const Attr = union(enum) {
            str: []const u8,
            boolean,
        };

        pub fn deinit(self: *Element, gpa: std.mem.Allocator) void {
            self.attrs.deinit(gpa);
            self.children.deinit(gpa);
            self.* = undefined;
        }
    };

    pub const PrintOptions = struct {
        indent: u8 = 2,
    };

    const PrintState = struct {
        opts: PrintOptions,
        state: struct {
            cur_indent: u16 = 0,
        },
    };

    pub const PrintError = error{WriteFailed};

    pub fn fmtEscapeHtml(unescaped: []const u8) Escaper {
        return .{ .unescaped = unescaped };
    }

    pub fn addNode(self: *HtmlDocument, parent_idx: Index, element: Element) !Index {
        const idx: Index = @enumFromInt(self.elements.items.len);
        try self.elements.append(self.gpa, element);
        var parent = self.getElement(parent_idx);
        try parent.children.append(self.gpa, idx);
        return idx;
    }

    pub fn getElement(self: *const HtmlDocument, idx: Index) *Element {
        return &self.elements.items[@intFromEnum(idx)];
    }

    pub fn init(gpa: std.mem.Allocator) !HtmlDocument {
        var res: HtmlDocument = .{
            .elements = .empty,
            .gpa = gpa,
            .arena = .init(gpa),
        };
        try res.elements.append(res.gpa, .{
            .type = .root,
            .attrs = .empty,
            .tag = "",
            .children = .empty,
        });
        return res;
    }

    fn printText(self: *const HtmlDocument, el: *const HtmlDocument.Element, w: *std.Io.Writer, state: *PrintState) !void {
        _ = self;
        _ = state;
        try w.print("{f}", .{fmtEscapeHtml(el.tag)});
    }

    fn printAttrs(self: *const HtmlDocument, attr_names: []const []const u8, attr_values: []const Element.Attr, w: *std.Io.Writer, state: *PrintState) !void {
        _ = self;
        _ = state;
        for (attr_names, attr_values) |name, value| {
            try w.writeByte(' ');
            try w.writeAll(name);
            switch (value) {
                .boolean => {},
                .str => |s| {
                    std.log.debug("attr {s}={s}", .{ name, s });
                    try w.print("=\"{s}\"", .{s});
                },
            }
        }
    }

    fn printVoid(self: *const HtmlDocument, el: *const HtmlDocument.Element, w: *std.Io.Writer, state: *PrintState) !void {
        try w.print("<{s}", .{el.tag});
        try self.printAttrs(el.attrs.keys(), el.attrs.values(), w, state);
        try w.writeAll("/>");
    }

    fn printRegular(self: *const HtmlDocument, el: *const HtmlDocument.Element, w: *std.Io.Writer, state: *PrintState) !void {
        try w.print("<{s}", .{el.tag});
        try self.printAttrs(el.attrs.keys(), el.attrs.values(), w, state);
        try w.writeAll(">");

        for (el.children.items) |idx| {
            try self.printElementTree(idx, w, state);
        }

        try w.print("</{s}>", .{el.tag});
    }

    fn printElementTree(self: *const HtmlDocument, node: HtmlDocument.Index, w: *std.Io.Writer, state: *PrintState) PrintError!void {
        const el = self.getElement(node);
        switch (el.type) {
            .text => try self.printText(el, w, state),
            .void => try self.printVoid(el, w, state),
            .regular => try self.printRegular(el, w, state),
            .root => unreachable,
        }
    }

    pub fn print(self: *const HtmlDocument, w: *std.Io.Writer, print_opts: PrintOptions) !void {
        var state: PrintState = .{ .opts = print_opts, .state = .{} };
        const root = self.getElement(Index.root);
        std.debug.assert(root.type == .root);
        for (root.children.items) |idx| {
            try self.printElementTree(idx, w, &state);
        }
    }

    pub fn deinit(self: *HtmlDocument) void {
        for (self.elements.items) |*e| {
            e.deinit(self.gpa);
        }
        self.elements.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Components = struct {
    pub fn document(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        { // <!DOCTYPE html>
            const idx = try doc.addNode(parent, .{
                .type = .void,
                .tag = "!DOCTYPE",
            });
            var el = doc.getElement(idx);
            try el.attrs.put(doc.gpa, "html", .boolean);
        }
        // <html lang="en">
        const html_idx = try doc.addNode(parent, .{
            .type = .regular,
            .tag = "html",
        });
        var html_el = doc.getElement(html_idx);
        try html_el.attrs.put(doc.gpa, "lang", .{ .str = "en" });

        // <head>
        const head_idx = try doc.addNode(html_idx, .{
            .type = .regular,
            .tag = "head",
        });

        // <meta charset="utf-8">
        {
            const idx = try doc.addNode(head_idx, .{
                .type = .void,
                .tag = "meta",
            });
            var el = doc.getElement(idx);
            try el.attrs.put(doc.gpa, "charset", .{ .str = "utf-8" });
        }

        // <meta viewport=...>
        {
            const idx = try doc.addNode(head_idx, .{
                .type = .void,
                .tag = "meta",
            });
            var el = doc.getElement(idx);
            try el.attrs.put(doc.gpa, "viewport", .{ .str = "viewport" });
            try el.attrs.put(doc.gpa, "content", .{ .str = "width=device-width, initial-scale=1" });
        }

        // <link>
        const link_idx = try doc.addNode(head_idx, .{
            .type = .void,
            .tag = "link",
        });
        var link_el = doc.getElement(link_idx);
        try link_el.attrs.put(doc.gpa, "rel", .{ .str = "stylesheet" });
        try link_el.attrs.put(doc.gpa, "href", .{ .str = "style.css" });

        // <body>
        return try doc.addNode(html_idx, .{
            .type = .regular,
            .tag = "body",
        });
    }

    pub fn p(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = "p",
        });
    }

    pub fn code(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = "code",
        });
    }

    pub fn nav(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = "nav",
        });
    }

    pub fn time(doc: *HtmlDocument, parent: HtmlDocument.Index, datetime: []const u8) !HtmlDocument.Index {
        const idx = try doc.addNode(parent, .{
            .type = .regular,
            .tag = "time",
        });
        var el = doc.getElement(idx);
        try el.attrs.put(doc.gpa, "datetime", .{ .str = datetime });
        return idx;
    }

    pub fn multilineCode(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        const pre = try doc.addNode(parent, .{
            .type = .regular,
            .tag = "pre",
        });
        return try doc.addNode(pre, .{
            .type = .regular,
            .tag = "code",
        });
    }

    pub fn img(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .void,
            .tag = "img",
        });
    }

    pub fn a(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = "a",
        });
    }

    pub fn br(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .void,
            .tag = "br",
        });
    }

    pub fn hr(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .void,
            .tag = "hr",
        });
    }

    pub fn strong(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = "strong",
        });
    }

    pub fn span(doc: *HtmlDocument, parent: HtmlDocument.Index, class: ?[]const u8) !HtmlDocument.Index {
        const idx = try doc.addNode(parent, .{
            .type = .regular,
            .tag = "span",
        });
        var el = doc.getElement(idx);
        if (class) |ss| {
            try el.attrs.put(doc.gpa, "class", .{ .str = ss });
        }
        return idx;
    }

    pub fn s(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = "s",
        });
    }

    pub fn em(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = "em",
        });
    }

    pub fn ul(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = "ul",
        });
    }

    pub fn ol(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = "ol",
        });
    }

    pub fn li(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = "li",
        });
    }

    pub fn blockquote(doc: *HtmlDocument, parent: HtmlDocument.Index) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = "blockquote",
        });
    }

    pub fn h(doc: *HtmlDocument, parent: HtmlDocument.Index, level: u3) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .regular,
            .tag = switch (level) {
                1 => "h1",
                2 => "h2",
                3 => "h3",
                4 => "h4",
                5 => "h5",
                6 => "h6",
                else => unreachable,
            },
        });
    }

    pub fn text(doc: *HtmlDocument, parent: HtmlDocument.Index, content: []const u8) !HtmlDocument.Index {
        return try doc.addNode(parent, .{
            .type = .text,
            .tag = content,
        });
    }
};

// so the worst part in how markdown treesitter represents plain text is that IT
// FUCKING DOES NOT.
//
// Hello, World!
// Hey, **bold and ~italic inside bold~** is that fine
// (paragraph ; [6, 0] - [8, 0]
//   (inline ; [6, 0] - [7, 51]
//     (inline ; [6, 0] - [7, 51]
//       (strong_emphasis ; [7, 5] - [7, 38]
//         (emphasis_delimiter) ; [7, 5] - [7, 6]
//         (emphasis_delimiter) ; [7, 6] - [7, 7]
//         (strikethrough ; [7, 16] - [7, 36]
//           (emphasis_delimiter) ; [7, 16] - [7, 17]
//           (emphasis_delimiter)) ; [7, 35] - [7, 36]
//         (emphasis_delimiter) ; [7, 36] - [7, 37]
//         (emphasis_delimiter))))))) ; [7, 37] - [7, 38]
// No node for text, it would be so easy man...
// Okay, so we start the text from the inline injection.
// and then we chip away at the text slice i guess....
// it is a bit weird i'd say.
// So basically we start from inline with a slice.
// When we encounter a node, we split up the text on the start of the node and
// commit the changes to the doc. Also we make a split at the end of the node.
// I think we can keep up this logic and just not commit the zero length changes.
// or we don't go into the nodes that we know should be concealed.

pub const MarkdownKind = enum(u8) {};

pub fn emitText(doc: *HtmlDocument, parent: HtmlDocument.Index, cursor: *ts.TreeCursor, contents: []const u8) !void {
    var el_idx: HtmlDocument.Index = parent;
    const node = cursor.node();
    const name = cursor.node().kind();
    const kind_id = cursor.node().kindId();
    std.log.debug("Parsing text node {s} with text {s}", .{ name, contents[node.startByte()..node.endByte()] });
    defer std.log.debug("Quit parsing test node {s}", .{name});
    switch (ts_help.MarkdownInline.map[kind_id]) {
        .strong_emphasis => {
            el_idx = try Components.strong(doc, parent);
        },
        .strikethrough => {
            el_idx = try Components.s(doc, parent);
        },
        .emphasis => {
            el_idx = try Components.em(doc, parent);
        },
        .code_span => {
            el_idx = try Components.code(doc, parent);
        },
        .link_destination, .link_title, .code_span_delimiter, .emphasis_delimiter => return,
        .hard_line_break => {
            _ = try Components.br(doc, parent);
        },
        .backslash_escape => {
            // removing backslash
            _ = try Components.text(doc, parent, contents[node.startByte() + 1 .. node.endByte()]);
            return;
        },
        .uri_autolink => {
            el_idx = try Components.a(doc, parent);
            var el = doc.getElement(el_idx);
            const slice = contents[node.startByte() + 1 .. node.endByte() - 1];
            try el.attrs.put(doc.gpa, "href", .{ .str = slice });
            _ = try Components.text(doc, el_idx, slice);
            return;
        },
        .inline_link => {
            std.debug.assert(cursor.gotoFirstChild());
            defer std.debug.assert(cursor.gotoParent());
            el_idx = try Components.a(doc, parent);
            while (true) {
                const child_node = cursor.node();
                if (cursor.node().isNamed()) {
                    const slice = contents[child_node.startByte()..child_node.endByte()];
                    var el = doc.getElement(el_idx);
                    switch (ts_help.MarkdownInline.map[child_node.kindId()]) {
                        .link_destination => try el.attrs.put(doc.gpa, "href", .{ .str = slice }),
                        // quotes are also a part of link_title for some reason
                        .link_title => try el.attrs.put(doc.gpa, "title", .{ .str = slice[1 .. slice.len - 1] }),
                        .link_text => try emitText(doc, el_idx, cursor, contents),
                        else => unreachable,
                    }
                }
                if (!cursor.gotoNextSibling()) {
                    break;
                }
            }
            return;
        },
        .image => {
            std.debug.assert(cursor.gotoFirstChild());
            defer std.debug.assert(cursor.gotoParent());
            el_idx = try Components.img(doc, parent);
            var el = doc.getElement(el_idx);
            while (true) {
                const child_node = cursor.node();
                if (cursor.node().isNamed()) {
                    const slice = contents[child_node.startByte()..child_node.endByte()];
                    switch (ts_help.MarkdownInline.map[child_node.kindId()]) {
                        .link_destination => try el.attrs.put(doc.gpa, "src", .{ .str = slice }),
                        // quotes are also a part of link_title for some reason
                        .link_title => try el.attrs.put(doc.gpa, "alt", .{ .str = slice[1 .. slice.len - 1] }),
                        .image_description => try el.attrs.put(doc.gpa, "title", .{ .str = slice }),
                        else => unreachable,
                    }
                }
                if (!cursor.gotoNextSibling()) {
                    break;
                }
            }
            return;
        },
        .@"inline",
        .link_text,
        => {},
        else => {
            std.log.warn("Unrecognized text node: {s}", .{name});
        },
    }
    var begin = node.startByte();
    const end = node.endByte();
    if (cursor.gotoFirstChild()) {
        defer std.debug.assert(cursor.gotoParent());
        while (true) {
            const child_node = cursor.node();
            if (child_node.isNamed()) {
                const next_begin = child_node.startByte();
                const slice = contents[begin..next_begin];
                if (slice.len > 0) {
                    _ = try Components.text(doc, el_idx, slice);
                }
                begin = child_node.endByte();
                try emitText(doc, el_idx, cursor, contents);
            }
            if (!cursor.gotoNextSibling()) {
                break;
            }
        }
    }
    const slice = contents[begin..end];
    if (slice.len > 0) {
        _ = try Components.text(doc, el_idx, slice);
    }
}

pub fn emitCode(doc: *HtmlDocument, parent: HtmlDocument.Index, cursor: *ts.TreeCursor, highlights: *const Parser.Result.HighlightMap, contents: []const u8) !void {
    var el_idx: HtmlDocument.Index = parent;
    const node = cursor.node();
    const name = cursor.node().kind();
    std.log.debug("Parsing code node {s} with text {s}", .{ name, contents[node.startByte()..node.endByte()] });
    const id = @intFromPtr(node.id);
    if (highlights.get(id)) |class| {
        el_idx = try Components.span(doc, parent, class);
    }
    var begin = node.startByte();
    const end = node.endByte();
    if (cursor.gotoFirstChild()) {
        defer std.debug.assert(cursor.gotoParent());
        while (true) {
            const child_node = cursor.node();
            const next_begin = child_node.startByte();
            const slice = contents[begin..next_begin];
            if (slice.len > 0) {
                _ = try Components.text(doc, el_idx, slice);
            }
            begin = child_node.endByte();
            try emitCode(doc, el_idx, cursor, highlights, contents);
            if (!cursor.gotoNextSibling()) {
                break;
            }
        }
    }
    const slice = contents[begin..end];
    if (slice.len > 0) {
        _ = try Components.text(doc, el_idx, slice);
    }
}

pub fn emitNode(doc: *HtmlDocument, parent: HtmlDocument.Index, cursor: *ts.TreeCursor, trees: *const Parser.Result, contents: []const u8) !void {
    var el_idx: HtmlDocument.Index = parent;
    const node = cursor.node();
    const name = cursor.node().kind();
    std.log.debug("Parsing node {s} with text {s}", .{ name, contents[node.startByte()..node.endByte()] });
    const id = @intFromPtr(node.id);
    if (trees.trees.get(id)) |tree| {
        std.log.debug("Got injection: {s}", .{@tagName(tree.kind)});
        switch (tree.kind) {
            .markdown_inline => {
                // here we should start parsing it as a text.
                var injection_cursor = tree.tree.walk();
                defer injection_cursor.destroy();
                try emitText(
                    doc,
                    el_idx,
                    &injection_cursor,
                    tree.bytes,
                );
                return;
            },
            .code_block => {
                var code_cursor = tree.tree.walk();
                defer code_cursor.destroy();
                try emitCode(
                    doc,
                    try Components.multilineCode(doc, parent),
                    &code_cursor,
                    &tree.highlights,
                    tree.bytes,
                );
                return;
            },
            .markdown => {},
            // else => |v| std.log.warn("TODO: tree.kind == {s}", .{@tagName(v)}),
        }
    }
    const kind_id = cursor.node().kindId();
    switch (ts_help.Markdown.map[kind_id]) {
        .document => {
            el_idx = try Components.document(doc, parent);
        },
        .minus_metadata => {
            try emitFrontMatter(doc, parent, contents[node.startByte() + 4 .. node.endByte() - 4]);
        },
        .paragraph => {
            el_idx = try Components.p(doc, parent);
        },
        .atx_heading => {
            std.debug.assert(cursor.gotoFirstChild());
            defer std.debug.assert(cursor.gotoParent());
            const heading_id = cursor.node().kindId();
            el_idx = try Components.h(
                doc,
                parent,
                switch (ts_help.Markdown.map[heading_id]) {
                    .atx_h1_marker => 1,
                    .atx_h2_marker => 2,
                    .atx_h3_marker => 3,
                    .atx_h4_marker => 4,
                    .atx_h5_marker => 5,
                    .atx_h6_marker => 6,
                    else => unreachable,
                },
            );
        },
        .setext_heading => {
            std.debug.assert(cursor.gotoLastChild());
            defer std.debug.assert(cursor.gotoParent());
            const heading_id = cursor.node().kindId();
            el_idx = try Components.h(
                doc,
                parent,
                switch (ts_help.Markdown.map[heading_id]) {
                    .setext_h1_underline => 1,
                    .setext_h2_underline => 2,
                    else => unreachable,
                },
            );
        },
        .list => {
            std.debug.assert(cursor.gotoFirstChild());
            defer std.debug.assert(cursor.gotoParent());
            std.debug.assert(cursor.gotoFirstChild());
            defer std.debug.assert(cursor.gotoParent());
            el_idx = switch (ts_help.Markdown.map[cursor.node().kindId()]) {
                .list_marker_minus => try Components.ul(doc, parent),
                .list_marker_dot => try Components.ol(doc, parent),
                else => unreachable,
            };
        },
        .list_item => {
            el_idx = try Components.li(doc, parent);
        },
        .block_quote => {
            el_idx = try Components.blockquote(doc, parent);
        },
        .thematic_break => {
            el_idx = try Components.hr(doc, parent);
        },
        .section,
        .list_marker_minus,
        .list_marker_dot,
        .block_continuation,
        .block_quote_marker,
        .atx_h1_marker,
        .atx_h2_marker,
        .atx_h3_marker,
        .atx_h4_marker,
        .atx_h5_marker,
        .atx_h6_marker,
        .setext_h1_underline,
        .setext_h2_underline,
        => {},
        else => {
            std.log.warn("Unrecognized node: {s}", .{name});
        },
    }
    if (!cursor.gotoFirstChild()) {
        return;
    }
    defer std.debug.assert(cursor.gotoParent());
    while (true) {
        if (cursor.node().isNamed()) {
            try emitNode(doc, el_idx, cursor, trees, contents);
        }
        if (!cursor.gotoNextSibling()) {
            break;
        }
    }
}

pub const FrontMatter = struct {
    pub const Key = enum {
        unknown,
        created,
        name,
    };
    date: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub fn emitHeader(doc: *HtmlDocument, parent: HtmlDocument.Index) !void {
    const nav_idx = try Components.nav(doc, parent);
    {
        const a_idx = try Components.a(doc, nav_idx);
        var el = doc.getElement(a_idx);
        try el.attrs.put(doc.gpa, "href", .{ .str = "/" });
        _ = try Components.text(doc, a_idx, "Home");
    }
}

pub fn emitFrontMatter(doc: *HtmlDocument, parent: HtmlDocument.Index, contents: []const u8) !void {
    // we are not doing yaml, it's just going to be key: value\n
    var r = std.Io.Reader.fixed(contents);
    var front: FrontMatter = .{};
    while (r.bufferedLen() > 0) {
        const key = try r.takeDelimiter(':') orelse return error.KeyMissing;
        r.toss(1);
        const value = try r.takeDelimiter('\n') orelse return error.ValueMissing;
        switch (std.meta.stringToEnum(FrontMatter.Key, key) orelse .unknown) {
            .created => front.date = value,
            .name => front.name = value,
            .unknown => continue,
        }
    }
    try emitHeader(doc, parent);
    if (front.name) |name| {
        const h1_idx = try Components.h(doc, parent, 1);
        _ = try Components.text(doc, h1_idx, name);
    }
    if (front.date) |date| {
        const date_idx = try Components.time(doc, parent, date);
        _ = try Components.text(
            doc,
            date_idx,
            try std.fmt.allocPrint(doc.arena.allocator(), "Published on {s}", .{date}),
        );
    }
}

pub const Parser = struct {
    registry: *const Language.Registry,

    markdown: *ts.Parser,
    markdown_inline: *ts.Parser,
    cpp: *ts.Parser,
    zig: *ts.Parser,

    pub const Result = struct {
        trees: TreeMap = .empty,
        root: usize,

        pub const Tree = struct {
            bytes: []const u8,
            tree: *ts.Tree,
            kind: enum {
                markdown,
                markdown_inline,
                code_block,
            },
            highlights: HighlightMap = .empty,

            pub fn deinit(self: *Tree, gpa: std.mem.Allocator) void {
                self.tree.destroy();
                self.highlights.deinit(gpa);
                self.* = undefined;
            }
        };

        pub const TreeMap = std.array_hash_map.Auto(usize, Tree);
        pub const HighlightMap = std.array_hash_map.Auto(usize, []const u8);

        pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
            for (self.trees.values()) |*t| {
                t.deinit(gpa);
            }
            self.trees.deinit(gpa);
            self.* = undefined;
        }
    };

    pub fn init(registry: *const Language.Registry) !Parser {
        const markdown_parser = ts.Parser.create();
        try markdown_parser.setLanguage(registry.markdown.language);
        const markdown_inline_parser = ts.Parser.create();
        try markdown_inline_parser.setLanguage(registry.markdown_inline.language);
        const cpp_parser = ts.Parser.create();
        try cpp_parser.setLanguage(registry.cpp.language);
        const zig_parser = ts.Parser.create();
        try zig_parser.setLanguage(registry.zig.language);

        return .{
            .registry = registry,
            .markdown = markdown_parser,
            .markdown_inline = markdown_inline_parser,
            .cpp = cpp_parser,
            .zig = zig_parser,
        };
    }

    pub fn parse(self: *const Parser, bytes: []const u8, gpa: std.mem.Allocator) !Result {
        var tree_map: Result.TreeMap = .empty;
        errdefer tree_map.deinit(gpa);

        const tree = self.markdown.parseString(bytes, null) orelse return error.ParseMarkdownError;
        const root = tree.rootNode();
        const root_id = @intFromPtr(root.id);

        try tree_map.put(gpa, root_id, .{
            .kind = .markdown,
            .bytes = bytes,
            .tree = tree,
        });

        const query_cursor = ts.QueryCursor.create();
        defer query_cursor.destroy();
        query_cursor.exec(self.registry.markdown.injections.?, root);

        while (query_cursor.nextMatch()) |match| {
            std.log.debug("Found match with pattern_index {d}", .{match.pattern_index});
            switch (match.pattern_index) {
                // code block
                0 => {
                    var lang_opt: ?[]const u8 = null;
                    var code_bytes_opt: ?[]const u8 = null;
                    var node_id_opt: ?usize = null;
                    for (match.captures) |capture| {
                        switch (capture.index) {
                            0 => lang_opt = bytes[capture.node.startByte()..capture.node.endByte()],
                            1 => {
                                code_bytes_opt = bytes[capture.node.startByte()..capture.node.endByte()];
                                node_id_opt = @intFromPtr(capture.node.id);
                            },
                            else => unreachable,
                        }
                    }

                    const lang = lang_opt.?;
                    const code_bytes = code_bytes_opt.?;

                    const code_parser, const highlight_query = if (std.mem.eql(u8, lang, "markdown"))
                        .{ self.markdown, self.registry.markdown.highlights }
                    else if (std.mem.eql(u8, lang, "markdown-inline"))
                        .{ self.markdown, self.registry.markdown.highlights }
                    else if (std.mem.eql(u8, lang, "cpp"))
                        .{ self.cpp, self.registry.cpp.highlights }
                    else if (std.mem.eql(u8, lang, "zig"))
                        .{ self.zig, self.registry.zig.highlights }
                    else {
                        std.log.warn("Codeblock with unknown language: {s}", .{lang});
                        continue;
                    };

                    const code_tree = code_parser.parseString(
                        code_bytes,
                        null,
                    ) orelse return error.ParseCodeBlockError;

                    var map: Result.HighlightMap = .empty;
                    if (highlight_query) |query| {
                        const highlight_query_cursor = ts.QueryCursor.create();
                        defer highlight_query_cursor.destroy();
                        highlight_query_cursor.exec(query, code_tree.rootNode());
                        while (highlight_query_cursor.nextMatch()) |highlight_match| {
                            for (highlight_match.captures) |capture| {
                                try map.put(gpa, @intFromPtr(capture.node.id), query.captureNameForId(capture.index).?);
                            }
                        }
                    }

                    const node_id = node_id_opt.?;
                    try tree_map.put(gpa, node_id, .{
                        .kind = .code_block,
                        .bytes = code_bytes,
                        .tree = code_tree,
                        .highlights = map,
                    });
                },
                // inline
                5 => {
                    for (match.captures) |capture| {
                        const injection_bytes = bytes[capture.node.startByte()..capture.node.endByte()];
                        const inline_tree = self.markdown_inline.parseString(
                            injection_bytes,
                            null,
                        ) orelse return error.ParseMarkdownInlineError;
                        try tree_map.put(gpa, @intFromPtr(capture.node.id), .{
                            .kind = .markdown_inline,
                            .bytes = injection_bytes,
                            .tree = inline_tree,
                        });
                    }
                },
                else => {},
            }
        }

        return .{
            .trees = tree_map,
            .root = root_id,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.markdown.destroy();
        self.markdown_inline.destroy();
        self.cpp.destroy();
        self.zig.destroy();
        self.* = undefined;
    }
};

pub const Language = struct {
    language: *const ts.Language,
    injections: ?*ts.Query = null,
    highlights: ?*ts.Query = null,

    pub const Registry = struct {
        markdown: Language,
        markdown_inline: Language,
        cpp: Language,
        zig: Language,

        const QueryError = std.Io.Dir.ReadFileAllocError || ts.Query.Error;

        fn getQuery(io: std.Io, filename: []const u8, language: *const ts.Language, gpa: std.mem.Allocator) !*ts.Query {
            errdefer {
                std.log.err("Failed to get query from {s}", .{filename});
            }
            const cwd = std.Io.Dir.cwd();

            const injections_file = try cwd.readFileAlloc(io, filename, gpa, .unlimited);
            defer gpa.free(injections_file);
            var err: u32 = undefined;
            return try ts.Query.create(language, injections_file, &err);
        }

        fn logErr(err: QueryError) ?*ts.Query {
            std.log.err("Error: {s}", .{@errorName(err)});
            return null;
        }

        pub fn init(io: std.Io, gpa: std.mem.Allocator) !Registry {
            var self: Registry = .{
                .markdown = .{
                    .language = tree_sitter_markdown(),
                },
                .markdown_inline = .{
                    .language = tree_sitter_markdown_inline(),
                },
                .cpp = .{
                    .language = tree_sitter_cpp(),
                },
                .zig = .{
                    .language = tree_sitter_zig(),
                },
            };
            self.markdown.injections = getQuery(
                io,
                "vendor/markdown/queries/injections.scm",
                self.markdown.language,
                gpa,
            ) catch |err| logErr(err);

            self.markdown_inline.injections = getQuery(
                io,
                "vendor/markdown-inline/queries/injections.scm",
                self.markdown_inline.language,
                gpa,
            ) catch |err| logErr(err);

            self.cpp.injections = getQuery(
                io,
                "vendor/cpp/queries/injections.scm",
                self.cpp.language,
                gpa,
            ) catch |err| logErr(err);
            self.cpp.highlights = getQuery(
                io,
                "vendor/cpp/queries/highlights.scm",
                self.cpp.language,
                gpa,
            ) catch |err| logErr(err);

            self.zig.injections = getQuery(
                io,
                "vendor/zig/queries/injections.scm",
                self.zig.language,
                gpa,
            ) catch |err| logErr(err);

            self.zig.highlights = getQuery(
                io,
                "vendor/zig/queries/highlights.scm",
                self.zig.language,
                gpa,
            ) catch |err| logErr(err);

            return self;
        }

        pub fn deinit(self: *Registry) void {
            self.markdown.deinit();
            self.markdown_inline.deinit();
            self.cpp.deinit();
            self.zig.deinit();
            self.* = undefined;
        }
    };

    pub fn deinit(self: *Language) void {
        self.language.destroy();
        if (self.injections) |q| {
            q.destroy();
        }
        if (self.highlights) |q| {
            q.destroy();
        }
        self.* = undefined;
    }
};

pub fn parseFile(gpa: std.mem.Allocator, contents: []const u8, parser: *const Parser) !HtmlDocument {
    var res = try parser.parse(contents, gpa);
    defer res.deinit(gpa);

    const tree = res.trees.getPtr(res.root).?;

    var doc: HtmlDocument = try .init(gpa);
    var cursor = tree.tree.walk();
    defer cursor.destroy();

    // try emitHeader(&doc, HtmlDocument.Index.root);
    try emitNode(&doc, HtmlDocument.Index.root, &cursor, &res, tree.bytes);

    return doc;
}

fn openDir(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return try std.Io.Dir.openDirAbsolute(io, path, options);
    }
    return try std.Io.Dir.cwd().openDir(io, path, options);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    if (args.len < 3) {
        std.log.err("Usage: md2html [MD-DIR] [HTML-DIR]", .{});
        return error.NotEnoughArgs;
    }

    ts.setAllocator(gpa);
    defer ts.setAllocator(null);

    std.log.info("Markdown dir: {s}", .{args[1]});
    std.log.info("Html dir: {s}", .{args[2]});

    const md_dir = try openDir(io, args[1], .{ .iterate = true });
    defer md_dir.close(io);

    const html_dir = try openDir(io, args[2], .{});
    defer html_dir.close(io);

    var registry: Language.Registry = try .init(io, gpa);
    defer registry.deinit();

    var parser: Parser = try .init(&registry);
    defer parser.deinit();

    var md_walker = try md_dir.walk(gpa);
    defer md_walker.deinit();
    while (try md_walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                const name_md = entry.basename;
                const name = std.mem.cutSuffix(u8, name_md, ".md") orelse continue;
                const name_html = try std.mem.join(arena, ".", &.{ name, "html" });
                const file_md = try md_dir.readFileAlloc(io, name_md, gpa, .unlimited);
                defer gpa.free(file_md);
                var doc = try parseFile(gpa, file_md, &parser);
                defer doc.deinit();

                const file_html = html_dir.openFile(io, name_html, .{ .mode = .write_only }) catch |err| switch (err) {
                    error.FileNotFound => try html_dir.createFile(io, name_html, .{}),
                    else => return err,
                };
                defer file_html.close(io);

                var buf: [4096]u8 = undefined;
                var writer = file_html.writer(io, &buf);
                try doc.print(&writer.interface, .{});
                try writer.flush();
            },
            else => {},
        }
    }
}
