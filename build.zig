const std = @import("std");
const Build = std.Build;

const Opts = struct {
    optimize: std.builtin.OptimizeMode,
    target: Build.ResolvedTarget,
};

const FILES_DIR = "blog";
const GENERATED_DIR = "generated";

const FILES_TO_WATCH = [_][]const u8{
    "test.md",
};

pub fn build(b: *Build) !void {
    const opts: Opts = .{
        .optimize = b.standardOptimizeOption(.{}),
        .target = b.standardTargetOptions(.{}),
    };
    const md2html_exe = md2html(b, &opts);
    const server_exe = server(b, &opts);

    const parse_step = b.step("parse", "Run md2html over dir");
    const parse_install = b.addInstallArtifact(md2html_exe, .{});

    const parse_gen = try generate(b, md2html_exe);

    parse_step.dependOn(&parse_install.step);
    parse_step.dependOn(&parse_gen.step);

    const serve_step = b.step("serve", "Run the HTTP server that serves the blog over localhost:2222");
    const serve_install = b.addInstallArtifact(server_exe, .{});
    const serve_run = b.addRunArtifact(server_exe);
    serve_run.addDirectoryArg(b.path(b.pathJoin(&.{ "zig-out", GENERATED_DIR })));
    serve_run.step.dependOn(&serve_install.step);
    serve_step.dependOn(&serve_run.step);

    const check_step = b.step("check", "See if program will compile");
    check_step.dependOn(&parse_install.step);
    check_step.dependOn(&serve_install.step);
}


fn generate(b: *Build, md2html_exe: *Build.Step.Compile) !*Build.Step.InstallDir {
    const parse_run = b.addRunArtifact(md2html_exe);

    for (FILES_TO_WATCH) |filename| {
        parse_run.addFileInput(b.path(b.pathJoin(&.{ FILES_DIR, filename })));
    }
    parse_run.addDirectoryArg(b.path(FILES_DIR));
    const gen_dir = parse_run.addOutputDirectoryArg(GENERATED_DIR);
    const install_step = b.addInstallDirectory(.{
        .source_dir = gen_dir,
        .install_dir = .prefix,
        .install_subdir = GENERATED_DIR,
    });
    
    return install_step;
}

fn server(b: *Build, opts: *const Opts) *Build.Step.Compile {
    return b.addExecutable(.{
        .name = "blog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        }),
    });
}

fn md2html(b: *Build, opts: *const Opts) *Build.Step.Compile {
    const tree_sitter = b.dependency("tree_sitter", .{
        .target = opts.target,
        .optimize = opts.optimize,
    });
    const markdown = getTreesitterParser(b, "markdown", opts);
    const markdown_inline = getTreesitterParser(b, "markdown-inline", opts);
    const exe = b.addExecutable(.{
        .name = "md2html",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/md2html.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{
                .{
                    .name = "tree-sitter",
                    .module = tree_sitter.module("tree_sitter"),
                }
            },
        }),
    });
    exe.root_module.linkLibrary(markdown);
    exe.root_module.linkLibrary(markdown_inline);
    return exe;
}

fn getTreesitterParser(b: *Build, name: []const u8, opts: *const Opts) *Build.Step.Compile {
    const mod = b.createModule(.{
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    const parser_root = b.pathJoin(&.{"vendor", name});
    mod.addCSourceFiles(.{
        .root = b.path(parser_root),
        .files = &.{
            "parser.c",
            "scanner.c",
        },
        .flags = &.{"-fPIE"},
    });
    b.installDirectory(.{
        .source_dir = b.path(b.pathJoin(&.{parser_root, "queries"})),
        .install_dir = .bin,
        .install_subdir = b.pathJoin(&.{"queries", name}),
    });
    const lib = b.addLibrary(.{
        .name = name,
        .root_module = mod,
    });
    b.installArtifact(lib);
    return lib;
}
