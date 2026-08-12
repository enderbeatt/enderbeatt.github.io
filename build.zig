const std = @import("std");
const Build = std.Build;

const Opts = struct {
    optimize: std.builtin.OptimizeMode,
    target: Build.ResolvedTarget,
};

const ParserModules = struct {
    markdown: *Build.Step.Compile,
    markdown_inline: *Build.Step.Compile,
    cpp: *Build.Step.Compile,
    zig: *Build.Step.Compile,

    const ParserOptions = struct {
        opts: *const Opts,
        external_scanner: bool = true,
    };

    pub fn init(b: *Build, opts: *const Opts) ParserModules {
        return .{
            .markdown = getTreesitterParser(b, "markdown", .{
                .opts = opts,
            }),
            .markdown_inline = getTreesitterParser(b, "markdown-inline", .{
                .opts = opts,
            }),
            .cpp = getTreesitterParser(b, "cpp", .{
                .opts = opts,
            }),
            .zig = getTreesitterParser(b, "zig", .{
                .opts = opts,
                .external_scanner = false,
            }),
        };
    }

    fn getTreesitterParser(b: *Build, name: []const u8, opts: ParserOptions) *Build.Step.Compile {
        const mod = b.createModule(.{
            .target = opts.opts.target,
            .optimize = opts.opts.optimize,
            .link_libc = true,
        });
        const parser_root = b.pathJoin(&.{ "vendor", name });
        mod.addCSourceFiles(.{
            .root = b.path(parser_root),
            .files = if (opts.external_scanner) &.{
                "parser.c",
                "scanner.c",
            } else &.{
                "parser.c",
            },
            .flags = &.{"-O2"},
        });
        b.installDirectory(.{
            .source_dir = b.path(b.pathJoin(&.{ parser_root, "queries" })),
            .install_dir = .bin,
            .install_subdir = b.pathJoin(&.{ "queries", name }),
        });
        const lib = b.addLibrary(.{
            .name = name,
            .root_module = mod,
        });
        b.installArtifact(lib);
        return lib;
    }

    pub fn link(p: *const ParserModules, mod: *Build.Module) void {
        mod.linkLibrary(p.markdown);
        mod.linkLibrary(p.markdown_inline);
        mod.linkLibrary(p.cpp);
        mod.linkLibrary(p.zig);
    }
};

const FILES_DIR = "blog";
const GENERATED_DIR = "generated";

const FILES_TO_WATCH = [_][]const u8{
    "index.md",
    "do-we-need-vim-at-this-point.md",
};

pub fn build(b: *Build) !void {
    const opts: Opts = .{
        .optimize = b.standardOptimizeOption(.{}),
        .target = b.standardTargetOptions(.{}),
    };
    const parser_modules: ParserModules = .init(b, &opts);
    const generate_enums_exe = generate_enums(b, &opts, &parser_modules);
    const md2html_exe = md2html(b, &opts, generate_enums_exe, &parser_modules);
    const server_exe = server(b, &opts);

    const gen_step = b.step("gen", "Test the enum generation");
    const get_run_step = b.addRunArtifact(generate_enums_exe);
    get_run_step.addPassthruArgs();
    gen_step.dependOn(&get_run_step.step);

    const parse_step = b.step("parse", "Run md2html over dir");
    const parse_install = b.addInstallArtifact(md2html_exe, .{});

    const parse_gen = try generateBlog(b, md2html_exe);

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

fn generateBlog(b: *Build, md2html_exe: *Build.Step.Compile) !*Build.Step.InstallFile {
    const parse_run = b.addRunArtifact(md2html_exe);

    for (FILES_TO_WATCH) |filename| {
        parse_run.addFileInput(b.path(b.pathJoin(&.{ FILES_DIR, filename })));
    }
    parse_run.addDirectoryArg(b.path(FILES_DIR));
    const gen_dir = parse_run.addOutputDirectoryArg(GENERATED_DIR);
    const install_dir_step = b.addInstallDirectory(.{
        .source_dir = gen_dir,
        .install_dir = .prefix,
        .install_subdir = GENERATED_DIR,
    });
    const install_css_step = b.addInstallFileWithDir(
        b.path(b.pathJoin(&.{ FILES_DIR, "style.css" })),
        .{
            .custom = GENERATED_DIR,
        },
        "style.css",
    );
    install_css_step.step.dependOn(&install_dir_step.step);

    return install_css_step;
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

fn md2html(b: *Build, opts: *const Opts, gen: *Build.Step.Compile, mods: *const ParserModules) *Build.Step.Compile {
    const tree_sitter = b.dependency("tree_sitter", .{
        .target = opts.target,
        .optimize = opts.optimize,
    });

    const gen_step = b.addRunArtifact(gen);
    const out = gen_step.addOutputFileArg("ts_help.zig");

    const exe = b.addExecutable(.{
        .name = "md2html",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/md2html.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{.{
                .name = "tree-sitter",
                .module = tree_sitter.module("tree_sitter"),
            }},
        }),
    });
    exe.root_module.addAnonymousImport("ts_help", .{
        .root_source_file = out,
    });
    mods.link(exe.root_module);
    return exe;
}

fn generate_enums(b: *Build, opts: *const Opts, mods: *const ParserModules) *Build.Step.Compile {
    const tree_sitter = b.dependency("tree_sitter", .{
        .target = opts.target,
        .optimize = .ReleaseFast,
    });
    const exe = b.addExecutable(.{ .name = "generate_enums", .root_module = b.createModule(.{
        .root_source_file = b.path("src/generate_enums.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{.{
            .name = "tree-sitter",
            .module = tree_sitter.module("tree_sitter"),
        }},
    }) });
    mods.link(exe.root_module);
    return exe;
}
