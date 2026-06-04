const std = @import("std");
const tsdb = @import("tsdb");

fn nanoTimestamp() i64 {
    var tv: std.c.timeval = undefined;
    const rc = std.c.gettimeofday(&tv, null);
    std.debug.assert(rc == 0);
    return @as(i64, tv.sec) * 1_000_000_000 + @as(i64, tv.usec) * 1000;
}

const Timer = struct {
    start_ns: i64,

    pub fn start() !Timer {
        return .{ .start_ns = nanoTimestamp() };
    }

    pub fn read(self: Timer) u64 {
        return @intCast(nanoTimestamp() - self.start_ns);
    }
};

/// 性能基准测试
/// 测量高并发写入和范围查询的吞吐量

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("\n=== TSDB.zig Performance Benchmark ===\n\n", .{});

    try benchmarkWriteSinglePoint(allocator);
    try benchmarkWriteBatch(allocator);
    try benchmarkWriteMultiSeries(allocator);
    try benchmarkQueryLatency(allocator);
    try benchmarkMemoryPartitionSort(allocator);
}

/// 单点逐条写入（模拟高基数场景，与 InfluxDB 3 Core ~320K/s 对标）
fn benchmarkWriteSinglePoint(allocator: std.mem.Allocator) !void {
    const data_dir = "tmp_bench_single";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    const total_points = 100_000;
    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "benchmark" }},
    };

    var timer = try Timer.start();
    var i: u32 = 0;
    while (i < total_points) : (i += 1) {
        try engine.write(key, .{
            .timestamp = @as(i64, i),
            .value = @floatFromInt(i),
        });
    }
    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const points_per_sec = @as(f64, @floatFromInt(total_points)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    std.debug.print("Write Throughput (Single Point):\n", .{});
    std.debug.print("  Points written: {d}\n", .{total_points});
    std.debug.print("  Elapsed: {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("  Throughput: {d:.0} points/sec\n\n", .{points_per_sec});
}

/// 批量写入（同序列，单次锁保护）
fn benchmarkWriteBatch(allocator: std.mem.Allocator) !void {
    const data_dir = "tmp_bench_batch";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    const points_per_series = 100_000;
    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "benchmark" }},
    };

    var points = try allocator.alloc(tsdb.DataPoint, points_per_series);
    defer allocator.free(points);
    var i: u32 = 0;
    while (i < points_per_series) : (i += 1) {
        points[i] = .{
            .timestamp = @as(i64, i),
            .value = @floatFromInt(i),
        };
    }

    var timer = try Timer.start();
    try engine.writeBatch(key, points);
    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const points_per_sec = @as(f64, @floatFromInt(points_per_series)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    std.debug.print("Write Throughput (Batch, 1 series):\n", .{});
    std.debug.print("  Points written: {d}\n", .{points_per_series});
    std.debug.print("  Elapsed: {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("  Throughput: {d:.0} points/sec\n\n", .{points_per_sec});
}

/// 多序列批量写入（模拟真实监控：100 个 host，每个 1000 点）
fn benchmarkWriteMultiSeries(allocator: std.mem.Allocator) !void {
    const data_dir = "tmp_bench_multi";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    const num_series = 100;
    const points_per_series = 1_000;
    const total_points = num_series * points_per_series;

    var buf: [32]u8 = undefined;

    var timer = try Timer.start();
    var s: u32 = 0;
    while (s < num_series) : (s += 1) {
        const host = try std.fmt.bufPrint(&buf, "host{d}", .{s});
        const key = tsdb.SeriesKey{
            .metric = "cpu",
            .tags = &[_]tsdb.Tag{.{ .key = "host", .value = host }},
        };
        var points = try allocator.alloc(tsdb.DataPoint, points_per_series);
        defer allocator.free(points);
        var i: u32 = 0;
        while (i < points_per_series) : (i += 1) {
            points[i] = .{
                .timestamp = @as(i64, i),
                .value = @floatFromInt(i % 100),
            };
        }
        try engine.writeBatch(key, points);
    }
    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const points_per_sec = @as(f64, @floatFromInt(total_points)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    std.debug.print("Write Throughput (Multi Series, {d} series x {d} pts):\n", .{ num_series, points_per_series });
    std.debug.print("  Points written: {d}\n", .{total_points});
    std.debug.print("  Elapsed: {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("  Throughput: {d:.0} points/sec\n\n", .{points_per_sec});
}

fn benchmarkQueryLatency(allocator: std.mem.Allocator) !void {
    const data_dir = "tmp_bench_query";
    defer tsdb.fs_helper.deleteTree(data_dir) catch {};

    var engine = try tsdb.Engine.init(allocator, data_dir);
    defer engine.deinit();

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "benchmark" }},
    };
    const sid = key.computeId();

    // 预加载 100 万点（使用批量写入）
    const total_points = 1_000_000;
    var batch = try allocator.alloc(tsdb.DataPoint, total_points);
    defer allocator.free(batch);
    var i: u32 = 0;
    while (i < total_points) : (i += 1) {
        batch[i] = .{
            .timestamp = @as(i64, i),
            .value = @floatFromInt(i % 100),
        };
    }
    try engine.writeBatch(key, batch);

    // 刷盘后再加载以测试磁盘查询
    try engine.flushHotPartition();

    var engine2 = try tsdb.Engine.init(allocator, "tmp_bench_query2");
    defer {
        engine2.deinit();
        tsdb.fs_helper.deleteTree("tmp_bench_query2") catch {};
    }

    // 直接从 engine.disk_partitions 获取文件路径
    try engine2.loadPartition(engine.disk_partitions.items[0].file_path);

    // 执行多次范围查询并测量延迟
    const num_queries = 1000;
    var total_ns: u64 = 0;
    var q: u32 = 0;
    while (q < num_queries) : (q += 1) {
        const start = @mod(q * 1000, total_points - 10000);
        const end = start + 10000;

        var timer = try Timer.start();
        const points = try engine2.queryRange(sid, start, end, allocator);
        const elapsed = timer.read();
        allocator.free(points);
        total_ns += elapsed;
    }

    const avg_ns = total_ns / num_queries;
    const avg_us = @as(f64, @floatFromInt(avg_ns)) / 1000.0;

    std.debug.print("Query Latency:\n", .{});
    std.debug.print("  Queries: {d}\n", .{num_queries});
    std.debug.print("  Range: 10,000 points per query\n", .{});
    std.debug.print("  Avg latency: {d:.2} us\n\n", .{avg_us});
}

fn benchmarkMemoryPartitionSort(allocator: std.mem.Allocator) !void {
    var part = tsdb.MemoryPartition.init(allocator, 0, 3600_000);
    defer part.deinit();

    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "sort" }},
    };

    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();
    const n = 1_000_000;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ts = rng.int(i64);
        try part.insert(key.computeId(), key, ts, @floatFromInt(ts), 1024);
    }

    var timer = try Timer.start();
    part.sortAll();
    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    // 验证有序
    const sd = part.series_map.get(key.computeId()).?;
    var sorted = true;
    var j: usize = 1;
    while (j < sd.len()) : (j += 1) {
        if (sd.timestamps.items[j] < sd.timestamps.items[j - 1]) {
            sorted = false;
            break;
        }
    }

    std.debug.print("Memory Partition Sort:\n", .{});
    std.debug.print("  Points: {d}\n", .{n});
    std.debug.print("  Elapsed: {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("  Sorted: {}\n\n", .{sorted});
}
