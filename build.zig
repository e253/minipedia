const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rxml = b.dependency("rapidxml", .{});
    const lzma = buildLibLzma(b, target);
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });

    const stringzilla = b.addStaticLibrary(.{
        .name = "stringzilla",
        .root_source_file = b.path("src/stringzilla.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_model = .{
                .explicit = &.{
                    .name = "ivybridge+evex512",
                    .llvm_name = "ivybridge+evex512",
                    .features = std.Target.Cpu.Feature.Set.empty,
                },
            },
        }),
        .optimize = optimize,
        .link_libc = true,
    });
    stringzilla.addIncludePath(b.path("src"));
    switch (target.result.cpu.arch) {
        .x86, .x86_64 => stringzilla.addCSourceFile(.{ .file = b.path("src/stringzilla.c"), .flags = &.{
            "-DSZ_AVOID_LIBC=1",
            "-DSZ_USE_X86_AVX2=1",
            "-DSZ_USE_X86_AVX512=1",
            "-DSZ_USE_X86_NEON=0",
            "-DSZ_USE_X86_SVE=0",
        } }),
        .arm, .aarch64 => stringzilla.addCSourceFile(.{ .file = b.path("src/stringzilla.c"), .flags = &.{
            "-DSZ_USE_X86_AVX2=0",
            "-DSZ_USE_X86_AVX512=0",
            "-DSZ_USE_X86_NEON=1",
            "-DSZ_USE_X86_SVE=1",
        } }),
        else => @panic("Only X86/Arm supported for stringzilla"),
    }

    const exe = b.addExecutable(.{
        .name = "main",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.addCSourceFiles(.{ .root = b.path("src"), .files = &.{ "wikixmlparser.cpp", "duck_tracer.c" }, .flags = &.{"-DWXMLP_LOG"} });
    exe.addIncludePath(rxml.path(""));
    exe.addIncludePath(b.path("src"));
    exe.linkLibC();
    exe.linkLibCpp();
    exe.linkLibrary(lzma);
    exe.linkSystemLibrary("duckdb");
    b.installArtifact(exe);

    const get_article = b.addExecutable(.{
        .name = "get_article",
        .root_source_file = b.path("src/get_article.zig"),
        .target = target,
        .optimize = optimize,
    });
    get_article.linkLibC();
    get_article.linkLibrary(lzma);
    b.installArtifact(get_article);

    const browser = b.addExecutable(.{
        .name = "browser",
        .root_source_file = b.path("src/browser.zig"),
        .target = target,
        .optimize = optimize,
    });
    browser.root_module.addImport("httpz", httpz.module("httpz"));
    browser.linkLibC();
    browser.linkLibrary(lzma);
    linkMinisearch(b, browser, optimize);
    b.installArtifact(browser);

    const wikiparserxml_tests = b.addTest(.{
        .root_source_file = b.path("src/wikixmlparser.zig"),
        .target = target,
        .optimize = .Debug,
    });
    wikiparserxml_tests.addCSourceFile(.{ .file = b.path("src/wikixmlparser.cpp") });
    wikiparserxml_tests.addIncludePath(rxml.path(""));
    wikiparserxml_tests.addIncludePath(b.path("src"));
    wikiparserxml_tests.linkLibC();
    wikiparserxml_tests.linkLibCpp();
    const run_wikiparserxml_tests = b.addRunArtifact(wikiparserxml_tests);

    const slice_array_tests = b.addTest(.{
        .root_source_file = b.path("src/slice_array.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const run_slice_array_tests = b.addRunArtifact(slice_array_tests);

    const lzma_binding_tests = b.addTest(.{
        .root_source_file = b.path("src/lzma.zig"),
        .target = target,
        .optimize = .Debug,
    });
    lzma_binding_tests.linkLibC();
    lzma_binding_tests.linkLibrary(lzma);
    const run_lzma_binding_tests = b.addRunArtifact(lzma_binding_tests);

    const mwp_tests = b.addTest(.{
        .root_source_file = b.path("src/MediaWikiParser.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const run_mwp_tests = b.addRunArtifact(mwp_tests);

    const minisearch_tests = b.addTest(.{
        .root_source_file = b.path("src/minisearch.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkMinisearch(b, minisearch_tests, optimize);
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

pub fn linkMinisearch(b: *std.Build, step: *std.Build.Step.Compile, opt: std.builtin.OptimizeMode) void {
    step.addIncludePath(b.path("./search"));
    if (opt == .Debug) {
        step.addLibraryPath(b.path("./search/target/debug"));
    } else {
        step.addLibraryPath(b.path("./search/target/release"));
    }
    step.linkSystemLibrary("minisearch");
    step.linkSystemLibrary("unwind");
}

fn have_x86_feat(t: std.Target, feat: std.Target.x86.Feature) bool {
    return switch (t.cpu.arch) {
        .x86, .x86_64 => std.Target.x86.featureSetHas(t.cpu.features, feat),
        else => false,
    };
}

pub fn buildLibLzma(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const xz_tools = b.dependency("xz_tools", .{});

    const lzma = b.addStaticLibrary(.{
        .name = "lzma",
        .link_libc = true,
        .target = target,
        .optimize = .ReleaseFast,
    });
    lzma.addCSourceFiles(.{
        .root = xz_tools.path(""),
        .files = &xz_tools_sources,
        .flags = &.{"-DHAVE_CONFIG_H"},
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
            .HAVE_IMMINTRIN_H = 1,
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
            .HAVE_USABLE_CLMUL = 1,
            .HAVE_VISIBILITY = 0,
            .HAVE__BOOL = 1,
            .HAVE__MM_MOVEMASK_EPI8 = 1,
            .NDEBUG = 0,
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
