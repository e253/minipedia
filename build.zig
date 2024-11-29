const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target, const rust_target = targetOptions(b);
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies.
    const rxml = b.dependency("rapidxml", .{});
    const lzma = buildLibLzma(b, target);
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });
    const build_minisearch = b.addSystemCommand(&.{ "cargo", "zigbuild", "--target", rust_target });
    if (optimize != .Debug) {
        build_minisearch.addArg("--release");
    }
    build_minisearch.setCwd(b.path("search"));

    // Archiver.
    const archiver = b.option(bool, "archiver", "Set this option to build the archiver") orelse false;
    if (archiver) {
        const exe = b.addExecutable(.{
            .name = "minipedia-archiver",
            .root_source_file = b.path("src/archiver.zig"),
            .target = b.host,
            .optimize = optimize,
        });
        exe.addCSourceFiles(.{
            .root = b.path("src/lib"),
            .files = &.{ "wiki_xml_parser/wikixmlparser.cpp", "tracing/duck_tracer.c" },
            .flags = &.{"-DWXMLP_LOG"},
        });
        exe.addIncludePath(rxml.path(""));
        exe.addIncludePath(b.path("src/lib/wiki_xml_parser/"));
        exe.addIncludePath(b.path("src/lib/tracing/"));
        exe.linkLibC();
        exe.linkLibCpp();
        exe.linkLibrary(buildLibLzma(b, b.host));
        exe.linkSystemLibrary("duckdb");
        b.installArtifact(exe);
    }

    // Dump article by id.
    {
        const get_article = b.addExecutable(.{
            .name = "get_article",
            .root_source_file = b.path("src/get_article.zig"),
            .target = target,
            .optimize = optimize,
        });
        get_article.linkLibC();
        get_article.linkLibrary(lzma);
        b.installArtifact(get_article);
    }

    // Browser.
    {
        // Frontend.
        const frontend_bundler = b.addExecutable(.{
            .name = "bundle_frontend",
            .root_source_file = b.path("tools/bundle_frontend.zig"),
            .target = b.host,
        });
        const bundle_frontend_step = b.addRunArtifact(frontend_bundler);
        bundle_frontend_step.addFileInput(b.path("frontend/build/index.html")); // TODO: add all other files in dir as inputs
        const frontend_zig = bundle_frontend_step.addOutputFileArg("frontend.zig");

        const frontend_files = b.addWriteFiles();
        _ = frontend_files.addCopyDirectory(b.path("frontend/build"), "frontend-files", .{});
        const copied_frontend_zig = frontend_files.addCopyFile(frontend_zig, "frontend.zig");

        // Browser executable.
        const browser = b.addExecutable(.{
            .name = "browser",
            .root_source_file = b.path("src/browser.zig"),
            .target = target,
            .optimize = optimize,
        });
        browser.root_module.addImport("httpz", httpz.module("httpz"));
        browser.root_module.addAnonymousImport("frontend", .{ .root_source_file = copied_frontend_zig });
        browser.linkLibC();
        browser.linkLibrary(lzma);
        linkMinisearch(b, browser, &build_minisearch.step, rust_target, optimize);

        const browser_install = b.addInstallArtifact(browser, .{});
        b.getInstallStep().dependOn(&browser_install.step);
        browser_install.step.dependOn(&bundle_frontend_step.step);
    }

    // Tests.
    {
        const wikiparserxml_tests = b.addTest(.{
            .root_source_file = b.path("src/lib/wiki_xml_parser.zig"),
            .target = target,
            .optimize = .Debug,
        });
        wikiparserxml_tests.addCSourceFile(.{ .file = b.path("src/lib/wiki_xml_parser/wikixmlparser.cpp") });
        wikiparserxml_tests.addIncludePath(rxml.path(""));
        wikiparserxml_tests.addIncludePath(b.path("src/lib/wiki_xml_parser/"));
        wikiparserxml_tests.linkLibC();
        wikiparserxml_tests.linkLibCpp();
        const run_wikiparserxml_tests = b.addRunArtifact(wikiparserxml_tests);

        const slice_array_tests = b.addTest(.{
            .root_source_file = b.path("src/lib/slice_array.zig"),
            .target = target,
            .optimize = .Debug,
        });
        const run_slice_array_tests = b.addRunArtifact(slice_array_tests);

        const lzma_binding_tests = b.addTest(.{
            .root_source_file = b.path("src/lib/lzma.zig"),
            .target = target,
            .optimize = .Debug,
        });
        lzma_binding_tests.linkLibC();
        lzma_binding_tests.linkLibrary(lzma);
        const run_lzma_binding_tests = b.addRunArtifact(lzma_binding_tests);

        const mwp_tests = b.addTest(.{
            .root_source_file = b.path("src/lib/MediaWikiParser.zig"),
            .target = target,
            .optimize = .Debug,
        });
        const run_mwp_tests = b.addRunArtifact(mwp_tests);

        const minisearch_tests = b.addTest(.{
            .root_source_file = b.path("src/lib/minisearch.zig"),
            .target = target,
            .optimize = optimize,
        });
        linkMinisearch(b, minisearch_tests, &build_minisearch.step, rust_target, optimize);
        minisearch_tests.linkLibC();
        const run_minisearch_tests = b.addRunArtifact(minisearch_tests);

        const test_step = b.step("test", "Run All Unit Tests");
        test_step.dependOn(&run_wikiparserxml_tests.step);
        test_step.dependOn(&run_slice_array_tests.step);
        test_step.dependOn(&run_lzma_binding_tests.step);
        test_step.dependOn(&run_mwp_tests.step);
        test_step.dependOn(&run_minisearch_tests.step);

        const test_mwp_step = b.step("test-mwp", "Run MediaWikiParser Test Suite");
        test_mwp_step.dependOn(&run_mwp_tests.step);
    }
}

fn targetOptions(b: *std.Build) struct { std.Build.ResolvedTarget, []const u8 } {
    const MinisearchTarget = enum {
        Amd64Linux,
        Amd64Windows,
        Arm64Macos,
        Amd64Macos,
    };
    const target_option = b.option(MinisearchTarget, "target", "Select a supported target");
    if (target_option) |requested_target| {
        switch (requested_target) {
            .Amd64Linux => return .{
                b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }),
                "x86_64-unknown-linux-musl",
            },
            .Amd64Windows => {
                std.io.getStdErr().writeAll("Error [Fatal]: Amd64Windows is broken. Compiler-rt bug that's fixed after 0.13.0.\n") catch unreachable;
                std.process.exit(0);
                //return .{
                //    b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
                //    "x86_64-pc-windows-gnu",
                //};
            },
            .Arm64Macos => return .{
                b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none }),
                "aarch64-apple-darwin",
            },
            .Amd64Macos => return .{
                b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos, .abi = .none }),
                "x86_64-apple-darwin",
            },
        }
    } else {
        const default = b.host.result;
        switch (default.os.tag) {
            .linux => {
                if (default.cpu.arch == .x86_64) {
                    return .{
                        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }),
                        "x86_64-unknown-linux-musl",
                    };
                }
            },
            .windows => {
                std.io.getStdErr().writeAll("Error [Fatal]: Amd64Windows is broken. Compiler-rt bug that's fixed after 0.13.0.\n") catch unreachable;
                std.process.exit(0);
                //if (default.cpu.arch == .x86_64) {
                //    break :blk .{
                //        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
                //        "x86_64-pc-windows-gnu",
                //    };
                //}
            },
            .macos => {
                if (default.cpu.arch == .aarch64) {
                    return .{
                        b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none }),
                        "aarch64-apple-darwin",
                    };
                }
                if (default.cpu.arch == .x86_64) {
                    return .{
                        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos, .abi = .none }),
                        "x86_64-apple-darwin",
                    };
                }
            },
            else => {},
        }
        std.io.getStdErr().writeAll(
            \\No target provided and none could be selected automatically from default options.
            \\Please select a target.
            \\
            \\  zig build -Dtarget=Amd64Linux
            \\
            \\  Options: Amd64Linux, Amd64Windows, Arm64Macos
            \\
            \\
        ) catch unreachable;
        std.process.exit(1);
    }
}

pub fn linkMinisearch(b: *std.Build, artifact: *std.Build.Step.Compile, build_minisearch_step: *std.Build.Step, rust_target: []const u8, opt: std.builtin.OptimizeMode) void {
    if (opt == .Debug) {
        artifact.addLibraryPath(b.path(b.fmt("./search/target/{s}/debug", .{rust_target})));
    } else {
        artifact.addLibraryPath(b.path(b.fmt("./search/target/{s}/release", .{rust_target})));
    }
    artifact.linkSystemLibrary("minisearch");
    artifact.linkSystemLibrary("unwind");
    artifact.step.dependOn(build_minisearch_step);
}

pub fn buildLibLzma(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const xz_tools = b.dependency("xz_tools", .{});

    const lzma = b.addStaticLibrary(.{
        .name = "lzma",
        .target = target,
        .optimize = .ReleaseFast,
    });
    lzma.linkLibC();
    lzma.addCSourceFiles(.{
        .root = xz_tools.path(""),
        .files = &xz_tools_sources,
        .flags = &.{ "-DHAVE_CONFIG_H", "-DLZMA_API_STATIC" },
    });
    for (xz_tools_includes) |xz_include| {
        lzma.addIncludePath(xz_tools.path(xz_include));
    }
    const config_h = b.addConfigHeader(
        .{ .style = .blank, .include_path = "config.h" },
        .{
            .ASSUME_RAM = 128,
            .HAVE_CHECK_CRC32 = 1,
            .HAVE_CHECK_CRC64 = 1,
            .HAVE_CLOCK_GETTIME = 1,
            .HAVE_CLOCK_MONOTONIC = 1,
            .HAVE_CPUID_H = 1,
            .HAVE_DCGETTEXT = 1,
            .HAVE_DECODERS = 1,
            .HAVE_DECODER_LZMA1 = 1,
            .HAVE_DECODER_LZMA2 = 1,
            .HAVE_DLFCN_H = 1,
            .HAVE_ENCODERS = 1,
            .HAVE_ENCODER_LZMA1 = 1,
            .HAVE_ENCODER_LZMA2 = 1,
            .HAVE_FUNC_ATTRIBUTE_CONSTRUCTOR = 1,
            .HAVE_FUTIMENS = 1,
            .HAVE_GETOPT_H = 1,
            .HAVE_GETOPT_LONG = 1,
            .HAVE_GETTEXT = 1,
            .HAVE_INTTYPES_H = 1,
            .HAVE_LINUX_LANDLOCK = 1,
            .HAVE_MBRTOWC = 1,
            .HAVE_MF_BT2 = 1,
            .HAVE_MF_BT3 = 1,
            .HAVE_MF_BT4 = 1,
            .HAVE_MF_HC3 = 1,
            .HAVE_MF_HC4 = 1,
            .HAVE_POSIX_FADVISE = 1,
            .HAVE_STDBOOL_H = 1,
            .HAVE_STDINT_H = 1,
            .HAVE_STDIO_H = 1,
            .HAVE_STDLIB_H = 1,
            .HAVE_STRINGS_H = 1,
            .HAVE_STRING_H = 1,
            .HAVE_STRUCT_STAT_ST_ATIM_TV_NSEC = 1,
            .HAVE_SYS_CDEFS_H = 1,
            .HAVE_SYS_PARAM_H = 1,
            .HAVE_SYS_STAT_H = 1,
            .HAVE_SYS_TYPES_H = 1,
            .HAVE_UINTPTR_T = 1,
            .HAVE_UNISTD_H = 1,
            .HAVE__BOOL = 1,
            .PACKAGE = "xz",
            .PACKAGE_BUGREPORT = "xz@tukaani.org",
            .PACKAGE_NAME = "XZ Utils",
            .PACKAGE_STRING = "XZ Utils 5.6.3",
            .PACKAGE_TARNAME = "xz",
            .PACKAGE_URL = "https://tukaani.org/xz/",
            .PACKAGE_VERSION = "5.6.3",
            .SIZEOF_SIZE_T = 8,
            .STDC_HEADERS = 1,
            .TUKLIB_FAST_UNALIGNED_ACCESS = 1,
            .TUKLIB_PHYSMEM_SYSCONF = 1,
            .VERSION = "5.6.3",
        },
    );
    if (target.result.cpu.arch == .x86_64) {
        config_h.addValues(.{
            .HAVE_IMMINTRIN_H = 1,
            .HAVE_USABLE_CLMUL = 1,
            .HAVE__MM_MOVEMASK_EPI8 = 1,
        });
    }

    lzma.addConfigHeader(config_h);
    lzma.installHeadersDirectory(xz_tools.path("src/liblzma/api"), "", .{});
    b.installArtifact(lzma);

    return lzma;
}

const xz_tools_includes = [_][]const u8{
    ".",
    "lib",
    "tests",
    "src/common",
    "src/liblzma/lz",
    "src/liblzma/lzma",
    "src/liblzma/simple",
    "src/liblzma/common",
    "src/liblzma/check",
    "src/liblzma/rangecoder",
    "src/liblzma/api",
    "src/liblzma/delta",
};

const xz_tools_sources = [_][]const u8{
    "src/liblzma/lz/lz_encoder_mf.c",
    "src/liblzma/lz/lz_encoder.c",
    "src/liblzma/lz/lz_decoder.c",
    "src/liblzma/simple/armthumb.c",
    "src/liblzma/simple/arm.c",
    "src/liblzma/simple/x86.c",
    "src/liblzma/simple/simple_encoder.c",
    "src/liblzma/simple/arm64.c",
    "src/liblzma/simple/riscv.c",
    "src/liblzma/simple/simple_coder.c",
    "src/liblzma/simple/powerpc.c",
    "src/liblzma/simple/sparc.c",
    "src/liblzma/simple/ia64.c",
    "src/liblzma/simple/simple_decoder.c",
    "src/liblzma/rangecoder/price_table.c",
    "src/liblzma/check/crc64_fast.c",
    "src/liblzma/check/crc32_fast.c",
    "src/liblzma/check/crc32_table.c",
    "src/liblzma/check/crc64_table.c",
    "src/liblzma/check/sha256.c",

    // can't be included with crc*_fast.c
    //"src/liblzma/check/crc64_small.c",
    //"src/liblzma/check/crc32_small.c",

    "src/liblzma/check/check.c",
    "src/liblzma/delta/delta_encoder.c",
    "src/liblzma/delta/delta_decoder.c",
    "src/liblzma/delta/delta_common.c",
    "src/liblzma/lzma/lzma_encoder_presets.c",
    "src/liblzma/lzma/lzma_decoder.c",
    "src/liblzma/lzma/lzma_encoder_optimum_normal.c",
    "src/liblzma/lzma/lzma2_encoder.c",
    "src/liblzma/lzma/fastpos_table.c",
    "src/liblzma/lzma/lzma_encoder.c",
    "src/liblzma/lzma/lzma_encoder_optimum_fast.c",
    "src/liblzma/lzma/lzma2_decoder.c",
    "src/liblzma/common/block_header_encoder.c",
    "src/liblzma/common/filter_buffer_decoder.c",
    "src/liblzma/common/stream_decoder.c",
    "src/liblzma/common/index_hash.c",
    "src/liblzma/common/block_buffer_encoder.c",
    "src/liblzma/common/filter_decoder.c",
    "src/liblzma/common/stream_encoder.c",
    "src/liblzma/common/stream_flags_common.c",
    "src/liblzma/common/stream_flags_encoder.c",
    "src/liblzma/common/auto_decoder.c",
    "src/liblzma/common/filter_common.c",
    "src/liblzma/common/outqueue.c",

    // multithreading is currently disabled
    //"src/liblzma/common/stream_decoder_mt.c",
    //"src/liblzma/common/stream_encoder_mt.c",

    "src/liblzma/common/block_util.c",
    "src/liblzma/common/alone_encoder.c",
    "src/liblzma/common/easy_buffer_encoder.c",
    "src/liblzma/common/block_buffer_decoder.c",
    "src/liblzma/common/stream_flags_decoder.c",
    "src/liblzma/common/common.c",
    "src/liblzma/common/index_decoder.c",
    "src/liblzma/common/easy_encoder.c",
    "src/liblzma/common/filter_flags_encoder.c",
    "src/liblzma/common/string_conversion.c",
    "src/liblzma/common/index.c",
    "src/liblzma/common/file_info.c",
    "src/liblzma/common/filter_encoder.c",
    "src/liblzma/common/stream_buffer_decoder.c",
    "src/liblzma/common/vli_size.c",
    "src/liblzma/common/stream_buffer_encoder.c",
    "src/liblzma/common/easy_preset.c",
    "src/liblzma/common/vli_encoder.c",
    "src/liblzma/common/microlzma_encoder.c",
    "src/liblzma/common/index_encoder.c",
    "src/liblzma/common/block_encoder.c",
    "src/liblzma/common/filter_buffer_encoder.c",
    "src/liblzma/common/filter_flags_decoder.c",
    "src/liblzma/common/block_header_decoder.c",
    "src/liblzma/common/easy_encoder_memusage.c",
    "src/liblzma/common/lzip_decoder.c",
    "src/liblzma/common/vli_decoder.c",
    "src/liblzma/common/alone_decoder.c",
    "src/liblzma/common/block_decoder.c",
    "src/liblzma/common/hardware_cputhreads.c",
    "src/liblzma/common/microlzma_decoder.c",
    "src/liblzma/common/hardware_physmem.c",
    "src/liblzma/common/easy_decoder_memusage.c",
    "src/common/tuklib_mbstr_fw.c",
    "src/common/tuklib_exit.c",
    "src/common/tuklib_cpucores.c",
    "src/common/tuklib_open_stdxxx.c",
    "src/common/tuklib_progname.c",
    "src/common/tuklib_physmem.c",
    "src/common/tuklib_mbstr_width.c",
};
