const std = @import("std");
const tsdb = @import("tsdb");
const compaction = @import("compaction");

// ==================== 集成测试 ====================
// 验证完整的数据链路：写入→查询→落盘→磁盘查询→合并

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

    try engine.write(key, .{ .timestamp = 1000, .value = 10.5 });
    try engine.write(key, .{ .timestamp = 2000, .value = 20.5 });
    try engine.write(key, .{ .timestamp = 3000, .value = 30.5 });

    try engine.flushHotPartition();

    var engine2 = try tsdb.Engine.init(allocator, "tmp_integration_wflq2");
    defer {
        engine2.deinit();
        tsdb.fs_helper.deleteTree("tmp_integration_wflq2") catch {};
    }

    try engine2.loadPartition(engine.disk_partitions.items[0].file_path);

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

    for (sids.items) |sid| {
        const points = try engine.queryRange(sid, 0, 1_000_000, allocator);
        defer allocator.free(points);
        try std.testing.expectEqual(@as(usize, points_per_series), points.len);
    }

    const avg = try engine.queryAvg(sids.items[0], 0, 1_000_000);
    try std.testing.expect(avg != null);
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
    try part_b.insert(key.computeId(), key, 200, 2.5, 1024);
    try part_b.insert(key.computeId(), key, 300, 3.0, 1024);
    try part_b.insert(key.computeId(), key, 400, 4.0, 1024);

    var compactor = compaction.Compactor.init(allocator);
    var merged = try compactor.mergePartitions(&part_a, &part_b);
    defer merged.deinit();

    const sd = merged.series_map.get(key.computeId()).?;
    try std.testing.expectEqual(@as(usize, 4), sd.len());
    try std.testing.expectEqual(@as(i64, 100), sd.timestamps.items[0]);
    try std.testing.expectEqual(@as(i64, 200), sd.timestamps.items[1]);
    try std.testing.expectEqual(@as(f64, 2.5), sd.values.items[1]);
    try std.testing.expectEqual(@as(i64, 300), sd.timestamps.items[2]);
    try std.testing.expectEqual(@as(i64, 400), sd.timestamps.items[3]);

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

test "integration: line protocol -> write -> query end-to-end" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_integration_e2e";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    // 解析 line protocol 并写入
    const line = "cpu,host=server01,region=us-west usage=75.5 1609459200000000000";
    const parsed = try engine.parseLineProtocol(line);
    try std.testing.expect(parsed != null);
    if (parsed) |p| {
        defer {
            allocator.free(p.key.metric);
            for (p.key.tags) |tag| {
                allocator.free(tag.key);
                allocator.free(tag.value);
            }
            allocator.free(p.key.tags);
        }
        const sid = p.key.computeId();
        try engine.write(p.key, p.point);

        // 查询验证
        const points = try engine.queryRange(sid, 0, 9999999999999, allocator);
        defer allocator.free(points);
        try std.testing.expectEqual(@as(usize, 1), points.len);
        try std.testing.expectEqual(@as(f64, 75.5), points[0].value);
        try std.testing.expectEqual(@as(i64, 1609459200000), points[0].timestamp);
    }
}

test "integration: auto-flush triggers and data survives on disk" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_integration_auto_flush";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.max_partition_points = 10;
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    // 写入 15 条，超过阈值 10，应自动落盘
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        try engine.write(key, .{ .timestamp = @intCast(i * 100), .value = @floatFromInt(i) });
    }

    // 验证磁盘分区已创建
    try std.testing.expect(engine.disk_partitions.items.len > 0);

    // 查询应返回全部 15 条（磁盘 + 热分区）
    const points = try engine.queryRange(sid, 0, 3600_000, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 15), points.len);
}

test "integration: queryByMetric across hot + disk partitions" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_integration_metric_cross";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.max_partition_points = 5;
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key1 = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };
    const key2 = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "B" }},
    };
    const key3 = tsdb.SeriesKey{
        .metric = "mem",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };

    // 写入足够数据触发自动落盘
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try engine.write(key1, .{ .timestamp = @intCast(i * 100), .value = @floatFromInt(i) });
        try engine.write(key2, .{ .timestamp = @intCast(i * 100 + 50), .value = @floatFromInt(i * 2) });
    }
    try engine.write(key3, .{ .timestamp = 100, .value = 99.0 });

    // 按 cpu 查询应包含 key1 和 key2 的所有数据
    const cpu_points = try engine.queryByMetric("cpu", 0, 3600_000, allocator);
    defer allocator.free(cpu_points);
    try std.testing.expect(cpu_points.len >= 16); // 8*2 = 16

    // 按 mem 查询
    const mem_points = try engine.queryByMetric("mem", 0, 3600_000, allocator);
    defer allocator.free(mem_points);
    try std.testing.expectEqual(@as(usize, 1), mem_points.len);
}

test "integration: flush then new writes go to new hot partition" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_integration_flush_new";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };

    try engine.write(key, .{ .timestamp = 100, .value = 1.0 });
    try engine.flushHotPartition();

    // 热分区应已重置
    try std.testing.expectEqual(@as(usize, 0), engine.hot_partition.series_map.count());
    try std.testing.expectEqual(@as(usize, 1), engine.disk_partitions.items.len);

    // 新写入应进入新的热分区
    try engine.write(key, .{ .timestamp = 200, .value = 2.0 });
    try std.testing.expectEqual(@as(usize, 1), engine.hot_partition.series_map.count());

    // 查询应返回两条（磁盘 + 热分区）
    const sid = key.computeId();
    const points = try engine.queryRange(sid, 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 2), points.len);
}

test "integration: writeBatch end-to-end" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_integration_batch";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    const points = [_]tsdb.DataPoint{
        .{ .timestamp = 100, .value = 1.0 },
        .{ .timestamp = 200, .value = 2.0 },
        .{ .timestamp = 300, .value = 3.0 },
    };

    try engine.writeBatch(key, &points);

    const result = try engine.queryRange(sid, 0, 9999999999999, allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(f64, 1.0), result[0].value);
    try std.testing.expectEqual(@as(f64, 2.0), result[1].value);
    try std.testing.expectEqual(@as(f64, 3.0), result[2].value);
}

test "integration: compaction with engine flush and reload" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_integration_compact";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };

    // 写入并 flush 两次，产生两个磁盘分区
    try engine.write(key, .{ .timestamp = 100, .value = 1.0 });
    try engine.write(key, .{ .timestamp = 200, .value = 2.0 });
    try engine.flushHotPartition();

    try engine.write(key, .{ .timestamp = 200, .value = 2.5 }); // 重复时间戳
    try engine.write(key, .{ .timestamp = 300, .value = 3.0 });
    try engine.flushHotPartition();

    try std.testing.expectEqual(@as(usize, 2), engine.disk_partitions.items.len);

    // 加载两个分区到内存并合并
    try engine.loadPartition(engine.disk_partitions.items[0].file_path);
    try engine.loadPartition(engine.disk_partitions.items[1].file_path);

    try std.testing.expectEqual(@as(usize, 2), engine.readonly_partitions.items.len);

    var compactor = compaction.Compactor.init(allocator);
    var merged = try compactor.mergePartitions(
        engine.readonly_partitions.items[0],
        engine.readonly_partitions.items[1],
    );
    defer merged.deinit();

    // 验证去重：ts=200 只保留一个
    const sd = merged.series_map.get(key.computeId()).?;
    try std.testing.expectEqual(@as(usize, 3), sd.len());
    try std.testing.expectEqual(@as(f64, 2.5), sd.values.items[1]); // 保留最新值
}

// ==================== 冒烟测试 ====================
// 验证核心功能的基本可用性（快速、关键路径）

test "smoke: engine init and deinit" {
    std.debug.print("\n[SMOKE] Running: {s}\n", .{"smoke: engine init and deinit"});
    const allocator = std.testing.allocator;
    const data_dir = "tmp_smoke_init";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};
    var engine = try tsdb.Engine.init(allocator, data_dir);
    engine.deinit();
    std.debug.print("[SMOKE] PASSED: {s}\n", .{"smoke: engine init and deinit"});
}

test "smoke: single write and query" {
    std.debug.print("\n[SMOKE] Running: {s}\n", .{"smoke: single write and query"});
    const allocator = std.testing.allocator;
    const data_dir = "tmp_smoke_write_query";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };

    try engine.write(key, .{ .timestamp = 1000, .value = 42.0 });

    const points = try engine.queryRange(key.computeId(), 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 1), points.len);
    try std.testing.expectEqual(@as(f64, 42.0), points[0].value);
    std.debug.print("[SMOKE] PASSED: {s}\n", .{"smoke: single write and query"});
}

test "smoke: parse line protocol and write" {
    std.debug.print("\n[SMOKE] Running: {s}\n", .{"smoke: parse line protocol and write"});
    const allocator = std.testing.allocator;
    const data_dir = "tmp_smoke_lp";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    const result = try engine.parseLineProtocol("cpu,host=A usage=90i 1609459200000000000");
    try std.testing.expect(result != null);
    if (result) |p| {
        defer {
            allocator.free(p.key.metric);
            for (p.key.tags) |tag| {
                allocator.free(tag.key);
                allocator.free(tag.value);
            }
            allocator.free(p.key.tags);
        }
        try std.testing.expectEqualStrings("cpu", p.key.metric);
        try std.testing.expectEqual(@as(f64, 90.0), p.point.value);
    }
    std.debug.print("[SMOKE] PASSED: {s}\n", .{"smoke: parse line protocol and write"});
}

test "smoke: flush creates disk file" {
    std.debug.print("\n[SMOKE] Running: {s}\n", .{"smoke: flush creates disk file"});
    const allocator = std.testing.allocator;
    const data_dir = "tmp_smoke_flush";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };

    try engine.write(key, .{ .timestamp = 100, .value = 1.0 });
    try engine.flushHotPartition();

    try std.testing.expectEqual(@as(usize, 1), engine.disk_partitions.items.len);
    std.debug.print("[SMOKE] PASSED: {s}\n", .{"smoke: flush creates disk file"});
}

test "smoke: queryByMetric returns correct data" {
    std.debug.print("\n[SMOKE] Running: {s}\n", .{"smoke: queryByMetric returns correct data"});
    const allocator = std.testing.allocator;
    const data_dir = "tmp_smoke_metric";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };

    try engine.write(key, .{ .timestamp = 100, .value = 1.0 });

    const points = try engine.queryByMetric("cpu", 0, 3600_000, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 1), points.len);
    std.debug.print("[SMOKE] PASSED: {s}\n", .{"smoke: queryByMetric returns correct data"});
}

test "smoke: file I/O roundtrip" {
    std.debug.print("\n[SMOKE] Running: {s}\n", .{"smoke: file I/O roundtrip"});
    const allocator = std.testing.allocator;
    const path = "tmp_smoke_file.bin";
    defer tsdb.fs_helper.remove(path) catch {};

    try tsdb.fs_helper.writeFile(path, "smoke test data");
    const data = try tsdb.fs_helper.readFile(path, allocator);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("smoke test data", data);
    std.debug.print("[SMOKE] PASSED: {s}\n", .{"smoke: file I/O roundtrip"});
}

// ==================== 回归测试 ====================
// 验证已修复的 bug 不会再次出现

test "regression: series_id precision loss (u64 as string in JSON)" {
    // 验证 series_id 可以正确表示为字符串，避免 JS Number 精度丢失
    const allocator = std.testing.allocator;
    const data_dir = "tmp_reg_sid";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{
            .{ .key = "host", .value = "server01" },
            .{ .key = "region", .value = "us-west" },
        },
    };

    const sid = key.computeId();
    try engine.write(key, .{ .timestamp = 1000, .value = 42.0 });

    // 验证 series_id 的字符串表示与数值一致
    var buf: [64]u8 = undefined;
    const sid_str = try std.fmt.bufPrint(&buf, "{d}", .{sid});
    const parsed_back = try std.fmt.parseInt(u64, sid_str, 10);
    try std.testing.expectEqual(sid, parsed_back);

    // 验证用原始 series_id 查询能找到数据
    const points = try engine.queryRange(sid, 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 1), points.len);
}

test "regression: query returns correct value (not empty)" {
    // 回归：之前查询返回的 value 为空
    const allocator = std.testing.allocator;
    const data_dir = "tmp_reg_val";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };

    try engine.write(key, .{ .timestamp = 100, .value = 75.5 });

    const points = try engine.queryRange(key.computeId(), 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 1), points.len);
    try std.testing.expectEqual(@as(f64, 75.5), points[0].value);
}

test "regression: write 2 records query returns 2 (not 4)" {
    // 回归：写入2条查到4条（数据重复问题）
    const allocator = std.testing.allocator;
    const data_dir = "tmp_reg_dup";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "server01" }},
    };
    const sid = key.computeId();

    try engine.write(key, .{ .timestamp = 100, .value = 1.0 });
    try engine.write(key, .{ .timestamp = 200, .value = 2.0 });

    const points = try engine.queryRange(sid, 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 2), points.len);
    try std.testing.expectEqual(@as(f64, 1.0), points[0].value);
    try std.testing.expectEqual(@as(f64, 2.0), points[1].value);
}

test "regression: nanosecond timestamp converts to milliseconds" {
    // 回归：纳秒时间戳未正确转换为毫秒
    const allocator = std.testing.allocator;
    const data_dir = "tmp_reg_ns";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    const line = "cpu,host=A value=42 1609459200000000000";
    const result = try engine.parseLineProtocol(line);
    try std.testing.expect(result != null);
    if (result) |p| {
        defer {
            allocator.free(p.key.metric);
            for (p.key.tags) |tag| {
                allocator.free(tag.key);
                allocator.free(tag.value);
            }
            allocator.free(p.key.tags);
        }
        // 1609459200000000000 ns = 1609459200000 ms
        try std.testing.expectEqual(@as(i64, 1609459200000), p.point.timestamp);
    }
}

test "regression: data directory not empty after flush" {
    // 回归：data 目录为空（数据未落盘）
    const allocator = std.testing.allocator;
    const data_dir = "tmp_reg_data_dir";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };

    try engine.write(key, .{ .timestamp = 100, .value = 1.0 });
    try engine.flushHotPartition();

    // 验证磁盘分区文件存在
    try std.testing.expect(engine.disk_partitions.items.len > 0);

    // 验证文件可读
    const file_path = engine.disk_partitions.items[0].file_path;
    const data = try tsdb.fs_helper.readFile(file_path, allocator);
    defer allocator.free(data);
    try std.testing.expect(data.len > 0);
    try std.testing.expectEqualStrings("TSDB", data[0..4]);
}

test "regression: HTTP query parameter parsing for large timestamps" {
    // 回归：前端传入纳秒时间戳时查询参数解析
    const http_server = @import("http_server");

    // 模拟前端传入纳秒时间戳
    const req = "GET /api/query?series_id=123&start=1609459200000000000&end=1609462800000000000 HTTP/1.1";
    const sid = http_server.extractQueryU64(req, "series_id");
    try std.testing.expect(sid != null);
    try std.testing.expectEqual(@as(u64, 123), sid.?);

    const start = http_server.extractQueryI64(req, "start");
    try std.testing.expect(start != null);
    // 1609459200000000000 应该能正确解析为 i64
    try std.testing.expectEqual(@as(i64, 1609459200000000000), start.?);
}

test "regression: query metric name with special characters" {
    const http_server = @import("http_server");

    const req = "GET /api/query_metric?metric=cpu_usage&start=0 HTTP/1.1";
    const metric = http_server.extractQueryString(req, "metric");
    try std.testing.expect(metric != null);
    try std.testing.expectEqualStrings("cpu_usage", metric.?);
}

// ==================== 验收测试 ====================
// 验证用户场景的端到端正确性

test "acceptance: user writes CPU metric and queries it back" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_accept_cpu";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    // 用户场景：写入 CPU 使用率，然后查询
    const line = "cpu,host=server01,region=us-west usage=75.5 1609459200000000000";
    const parsed = try engine.parseLineProtocol(line);
    try std.testing.expect(parsed != null);
    if (parsed) |p| {
        defer {
            allocator.free(p.key.metric);
            for (p.key.tags) |tag| {
                allocator.free(tag.key);
                allocator.free(tag.value);
            }
            allocator.free(p.key.tags);
        }
        const sid = p.key.computeId();
        try engine.write(p.key, p.point);

        // 用 series_id 查询
        const points = try engine.queryRange(sid, 0, 9999999999999, allocator);
        defer allocator.free(points);
        try std.testing.expectEqual(@as(usize, 1), points.len);
        try std.testing.expectEqual(@as(f64, 75.5), points[0].value);

        // 用 metric 名查询
        const metric_points = try engine.queryByMetric("cpu", 0, 9999999999999, allocator);
        defer allocator.free(metric_points);
        try std.testing.expectEqual(@as(usize, 1), metric_points.len);
    }
}

test "acceptance: user flushes data and queries from disk" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_accept_flush";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "memory",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "server01" }},
    };
    const sid = key.computeId();

    // 写入多条数据
    try engine.write(key, .{ .timestamp = 1000, .value = 50.0 });
    try engine.write(key, .{ .timestamp = 2000, .value = 60.0 });
    try engine.write(key, .{ .timestamp = 3000, .value = 70.0 });

    // 手动落盘
    try engine.flushHotPartition();

    // 热分区已清空
    try std.testing.expectEqual(@as(usize, 0), engine.hot_partition.series_map.count());

    // 查询应自动从磁盘加载数据
    const points = try engine.queryRange(sid, 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 3), points.len);
    try std.testing.expectEqual(@as(f64, 50.0), points[0].value);
    try std.testing.expectEqual(@as(f64, 60.0), points[1].value);
    try std.testing.expectEqual(@as(f64, 70.0), points[2].value);
}

test "acceptance: user writes multi-series batch and queries by metric" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_accept_multi";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    // 模拟批量写入：3 台服务器的 CPU 数据
    const hosts = [_][]const u8{ "server01", "server02", "server03" };
    for (&hosts, 0..) |host, i| {
        const key = tsdb.SeriesKey{
            .metric = "cpu",
            .tags = &[_]tsdb.Tag{.{ .key = "host", .value = host }},
        };
        try engine.write(key, .{ .timestamp = @intCast((i + 1) * 1000), .value = @floatFromInt(i * 10 + 50) });
    }

    // 按 metric 名查询应返回 3 条
    const points = try engine.queryByMetric("cpu", 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 3), points.len);
}

test "acceptance: data persists across engine restart" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_accept_restart";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    const key = tsdb.SeriesKey{
        .metric = "disk",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    // 第一次启动：写入并落盘
    {
        var engine = try tsdb.Engine.init(allocator, data_dir);
        defer engine.deinit();
        engine.hot_partition.start_time = 0;
        engine.hot_partition.end_time = 3600_000;

        try engine.write(key, .{ .timestamp = 100, .value = 1.0 });
        try engine.write(key, .{ .timestamp = 200, .value = 2.0 });
        try engine.flushHotPartition();

        // 记录磁盘分区文件路径
        try std.testing.expect(engine.disk_partitions.items.len > 0);
    }

    // 第二次启动：手动加载磁盘分区并查询
    {
        var engine = try tsdb.Engine.init(allocator, data_dir);
        defer engine.deinit();

        // 扫描 data 目录加载分区文件
        const dir = std.c.opendir(data_dir.ptr) orelse return error.CannotOpenDir;
        defer _ = std.c.closedir(dir);

        while (true) {
            const entry = std.c.readdir(dir) orelse break;
            const name = std.mem.sliceTo(&entry.name, 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (std.mem.endsWith(u8, name, ".tsdb")) {
                const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ data_dir, name });
                defer allocator.free(file_path);
                try engine.loadPartition(file_path);
            }
        }

        const points = try engine.queryRange(sid, 0, 9999999999999, allocator);
        defer allocator.free(points);
        try std.testing.expectEqual(@as(usize, 2), points.len);
    }
}

test "acceptance: query with time range filtering" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_accept_range";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    // 写入 5 个时间点的数据
    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        try engine.write(key, .{ .timestamp = (i + 1) * 1000, .value = @floatFromInt(i * 10) });
    }

    // 查询时间范围 [2000, 4000] 应返回 ts=2000, 3000, 4000 三条
    const points = try engine.queryRange(sid, 2000, 4000, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 3), points.len);
    try std.testing.expectEqual(@as(f64, 10.0), points[0].value);
    try std.testing.expectEqual(@as(f64, 20.0), points[1].value);
    try std.testing.expectEqual(@as(f64, 30.0), points[2].value);
}

// ==================== 系统测试 ====================
// 验证系统级别的稳定性和边界条件

test "system: concurrent writes from multiple threads" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_system_concurrent";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };

    // 多线程并发写入
    const num_threads = 4;
    const points_per_thread = 100;
    var threads: [num_threads]std.Thread = undefined;

    const Context = struct {
        engine: *tsdb.Engine,
        key: tsdb.SeriesKey,
        thread_id: usize,
        count: usize,
    };

    var contexts: [num_threads]Context = undefined;

    for (&threads, 0..) |*t, i| {
        contexts[i] = .{
            .engine = &engine,
            .key = key,
            .thread_id = i,
            .count = points_per_thread,
        };
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(c: *Context) void {
                var j: usize = 0;
                while (j < c.count) : (j += 1) {
                    const ts: i64 = @intCast(c.thread_id * 10000 + j);
                    c.engine.write(c.key, .{ .timestamp = ts, .value = @floatFromInt(j) }) catch {};
                }
            }
        }.run, .{&contexts[i]});
    }

    for (&threads) |t| {
        t.join();
    }

    // 验证总点数
    const sid = key.computeId();
    const points = try engine.queryRange(sid, 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, num_threads * points_per_thread), points.len);
}

test "system: large dataset write and query performance" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_system_large";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };

    // 写入 10000 个点
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        try engine.write(key, .{ .timestamp = @intCast(i), .value = @floatFromInt(i) });
    }

    const sid = key.computeId();

    // 全范围查询
    const points = try engine.queryRange(sid, 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 10000), points.len);

    // 范围查询
    const partial = try engine.queryRange(sid, 5000, 7000, allocator);
    defer allocator.free(partial);
    try std.testing.expect(partial.len > 0);
    try std.testing.expect(partial.len < 10000);
}

test "system: corrupted disk partition handling" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_system_corrupt";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    // 写入一个损坏的分区文件
    const corrupt_path = "tmp_system_corrupt/corrupt.tsdb";
    try tsdb.fs_helper.makePath(data_dir);
    try tsdb.fs_helper.writeFile(corrupt_path, "CORRUPT_DATA_HERE");

    // 加载损坏文件应返回错误
    try std.testing.expectError(error.InvalidMagic, engine.loadPartition(corrupt_path));
}

test "system: empty engine operations" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_system_empty";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    // 空引擎查询应返回空结果
    const points = try engine.queryRange(99999, 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 0), points.len);

    // 空引擎 queryByMetric
    const metric_points = try engine.queryByMetric("nonexistent", 0, 9999999999999, allocator);
    defer allocator.free(metric_points);
    try std.testing.expectEqual(@as(usize, 0), metric_points.len);

    // 空引擎 queryAvg
    const avg = try engine.queryAvg(99999, 0, 9999999999999);
    try std.testing.expect(avg == null);

    // 空引擎 flush 不崩溃
    try engine.flushHotPartition();
    try std.testing.expectEqual(@as(usize, 0), engine.disk_partitions.items.len);
}

test "system: multiple flush cycles" {
    const allocator = std.testing.allocator;
    const data_dir = "tmp_system_multi_flush";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    // 多次写入+flush循环
    // flush 后热分区时间范围前进，后续写入的时间戳需要在新范围内
    try engine.write(key, .{ .timestamp = 100, .value = 0.0 });
    try engine.flushHotPartition();

    // flush 后热分区时间范围变为 [3600000, 7200000)
    try engine.write(key, .{ .timestamp = 3600_100, .value = 1.0 });
    try engine.flushHotPartition();

    try engine.write(key, .{ .timestamp = 7200_100, .value = 2.0 });
    try engine.flushHotPartition();

    // 查询应返回全部 3 条（从磁盘分区自动加载）
    const points = try engine.queryRange(sid, 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 3), points.len);
}

// ==================== 接口测试 ====================
// 测试 HTTP API 端点的基本功能

test "api: write endpoint accepts single line" {
    std.debug.print("\n[API] Running: write endpoint\n", .{});
    // This test validates the write API logic by testing parseLineProtocol
    const allocator = std.testing.allocator;
    const data_dir = "tmp_api_write";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const line = "cpu,host=A usage=42.5 1609459200000000000";
    const parsed = try engine.parseLineProtocol(line);
    try std.testing.expect(parsed != null);
    if (parsed) |p| {
        defer {
            allocator.free(p.key.metric);
            for (p.key.tags) |tag| { allocator.free(tag.key); allocator.free(tag.value); }
            allocator.free(p.key.tags);
        }
        try engine.write(p.key, p.point);
        const points = try engine.queryRange(p.key.computeId(), 0, 9999999999999, allocator);
        defer allocator.free(points);
        try std.testing.expectEqual(@as(usize, 1), points.len);
    }
    std.debug.print("[API] PASSED: write endpoint\n", .{});
}

test "api: query endpoint returns correct format" {
    std.debug.print("\n[API] Running: query endpoint format\n", .{});
    const allocator = std.testing.allocator;
    const data_dir = "tmp_api_query";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };
    try engine.write(key, .{ .timestamp = 100, .value = 42.5 });

    const points = try engine.queryRangeEx(key.computeId(), 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 1), points.len);
    try std.testing.expectEqualStrings("cpu", points[0].metric);
    try std.testing.expectEqual(@as(u64, key.computeId()), points[0].series_id);
    std.debug.print("[API] PASSED: query endpoint format\n", .{});
}

test "api: query_metric endpoint finds data by name" {
    std.debug.print("\n[API] Running: query_metric endpoint\n", .{});
    const allocator = std.testing.allocator;
    const data_dir = "tmp_api_metric";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "memory",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };
    try engine.write(key, .{ .timestamp = 100, .value = 75.0 });

    const points = try engine.queryByMetricEx("memory", 0, 9999999999999, allocator);
    defer allocator.free(points);
    try std.testing.expect(points.len > 0);
    std.debug.print("[API] PASSED: query_metric endpoint\n", .{});
}

test "api: flush endpoint creates disk file" {
    std.debug.print("\n[API] Running: flush endpoint\n", .{});
    const allocator = std.testing.allocator;
    const data_dir = "tmp_api_flush";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };
    try engine.write(key, .{ .timestamp = 100, .value = 1.0 });
    try engine.flushHotPartition();

    try std.testing.expect(engine.disk_partitions.items.len > 0);
    std.debug.print("[API] PASSED: flush endpoint\n", .{});
}

test "api: export returns line protocol format" {
    std.debug.print("\n[API] Running: export endpoint\n", .{});
    const allocator = std.testing.allocator;
    const data_dir = "tmp_api_export";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();
    engine.hot_partition.start_time = 0;
    engine.hot_partition.end_time = 3600_000;

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{
            .{ .key = "host", .value = "server01" },
            .{ .key = "region", .value = "us-west" },
        },
    };
    try engine.write(key, .{ .timestamp = 100, .value = 35.47 });
    try engine.flushHotPartition();

    // Simulate export: load partition and format as LP
    try engine.loadPartition(engine.disk_partitions.items[0].file_path);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    const p = engine.readonly_partitions.items[0];
    var sit = p.series_keys.iterator();
    while (sit.next()) |entry| {
        const sid = entry.key_ptr.*;
        const k = entry.value_ptr.*;
        const sd = p.series_map.getPtr(sid) orelse continue;
        for (0..sd.len()) |i| {
            try output.appendSlice(allocator, k.metric);
            for (k.tags) |tag| {
                try output.appendSlice(allocator, ",");
                try output.appendSlice(allocator, tag.key);
                try output.appendSlice(allocator, "=");
                try output.appendSlice(allocator, tag.value);
            }
            try output.appendSlice(allocator, " value=");
            var val_buf: [64]u8 = undefined;
            const val_str = try std.fmt.bufPrint(&val_buf, "{d:.2}", .{sd.values.items[i]});
            try output.appendSlice(allocator, val_str);
            try output.appendSlice(allocator, " ");
            var ts_buf: [32]u8 = undefined;
            const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{sd.timestamps.items[i] * 1_000_000});
            try output.appendSlice(allocator, ts_str);
            try output.appendSlice(allocator, "\n");
        }
    }

    const result = output.items;
    try std.testing.expect(std.mem.startsWith(u8, result, "cpu,"));
    try std.testing.expect(std.mem.indexOf(u8, result, "host=server01") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "region=us-west") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "value=35.47") != null);
    std.debug.print("[API] PASSED: export endpoint\n", .{});
}
