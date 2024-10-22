const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rxml = b.dependency("rapidxml", .{});
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
        .flags = &xz_tools_c_flags,
    });
    inline for (xz_tools_includes) |xz_include| {
        lzma.addIncludePath(xz_tools.path(xz_include));
    }
    b.installArtifact(lzma);

    const exe = b.addExecutable(.{
        .name = "main",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.addCSourceFile(.{ .file = b.path("src/wikixmlparser.cpp") });
    exe.addIncludePath(rxml.path(""));
    exe.addIncludePath(b.path("src"));
    exe.linkLibC();
    exe.linkLibCpp();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const wikiparserxml_tests = b.addTest(.{
        .root_source_file = b.path("src/wikixmlparser.zig"),
        .target = target,
        .optimize = optimize,
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
        .optimize = optimize,
    });
    const run_slice_array_tests = b.addRunArtifact(slice_array_tests);

    const test_step = b.step("test", "Run Unit Tests");
    test_step.dependOn(&run_wikiparserxml_tests.step);
    test_step.dependOn(&run_slice_array_tests.step);
}

const xz_tools_includes = [_][]const u8{
    ".",
    "lib",
    "tests",
    "src/xz",
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

const xz_tools_c_flags = [_][]const u8{
    "-DASSUME_RAM=128",
    "-DHAVE_CHECK_CRC32=1",
    "-DHAVE_CHECK_CRC64=1",
    "-DHAVE_CLOCK_GETTIME=1",
    "-DHAVE_CLOCK_MONOTONIC=1",
    "-DHAVE_CPUID_H=1",
    "-DHAVE_DCGETTEXT=1",
    "-DHAVE_DECODERS=1",
    "-DHAVE_DECODER_LZMA1=1",
    "-DHAVE_DECODER_LZMA2=1",
    "-DHAVE_DLFCN_H=1",
    "-DHAVE_ENCODERS=1",
    "-DHAVE_ENCODER_LZMA1=1",
    "-DHAVE_ENCODER_LZMA2=1",
    "-DHAVE_FUNC_ATTRIBUTE_CONSTRUCTOR=1",
    "-DHAVE_FUTIMENS=1",
    "-DHAVE_GETOPT_H=1",
    "-DHAVE_GETOPT_LONG=1",
    "-DHAVE_GETTEXT=1",
    "-DHAVE_IMMINTRIN_H=1",
    "-DHAVE_INTTYPES_H=1",
    "-DHAVE_LINUX_LANDLOCK=1",
    "-DHAVE_MBRTOWC=1",
    "-DHAVE_MF_BT2=1",
    "-DHAVE_MF_BT3=1",
    "-DHAVE_MF_BT4=1",
    "-DHAVE_MF_HC3=1",
    "-DHAVE_MF_HC4=1",
    "-DHAVE_POSIX_FADVISE=1",
    "-DHAVE_STDBOOL_H=1",
    "-DHAVE_STDINT_H=1",
    "-DHAVE_STDIO_H=1",
    "-DHAVE_STDLIB_H=1",
    "-DHAVE_STRINGS_H=1",
    "-DHAVE_STRING_H=1",
    "-DHAVE_STRUCT_STAT_ST_ATIM_TV_NSEC=1",
    "-DHAVE_SYS_CDEFS_H=1",
    "-DHAVE_SYS_PARAM_H=1",
    "-DHAVE_SYS_STAT_H=1",
    "-DHAVE_SYS_TYPES_H=1",
    "-DHAVE_UINTPTR_T=1",
    "-DHAVE_UNISTD_H=1",
    "-DHAVE_USABLE_CLMUL=1",
    "-DHAVE_VISIBILITY=1",
    "-DHAVE__BOOL=1",
    "-DHAVE__MM_MOVEMASK_EPI8=1",
    "-DNDEBUG=1",
    \\-DPACKAGE="\"xz\""
    ,
    \\-DPACKAGE_BUGREPORT="\"xz@tukaani.org\""
    ,
    \\-DPACKAGE_NAME="\"XZ Utils\""
    ,
    \\-DPACKAGE_STRING="\"XZ Utils 5.7.0.alpha\""
    ,
    \\-DPACKAGE_TARNAME="\"xz\""
    ,
    \\-DPACKAGE_URL="\"https://tukaani.org/xz/\""
    ,
    \\-DPACKAGE_VERSION="\"5.7.0.alpha\""
    ,
    "-DSIZEOF_SIZE_T=8",
    "-DSTDC_HEADERS=1",
    "-DTUKLIB_FAST_UNALIGNED_ACCESS=1",
    "-DTUKLIB_PHYSMEM_SYSCONF=1",
    \\-DVERSION="\"5.7.0.alpha\""
    ,
};

const xz_tools_sources = [_][]const u8{
    "src/liblzma/lz/lz_encoder_mf.c",
    "src/liblzma/lz/lz_encoder.c",
    "src/liblzma/lz/lz_decoder.c",
    "src/liblzma/simple/simple_encoder.c",
    "src/liblzma/simple/simple_coder.c",
    "src/liblzma/simple/simple_decoder.c",
    "src/liblzma/rangecoder/price_table.c",
    "src/liblzma/check/crc64_fast.c",
    "src/liblzma/check/crc32_fast.c",
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
