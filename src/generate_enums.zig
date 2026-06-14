const std = @import("std");
const ts = @import("tree-sitter");
const Io = std.Io;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

extern fn tree_sitter_markdown() *ts.Language;
extern fn tree_sitter_markdown_inline() *ts.Language;

pub fn createEnum(w: *Io.Writer, name: []const u8, lang: *const ts.Language, arena: std.mem.Allocator) !void {
    try w.print("pub const {s} = enum {{\n", .{name});
    var map: std.array_hash_map.String([]const u8) = .empty;

    for (0..lang.nodeKindCount()) |i| {
        const smol: u16 = @intCast(i);
        const slice = lang.nodeKindForId(smol).?;
        const enum_field = blk: {
            if (std.zig.isValidId(slice) and !std.mem.eql(u8, slice, "_")) {
                break :blk try arena.dupe(u8, slice);
            } else if (std.mem.eql(u8, slice, "\"")) {
                break :blk try arena.dupe(u8,
                    \\@"\""
                );
            } else if (std.mem.eql(u8, slice, "\\")) {
                break :blk try arena.dupe(u8,
                    \\@"\\"
                );
            }
            break :blk try std.fmt.allocPrint(arena, "@\"{s}\"", .{slice});
        };
        const res = try map.getOrPutValue(arena, slice, enum_field);
        if (!res.found_existing) {
            try w.print("    {s},\n", .{enum_field});
        }
    }
    try w.writeAll("\n    pub const map = [_]@This() {\n");
    for (0..lang.nodeKindCount()) |i| {
        const smol: u16 = @intCast(i);
        const slice = lang.nodeKindForId(smol).?;
        const enum_field = map.get(slice).?;
        try w.print("        .{s},\n", .{enum_field});
    }
    try w.writeAll("    };\n");
    try w.writeAll("};\n");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("Usage: generate_enums [output-file]\n", .{});
        return error.WrongArguments;
    }

    var file = try Io.Dir.cwd().createFile(io, args[1], .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);

    const markdown = tree_sitter_markdown();
    defer markdown.destroy();
    try createEnum(&writer.interface, "Markdown", markdown, arena);

    const markdown_inline = tree_sitter_markdown_inline();
    defer markdown_inline.destroy();
    try createEnum(&writer.interface, "MarkdownInline", markdown_inline, arena);

    try writer.flush();
}
