const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tsdb_mod = b.createModule(.{
        .root_source_file = b.path("src/tsdb.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compaction_mod = b.createModule(.{
        .root_source_file = b.path("src/compaction.zig"),
        .target = target,
        .optimize = optimize,
    });
    compaction_mod.addImport("tsdb", tsdb_mod);

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("tsdb", tsdb_mod);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tsdb", .module = tsdb_mod },
            .{ .name = "compaction", .module = compaction_mod },
            .{ .name = "server", .module = server_mod },
        },
    });

    // 主可执行文件 tsdb
    const exe = b.addExecutable(.{
        .name = "tsdb",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    // 运行命令
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the tsdb CLI");
    run_step.dependOn(&run_cmd.step);

    // 单元测试
    const test_step = b.step("test", "Run unit tests");

    const tsdb_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tsdb.zig"),
        .target = target,
        .optimize = optimize,
    });
    const t_tsdb = b.addTest(.{ .root_module = tsdb_test_mod });
    test_step.dependOn(&b.addRunArtifact(t_tsdb).step);

    const compaction_test_mod = b.createModule(.{
        .root_source_file = b.path("src/compaction.zig"),
        .target = target,
        .optimize = optimize,
    });
    compaction_test_mod.addImport("tsdb", tsdb_mod);
    const t_compaction = b.addTest(.{ .root_module = compaction_test_mod });
    test_step.dependOn(&b.addRunArtifact(t_compaction).step);

    const server_test_mod = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_test_mod.addImport("tsdb", tsdb_mod);
    const t_server = b.addTest(.{ .root_module = server_test_mod });
    test_step.dependOn(&b.addRunArtifact(t_server).step);

    const arrow_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi/arrow.zig"),
        .target = target,
        .optimize = optimize,
    });
    const t_arrow = b.addTest(.{ .root_module = arrow_test_mod });
    test_step.dependOn(&b.addRunArtifact(t_arrow).step);

    const optimizer_test_mod = b.createModule(.{
        .root_source_file = b.path("src/fdap/optimizer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const t_optimizer = b.addTest(.{ .root_module = optimizer_test_mod });
    test_step.dependOn(&b.addRunArtifact(t_optimizer).step);

    // 集成测试
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addImport("tsdb", tsdb_mod);
    integration_mod.addImport("compaction", compaction_mod);

    const integration_test = b.addTest(.{
        .root_module = integration_mod,
    });
    const run_integration = b.addRunArtifact(integration_test);
    test_step.dependOn(&run_integration.step);

    // 基准测试
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tests/benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("tsdb", tsdb_mod);

    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}
