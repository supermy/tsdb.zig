const std = @import("std");
const tsdb = @import("tsdb");
const compaction = @import("compaction");

// 集成测试：验证完整的写入、查询、刷盘、加载、合并链路

test "integration: write -> flush -> load -> query" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_integration_wflq";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    const key = tsdb.SeriesKey{
        .metric = "cpu_usage",
        .tags = &[_]tsdb.Tag{
            .{ .key = "host", .value = "server01" },
            .{ .key = "dc", .value = "us-east" },
        },
    };
    const sid = key.computeId();

    // 写入若干点
    try engine.write(key, .{ .timestamp = 1000, .value = 10.5 });
    try engine.write(key, .{ .timestamp = 2000, .value = 20.5 });
    try engine.write(key, .{ .timestamp = 3000, .value = 30.5 });

    // 刷盘
    try engine.flushHotPartition();

    // 新引擎加载
    var engine2 = try tsdb.Engine.init(allocator, "tmp_integration_wflq2");
    defer {
        engine2.deinit();
        tsdb.fs_helper.deleteTree("tmp_integration_wflq2") catch {};
    }

    try engine2.loadPartition(engine.disk_partitions.items[0].file_path);

    // 查询验证
    const points = try engine2.queryRange(sid, 1500, 2500, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 1), points.len);
    try std.testing.expectEqual(@as(f64, 20.5), points[0].value);
}

test "integration: high cardinality write and query" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_integration_high_card";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    const num_series = 100;
    const points_per_series = 50;

    var sids = std.ArrayList(u64).empty;
    defer sids.deinit(allocator);

    var i: u32 = 0;
    while (i < num_series) : (i += 1) {
        var buf: [32]u8 = undefined;
        const host = try std.fmt.bufPrint(&buf, "host{d}", .{i});
        const key = tsdb.SeriesKey{
            .metric = "cpu",
            .tags = &[_]tsdb.Tag{.{ .key = "host", .value = host }},
        };
        try sids.append(allocator, key.computeId());

        var j: u32 = 0;
        while (j < points_per_series) : (j += 1) {
            try engine.write(key, .{
                .timestamp = @as(i64, j) * 1000,
                .value = @floatFromInt(j),
            });
        }
    }

    // 验证每个序列可查询
    for (sids.items) |sid| {
        const points = try engine.queryRange(sid, 0, 1_000_000, allocator);
        defer allocator.free(points);
        try std.testing.expectEqual(@as(usize, points_per_series), points.len);
    }

    // 验证聚合平均值
    const avg = try engine.queryAvg(sids.items[0], 0, 1_000_000);
    try std.testing.expect(avg != null);
    // 0..49 的平均值 = 24.5
    try std.testing.expectApproxEqAbs(@as(f64, 24.5), avg.?, 0.001);
}

test "integration: compaction roundtrip" {
    const allocator = std.testing.allocator;

    var part_a = tsdb.MemoryPartition.init(allocator, 0, 1000);
    defer part_a.deinit();
    var part_b = tsdb.MemoryPartition.init(allocator, 500, 1500);
    defer part_b.deinit();

    const key = tsdb.SeriesKey{
        .metric = "mem",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };

    try part_a.insert(key.computeId(), key, 100, 1.0, 1024);
    try part_a.insert(key.computeId(), key, 200, 2.0, 1024);
    try part_b.insert(key.computeId(), key, 200, 2.5, 1024); // 重复
    try part_b.insert(key.computeId(), key, 300, 3.0, 1024);
    try part_b.insert(key.computeId(), key, 400, 4.0, 1024);

    var compactor = compaction.Compactor.init(allocator);
    var merged = try compactor.mergePartitions(&part_a, &part_b);
    defer merged.deinit();

    // 验证合并结果已排序且去重
    const sd = merged.series_map.get(key.computeId()).?;
    try std.testing.expectEqual(@as(usize, 4), sd.len());
    try std.testing.expectEqual(@as(i64, 100), sd.timestamps.items[0]);
    try std.testing.expectEqual(@as(i64, 200), sd.timestamps.items[1]);
    try std.testing.expectEqual(@as(f64, 2.5), sd.values.items[1]);
    try std.testing.expectEqual(@as(i64, 300), sd.timestamps.items[2]);
    try std.testing.expectEqual(@as(i64, 400), sd.timestamps.items[3]);

    // 验证写入磁盘后可读回
    const file_path = "tmp_compaction_roundtrip.tsdb";
    defer tsdb.fs_helper.deleteTree(file_path) catch {};
    try compactor.writePartitionToDisk(&merged, file_path);

    var engine = try tsdb.Engine.init(allocator, "tmp_compaction_engine");
    defer {
        engine.deinit();
        tsdb.fs_helper.deleteTree("tmp_compaction_engine") catch {};
    }
    try engine.loadPartition(file_path);

    const points = try engine.queryRange(key.computeId(), 0, 500, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 4), points.len);
}
