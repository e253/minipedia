const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rxml = b.dependency("rapidxml", .{});

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
