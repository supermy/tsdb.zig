const std = @import("std");
const tsdb = @import("tsdb");

/// Compaction 负责将多个小的内存分区或磁盘分区合并为更大的不可变分区。
/// 合并过程包括：排序、去重（相同时间戳和序列保留最新值）、重新序列化。
/// 生产环境应将合并后的分区写入 Parquet；此处使用与 Engine 相同的二进制格式。
pub const Compactor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Compactor {
        return .{
            .allocator = allocator,
        };
    }

    /// 合并两个内存分区，返回一个新的分区（需调用方 deinit）
    pub fn mergePartitions(self: *Compactor, a: *const tsdb.MemoryPartition, b: *const tsdb.MemoryPartition) !tsdb.MemoryPartition {
        const start = @min(a.start_time, b.start_time);
        const end = @max(a.end_time, b.end_time);
        var result = tsdb.MemoryPartition.init(self.allocator, start, end);
        errdefer result.deinit();

        try self.copyPartitionInto(a, &result);
        try self.copyPartitionInto(b, &result);
        result.sortAll();
        try self.deduplicatePartition(&result);
        return result;
    }

    fn copyPartitionInto(self: *Compactor, src: *const tsdb.MemoryPartition, dst: *tsdb.MemoryPartition) !void {
        _ = self;
        var it = src.series_map.iterator();
        while (it.next()) |entry| {
            const sid = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            const key = src.series_keys.get(sid) orelse continue;
            const sd = try dst.getOrCreateSeriesData(sid, key, 1024);
            try sd.timestamps.appendSlice(dst.allocator, data.timestamps.items);
            try sd.values.appendSlice(dst.allocator, data.values.items);
        }
    }

    /// 对分区内每个序列按时间戳去重：相同时间戳保留最后出现的值
    fn deduplicatePartition(self: *Compactor, partition: *tsdb.MemoryPartition) !void {
        _ = self;
        var it = partition.series_map.iterator();
        while (it.next()) |entry| {
            const sd = entry.value_ptr;
            const n = sd.len();
            if (n <= 1) continue;

            // 由于已经排序，只需扫描去重
            var write_idx: usize = 0;
            var read_idx: usize = 1;
            while (read_idx < n) : (read_idx += 1) {
                if (sd.timestamps.items[read_idx] == sd.timestamps.items[write_idx]) {
                    // 重复时间戳，覆盖值（保留最新）
                    sd.values.items[write_idx] = sd.values.items[read_idx];
                } else {
                    write_idx += 1;
                    sd.timestamps.items[write_idx] = sd.timestamps.items[read_idx];
                    sd.values.items[write_idx] = sd.values.items[read_idx];
                }
            }
            sd.timestamps.shrinkAndFree(partition.allocator, write_idx + 1);
            sd.values.shrinkAndFree(partition.allocator, write_idx + 1);
        }
    }

    /// 将分区重写为磁盘文件（与 Engine.flushHotPartition 相同格式）
    pub fn writePartitionToDisk(self: *Compactor, partition: *tsdb.MemoryPartition, file_path: []const u8) !void {
        _ = self;
        var writer = tsdb.fs_helper.BinaryWriter.init();
        defer writer.deinit(partition.allocator);

        try writer.writeAll(partition.allocator, "TSDB");
        try writer.writeInt(u32, 1, .little, partition.allocator);
        try writer.writeInt(i64, partition.start_time, .little, partition.allocator);
        try writer.writeInt(i64, partition.end_time, .little, partition.allocator);

        const series_count: u32 = @intCast(partition.series_map.count());
        try writer.writeInt(u32, series_count, .little, partition.allocator);

        var sit = partition.series_map.iterator();
        while (sit.next()) |entry| {
            const sid = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            const key = partition.series_keys.get(sid).?;

            try writer.writeInt(u64, sid, .little, partition.allocator);
            try writer.writeInt(u32, @intCast(key.metric.len), .little, partition.allocator);
            try writer.writeAll(partition.allocator, key.metric);
            try writer.writeInt(u32, @intCast(key.tags.len), .little, partition.allocator);
            for (key.tags) |tag| {
                try writer.writeInt(u32, @intCast(tag.key.len), .little, partition.allocator);
                try writer.writeAll(partition.allocator, tag.key);
                try writer.writeInt(u32, @intCast(tag.value.len), .little, partition.allocator);
                try writer.writeAll(partition.allocator, tag.value);
            }
            const pc: u32 = @intCast(data.len());
            try writer.writeInt(u32, pc, .little, partition.allocator);
            for (data.timestamps.items) |ts| {
                try writer.writeInt(i64, ts, .little, partition.allocator);
            }
            for (data.values.items) |val| {
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, @as(u64, @bitCast(val)), .little);
                try writer.writeAll(partition.allocator, &bytes);
            }
        }

        try tsdb.fs_helper.writeFile(file_path, writer.items());
    }
};

test "Compactor merge and deduplicate" {
    const allocator = std.testing.allocator;
    var compactor = Compactor.init(allocator);

    var part_a = tsdb.MemoryPartition.init(allocator, 0, 100);
    defer part_a.deinit();
    const key = tsdb.SeriesKey{
        .metric = "cpu",
        .tags = &[_]tsdb.Tag{.{ .key = "host", .value = "A" }},
    };
    try part_a.insert(key.computeId(), key, 10, 1.0, 1024);
    try part_a.insert(key.computeId(), key, 20, 2.0, 1024);

    var part_b = tsdb.MemoryPartition.init(allocator, 50, 150);
    defer part_b.deinit();
    try part_b.insert(key.computeId(), key, 20, 3.0, 1024); // 重复时间戳
    try part_b.insert(key.computeId(), key, 30, 4.0, 1024);

    var merged = try compactor.mergePartitions(&part_a, &part_b);
    defer merged.deinit();

    const sd = merged.series_map.get(key.computeId()).?;
    try std.testing.expectEqual(@as(usize, 3), sd.len());
    try std.testing.expectEqual(@as(i64, 10), sd.timestamps.items[0]);
    try std.testing.expectEqual(@as(i64, 20), sd.timestamps.items[1]);
    // 去重后保留 3.0（来自 part_b 的最后覆盖）
    try std.testing.expectEqual(@as(f64, 3.0), sd.values.items[1]);
    try std.testing.expectEqual(@as(i64, 30), sd.timestamps.items[2]);
}
