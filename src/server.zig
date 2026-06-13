const std = @import("std");
const net = std.Io.net;

pub const ServerError = std.Io.Dir.ReadFileAllocError || std.http.Server.Request.RespondError || error{WriteFailed};

fn openDir(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return try std.Io.Dir.openDirAbsolute(io, path, options);
    }
    return try std.Io.Dir.cwd().openDir(io, path, options);
}

pub fn serveError(err: ServerError, request: *std.http.Server.Request) !void {
    const res: std.http.Server.Request.RespondOptions = switch (err) {
        error.FileNotFound => .{
            .status = .not_found,
            .reason = "The file was not found",
        },
        error.IsDir => .{
            .status = .not_found,
            .reason = "The requested file is a directory",
        },
        else => .{
            .status = .internal_server_error,
            .reason = @errorName(err),
        },
    };
    try request.respond("", res);
}

pub fn getPageFile(target: []const u8) []const u8 {
    const file_name = target[1..];
    if (file_name.len == 0) {
        return "index.html";
    }
    return file_name;
}

pub fn servePage(io: std.Io, gpa: std.mem.Allocator, cwd: std.Io.Dir, request: *std.http.Server.Request) !void {
    std.log.info("Got request for serve path: {s}", .{request.head.target});
    const file_name = getPageFile(request.head.target);
    const file_contents = try cwd.readFileAlloc(
        io,
        file_name,
        gpa,
        .unlimited,
    );
    defer gpa.free(file_contents);
    try request.respond(file_contents, .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    if (args.len == 1) {
        std.log.err("Usage: blog [BLOG-DIR]", .{});
        return error.NoDir;
    }

    std.log.info("Watching over {s}", .{ args[1] });

    const blog_dir = try openDir(io, args[1], .{ .iterate = true });
    defer blog_dir.close(io);

    const addr = try net.IpAddress.parse("127.0.0.1", 2222);
    var sock = try addr.listen(io, .{ .reuse_address = true });
    defer sock.deinit(io);

    while (true) {
        const conn = try sock.accept(io);
        defer conn.close(io);
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var conn_reader = conn.reader(io, &rbuf);
        var http_writer = conn.writer(io, &wbuf);
        var http_server = std.http.Server.init(&conn_reader.interface, &http_writer.interface);
        var req = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => { continue; },
            else => { return err; },
        };
        servePage(io, init.arena.allocator(), blog_dir, &req) catch |err| {
            std.log.info("Could not serve page. Got: {s}", .{ @errorName(err) });
            try serveError(err, &req);
        };
    }
}
