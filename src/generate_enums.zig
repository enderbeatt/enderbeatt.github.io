const std = @import("std");
const ts = @import("tree-sitter"); 
const Io = std.Io;

pub const std_options: std.Options = .{
    .log_level = .debug,
};

extern fn tree_sitter_markdown() *ts.Language;
extern fn tree_sitter_markdown_inline() *ts.Language;

pub fn createEnum(w: *Io.Writer, name: []const u8, lang: *const ts.Language) !void {
    try w.print("pub const {s} = enum(u16) {\n", .{name});
    for (0..lang.nodeKindCount()) |i| {
        const smol: u16 = @intCast(i);
        const slice = lang.nodeKindForId(smol).?;
        try w.print("    {s} = {d},\n", .{slice, smol});
    }
    try w.writeAll("};\n");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena;
    const args = init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("Usage: generate_enums [output-file]", .{});
    }

    const buf: [4096]u8 = undefined;

    const markdown = tree_sitter_markdown();
    defer markdown.destroy();
}
