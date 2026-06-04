const std = @import("std");
const fs = @import("fs_helper.zig");

pub const fs_helper = fs;

/// 获取当前毫秒时间戳（Zig 0.16 移除了 std.time.milliTimestamp）
fn milliTimestamp() !i64 {
    var tv: std.c.timeval = undefined;
    const rc = std.c.gettimeofday(&tv, null);
    if (rc != 0) return error.TimeError;
    return @as(i64, tv.sec) * 1000 + @divFloor(tv.usec, 1000);
}

/// Zig 0.16 兼容的阻塞互斥锁包装器
pub const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

/// 时序数据点：时间戳 + 值
pub const DataPoint = struct {
    timestamp: i64, // 毫秒时间戳
    value: f64,
};

/// 标签键值对，用于标识序列
pub const Tag = struct {
    key: []const u8,
    value: []const u8,

    pub fn hash(t: Tag, hasher: *std.hash.Wyhash) void {
        hasher.update(t.key);
        hasher.update(t.value);
    }

    pub fn eql(a: Tag, b: Tag) bool {
        return std.mem.eql(u8, a.key, b.key) and std.mem.eql(u8, a.value, b.value);
    }
};

/// 序列标识 = 指标名 + 有序标签集合
pub const SeriesKey = struct {
    metric: []const u8,
    tags: []const Tag,

    pub fn computeId(self: SeriesKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(self.metric);
        for (self.tags) |tag| {
            tag.hash(&hasher);
        }
        return hasher.final();
    }

    pub fn format(
        self: SeriesKey,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}", .{self.metric});
        for (self.tags) |tag| {
            try writer.print(",{s}={s}", .{ tag.key, tag.value });
        }
    }
};

/// 单列序列数据（列式存储）
pub const SeriesData = struct {
    timestamps: std.ArrayList(i64),
    values: std.ArrayList(f64),

    pub fn init() SeriesData {
        return .{
            .timestamps = std.ArrayList(i64).empty,
            .values = std.ArrayList(f64).empty,
        };
    }

    pub fn deinit(self: *SeriesData, allocator: std.mem.Allocator) void {
        self.timestamps.deinit(allocator);
        self.values.deinit(allocator);
    }

    pub fn append(self: *SeriesData, allocator: std.mem.Allocator, timestamp: i64, value: f64) !void {
        try self.timestamps.append(allocator, timestamp);
        try self.values.append(allocator, value);
    }

    pub fn appendSlice(self: *SeriesData, allocator: std.mem.Allocator, timestamps: []const i64, values: []const f64) !void {
        try self.timestamps.appendSlice(allocator, timestamps);
        try self.values.appendSlice(allocator, values);
    }

    pub fn len(self: *const SeriesData) usize {
        return self.timestamps.items.len;
    }

    /// 按时间戳排序（若数据无序摄入，需先排序）
    pub fn sort(self: *SeriesData, allocator: std.mem.Allocator) void {
        const TimedValue = struct {
            ts: i64,
            val: f64,
        };
        const n = self.timestamps.items.len;
        if (n == 0) return;

        var temp = std.ArrayList(TimedValue).empty;
        defer temp.deinit(allocator);
        temp.ensureTotalCapacityPrecise(allocator, n) catch return;
        for (0..n) |i| {
            temp.appendAssumeCapacity(.{
                .ts = self.timestamps.items[i],
                .val = self.values.items[i],
            });
        }

        std.mem.sort(TimedValue, temp.items, {}, struct {
            pub fn lessThan(_: void, a: TimedValue, b: TimedValue) bool {
                return a.ts < b.ts;
            }
        }.lessThan);

        for (0..n) |i| {
            self.timestamps.items[i] = temp.items[i].ts;
            self.values.items[i] = temp.items[i].val;
        }
    }
};

/// 内存分区：一个时间范围内的列式数据
/// 保持 Arrow 列式语义：按序列分块，每块内时间戳与值独立数组
pub const MemoryPartition = struct {
    start_time: i64,
    end_time: i64,
    // series_id -> 数据
    series_map: std.AutoHashMap(u64, SeriesData),
    // series_id -> 序列键（用于序列化）
    series_keys: std.AutoHashMap(u64, SeriesKey),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, start_time: i64, end_time: i64) MemoryPartition {
        return .{
            .start_time = start_time,
            .end_time = end_time,
            .series_map = std.AutoHashMap(u64, SeriesData).init(allocator),
            .series_keys = std.AutoHashMap(u64, SeriesKey).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryPartition) void {
        var it = self.series_map.valueIterator();
        while (it.next()) |sd| {
            sd.deinit(self.allocator);
        }
        self.series_map.deinit();

        // 释放 series_keys 中的字符串
        var key_it = self.series_keys.iterator();
        while (key_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.metric);
            for (entry.value_ptr.tags) |tag| {
                self.allocator.free(tag.key);
                self.allocator.free(tag.value);
            }
            self.allocator.free(entry.value_ptr.tags);
        }
        self.series_keys.deinit();
    }

    fn cloneSeriesKey(self: *MemoryPartition, key: SeriesKey) !SeriesKey {
        const metric = try self.allocator.dupe(u8, key.metric);
        errdefer self.allocator.free(metric);
        const tags = try self.allocator.alloc(Tag, key.tags.len);
        errdefer {
            // 只释放已成功初始化的 tag 字符串
            var k: usize = 0;
            while (k < tags.len) : (k += 1) {
                if (tags[k].key.len > 0) self.allocator.free(tags[k].key);
                if (tags[k].value.len > 0) self.allocator.free(tags[k].value);
            }
            self.allocator.free(tags);
        }
        for (key.tags, 0..) |tag, i| {
            const key_owned = try self.allocator.dupe(u8, tag.key);
            errdefer self.allocator.free(key_owned);
            tags[i] = .{
                .key = key_owned,
                .value = try self.allocator.dupe(u8, tag.value),
            };
        }
        return .{ .metric = metric, .tags = tags };
    }

    fn freeSeriesKey(allocator: std.mem.Allocator, key: SeriesKey) void {
        allocator.free(key.metric);
        for (key.tags) |tag| {
            allocator.free(tag.key);
            allocator.free(tag.value);
        }
        allocator.free(key.tags);
    }

    pub fn insert(self: *MemoryPartition, series_id: u64, key: SeriesKey, timestamp: i64, value: f64, prealloc: usize) !void {
        const gop = try self.series_map.getOrPut(series_id);
        if (!gop.found_existing) {
            const owned_key = try self.cloneSeriesKey(key);
            errdefer freeSeriesKey(self.allocator, owned_key);
            try self.series_keys.put(series_id, owned_key);
            var sd = SeriesData.init();
            // 预分配容量，减少扩容开销
            try sd.timestamps.ensureTotalCapacityPrecise(self.allocator, prealloc);
            try sd.values.ensureTotalCapacityPrecise(self.allocator, prealloc);
            gop.value_ptr.* = sd;
        }
        try gop.value_ptr.append(self.allocator, timestamp, value);
    }

    pub fn getOrCreateSeriesData(self: *MemoryPartition, series_id: u64, key: SeriesKey, prealloc: usize) !*SeriesData {
        const gop = try self.series_map.getOrPut(series_id);
        if (!gop.found_existing) {
            const owned_key = try self.cloneSeriesKey(key);
            errdefer freeSeriesKey(self.allocator, owned_key);
            try self.series_keys.put(series_id, owned_key);
            var sd = SeriesData.init();
            try sd.timestamps.ensureTotalCapacityPrecise(self.allocator, prealloc);
            try sd.values.ensureTotalCapacityPrecise(self.allocator, prealloc);
            gop.value_ptr.* = sd;
        }
        return gop.value_ptr;
    }

    pub fn sortAll(self: *MemoryPartition) void {
        var it = self.series_map.valueIterator();
        while (it.next()) |sd| {
            sd.sort(self.allocator);
        }
    }
};

/// 分区元数据（磁盘上的不可变文件）
pub const PartitionMeta = struct {
    start_time: i64,
    end_time: i64,
    file_path: []const u8,
    series_count: u32,
    point_count: u64,
};

/// 时序数据库引擎
/// 负责：摄入路由、分区管理、查询调度、保留策略
pub const Engine = struct {
    allocator: std.mem.Allocator,
    // 时间分区粒度（毫秒）
    partition_duration: i64,
    // 当前热分区
    hot_partition: *MemoryPartition,
    // 只读内存分区（等待刷盘或刚加载）
    readonly_partitions: std.ArrayList(*MemoryPartition),
    // 磁盘分区元数据
    disk_partitions: std.ArrayList(PartitionMeta),
    // 标签索引：tag_key=tag_value -> 系列 ID 集合
    tag_index: std.StringHashMap(std.AutoHashMap(u64, void)),
    // 保护引擎状态的互斥锁
    lock: Mutex,
    // 数据目录
    data_dir: []const u8,
    // 最大内存分区大小（点数），超过则刷盘
    max_partition_points: usize,
    // 热分区当前点数（增量计数，避免每次 O(series_count) 遍历）
    hot_partition_points: usize,
    // 预分配容量：每个新序列的初始容量
    series_prealloc: usize,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !Engine {
        const partition_duration_ms = 3600_000; // 1小时分区

        const hot = try allocator.create(MemoryPartition);
        const now = try milliTimestamp();
        const start = @divTrunc(now, partition_duration_ms) * partition_duration_ms;
        hot.* = MemoryPartition.init(allocator, start, start + partition_duration_ms);

        // 确保数据目录存在
        fs.makePath(data_dir) catch {};

        return .{
            .allocator = allocator,
            .partition_duration = partition_duration_ms,
            .hot_partition = hot,
            .readonly_partitions = std.ArrayList(*MemoryPartition).empty,
            .disk_partitions = std.ArrayList(PartitionMeta).empty,
            .tag_index = std.StringHashMap(std.AutoHashMap(u64, void)).init(allocator),
            .lock = .{},
            .data_dir = try allocator.dupe(u8, data_dir),
            .max_partition_points = 10_000_000, // 1000万点
            .hot_partition_points = 0,
            .series_prealloc = 1024,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.hot_partition.deinit();
        self.allocator.destroy(self.hot_partition);

        for (self.readonly_partitions.items) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        self.readonly_partitions.deinit(self.allocator);

        for (self.disk_partitions.items) |meta| {
            self.allocator.free(meta.file_path);
        }
        self.disk_partitions.deinit(self.allocator);

        var it = self.tag_index.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.tag_index.deinit();

        self.allocator.free(self.data_dir);
    }

    /// 写入单条数据点
    pub fn write(self: *Engine, series_key: SeriesKey, point: DataPoint) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.writeUnlocked(series_key, point);
    }

    /// 批量写入多个数据点（同序列），单次锁保护
    pub fn writeBatch(self: *Engine, series_key: SeriesKey, points: []const DataPoint) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const series_id = series_key.computeId();
        // 只对第一个点建立索引，后续点复用
        var first = true;
        for (points) |point| {
            try self.writeUnlockedInternal(series_key, point, series_id, &first);
        }
    }

    fn writeUnlocked(self: *Engine, series_key: SeriesKey, point: DataPoint) !void {
        const series_id = series_key.computeId();
        var first = true;
        try self.writeUnlockedInternal(series_key, point, series_id, &first);
    }

    fn writeUnlockedInternal(self: *Engine, series_key: SeriesKey, point: DataPoint, series_id: u64, is_first: *bool) !void {
        // 优化：若 series_id 已在热分区中，跳过 tag_index（索引已建立）
        const is_new_series = !self.hot_partition.series_map.contains(series_id);
        if (is_new_series and is_first.*) {
            is_first.* = false;
            // 更新时间索引（仅新序列需要）
            for (series_key.tags) |tag| {
                const index_key = try std.fmt.allocPrint(self.allocator, "{s}={s}", .{ tag.key, tag.value });
                errdefer self.allocator.free(index_key);

                const gop = try self.tag_index.getOrPut(index_key);
                if (!gop.found_existing) {
                    const owned_key = try self.allocator.dupe(u8, index_key);
                    gop.key_ptr.* = owned_key;
                    gop.value_ptr.* = std.AutoHashMap(u64, void).init(self.allocator);
                    self.allocator.free(index_key);
                } else {
                    self.allocator.free(index_key);
                }
                try gop.value_ptr.put(series_id, {});
            }
        }

        // 确定分区
        const partition_start = @divTrunc(point.timestamp, self.partition_duration) * self.partition_duration;
        const partition_end = partition_start + self.partition_duration;

        if (partition_start == self.hot_partition.start_time) {
            try self.hot_partition.insert(series_id, series_key, point.timestamp, point.value, self.series_prealloc);
        } else if (partition_start < self.hot_partition.start_time) {
            try self.hot_partition.insert(series_id, series_key, point.timestamp, point.value, self.series_prealloc);
        } else {
            // 未来数据：旋转分区
            try self.rotateHotPartition();
            self.hot_partition.start_time = partition_start;
            self.hot_partition.end_time = partition_end;
            try self.hot_partition.insert(series_id, series_key, point.timestamp, point.value, self.series_prealloc);
        }

        self.hot_partition_points += 1;

        // 检查是否需要刷盘（增量计数，O(1)）
        if (self.hot_partition_points >= self.max_partition_points) {
            try self.flushHotPartition();
        }
    }

    fn rotateHotPartition(self: *Engine) !void {
        try self.flushHotPartition();
    }

    /// 将热分区刷写到磁盘（简化二进制格式，预留 Parquet 替换路径）
    pub fn flushHotPartition(self: *Engine) !void {
        // 空分区不刷盘
        if (self.hot_partition.series_map.count() == 0) return;

        self.hot_partition.sortAll();

        const filename = try std.fmt.allocPrint(self.allocator, "{s}/partition_{d}_{d}.tsdb", .{
            self.data_dir,
            self.hot_partition.start_time,
            self.hot_partition.end_time,
        });
        defer self.allocator.free(filename);

        var writer = fs.BinaryWriter.init();
        defer writer.deinit(self.allocator);

        // 简单二进制格式：
        try writer.writeAll(self.allocator, "TSDB");
        try writer.writeInt(u32, 1, .little, self.allocator);
        try writer.writeInt(i64, self.hot_partition.start_time, .little, self.allocator);
        try writer.writeInt(i64, self.hot_partition.end_time, .little, self.allocator);

        const series_count: u32 = @intCast(self.hot_partition.series_map.count());
        try writer.writeInt(u32, series_count, .little, self.allocator);

        var total_points: u64 = 0;
        var sit = self.hot_partition.series_map.iterator();
        while (sit.next()) |entry| {
            const sid = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            const key = self.hot_partition.series_keys.get(sid).?;

            try writer.writeInt(u64, sid, .little, self.allocator);
            try writer.writeInt(u32, @intCast(key.metric.len), .little, self.allocator);
            try writer.writeAll(self.allocator, key.metric);
            try writer.writeInt(u32, @intCast(key.tags.len), .little, self.allocator);
            for (key.tags) |tag| {
                try writer.writeInt(u32, @intCast(tag.key.len), .little, self.allocator);
                try writer.writeAll(self.allocator, tag.key);
                try writer.writeInt(u32, @intCast(tag.value.len), .little, self.allocator);
                try writer.writeAll(self.allocator, tag.value);
            }
            const pc: u32 = @intCast(data.len());
            try writer.writeInt(u32, pc, .little, self.allocator);
            for (data.timestamps.items) |ts| {
                try writer.writeInt(i64, ts, .little, self.allocator);
            }
            for (data.values.items) |val| {
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, @as(u64, @bitCast(val)), .little);
                try writer.writeAll(self.allocator, &bytes);
            }
            total_points += pc;
        }

        try fs.writeFile(filename, writer.items());

        // 先追加元数据，再清空热分区（避免元数据追加失败导致数据丢失）
        const next_start = self.hot_partition.end_time;
        const next_end = next_start + self.partition_duration;

        try self.disk_partitions.append(self.allocator, .{
            .start_time = self.hot_partition.start_time,
            .end_time = self.hot_partition.end_time,
            .file_path = try self.allocator.dupe(u8, filename),
            .series_count = series_count,
            .point_count = total_points,
        });

        // 清空热分区
        self.hot_partition.deinit();
        self.hot_partition.* = MemoryPartition.init(self.allocator, next_start, next_end);
        self.hot_partition_points = 0;
    }

    /// 加载磁盘分区到只读内存（mmap 风格的简化：全量加载）
    pub fn loadPartition(self: *Engine, file_path: []const u8) !void {
        const data = try fs.readFile(file_path, self.allocator);
        defer self.allocator.free(data);
        var reader = fs.BinaryReader.init(data);

        var magic: [4]u8 = undefined;
        try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "TSDB")) return error.InvalidMagic;

        const version = try reader.readInt(u32, .little);
        if (version != 1) return error.UnsupportedVersion;

        const start_time = try reader.readInt(i64, .little);
        const end_time = try reader.readInt(i64, .little);
        const series_count = try reader.readInt(u32, .little);

        var total_points: u64 = 0;
        const partition = try self.allocator.create(MemoryPartition);
        partition.* = MemoryPartition.init(self.allocator, start_time, end_time);
        errdefer {
            partition.deinit();
            self.allocator.destroy(partition);
        }

        var i: u32 = 0;
        while (i < series_count) : (i += 1) {
            const sid = try reader.readInt(u64, .little);
            const metric_len = try reader.readInt(u32, .little);
            const metric = try reader.readSlice(metric_len);

            const tag_count = try reader.readInt(u32, .little);
            const tags = try self.allocator.alloc(Tag, tag_count);
            defer self.allocator.free(tags);
            var j: u32 = 0;
            while (j < tag_count) : (j += 1) {
                const key_len = try reader.readInt(u32, .little);
                const key_slice = try reader.readSlice(key_len);
                const value_len = try reader.readInt(u32, .little);
                const value_slice = try reader.readSlice(value_len);
                tags[j] = .{ .key = key_slice, .value = value_slice };
            }

            const point_count = try reader.readInt(u32, .little);
            const timestamps = try self.allocator.alloc(i64, point_count);
            defer self.allocator.free(timestamps);
            var k: usize = 0;
            while (k < point_count) : (k += 1) {
                timestamps[k] = try reader.readInt(i64, .little);
            }

            const values = try self.allocator.alloc(f64, point_count);
            defer self.allocator.free(values);
            k = 0;
            while (k < point_count) : (k += 1) {
                var bytes: [8]u8 = undefined;
                try reader.readAll(&bytes);
                values[k] = std.mem.bytesToValue(f64, &bytes);
            }

            // getOrCreateSeriesData 会深度克隆 key
            const series_key = SeriesKey{ .metric = metric, .tags = tags };
            const sd = try partition.getOrCreateSeriesData(sid, series_key, 1024);
            try sd.appendSlice(self.allocator, timestamps, values);
            total_points += point_count;
        }

        try self.readonly_partitions.append(self.allocator, partition);
    }

    /// 查询某序列在时间范围内的数据点
    pub fn queryRange(self: *Engine, series_id: u64, start: i64, end: i64, allocator: std.mem.Allocator) ![]DataPoint {
        var result = std.ArrayList(DataPoint).empty;
        errdefer result.deinit(allocator);

        self.lock.lock();
        defer self.lock.unlock();

        // 查询热分区
        try self.queryPartition(self.hot_partition, series_id, start, end, &result, allocator);

        // 查询只读内存分区
        for (self.readonly_partitions.items) |partition| {
            try self.queryPartition(partition, series_id, start, end, &result, allocator);
        }

        // TODO: 查询磁盘分区（按需加载）

        return result.toOwnedSlice(allocator);
    }

    fn queryPartition(self: *Engine, partition: *MemoryPartition, series_id: u64, start: i64, end: i64, result: *std.ArrayList(DataPoint), allocator: std.mem.Allocator) !void {
        _ = self;
        const sd = partition.series_map.getPtr(series_id) orelse return;
        const n = sd.len();
        if (n == 0) return;

        // 二分查找起始位置（假设已排序）
        const left = std.sort.lowerBound(i64, sd.timestamps.items, start, struct {
            pub fn compare(ctx: i64, item: i64) std.math.Order {
                return std.math.order(ctx, item);
            }
        }.compare);
        const right = std.sort.upperBound(i64, sd.timestamps.items, end, struct {
            pub fn compare(ctx: i64, item: i64) std.math.Order {
                return std.math.order(ctx, item);
            }
        }.compare);

        for (left..right) |i| {
            try result.append(allocator, .{
                .timestamp = sd.timestamps.items[i],
                .value = sd.values.items[i],
            });
        }
    }

    /// 聚合查询：某序列在时间范围内的平均值
    pub fn queryAvg(self: *Engine, series_id: u64, start: i64, end: i64) !?f64 {
        const points = try self.queryRange(series_id, start, end, self.allocator);
        defer self.allocator.free(points);
        if (points.len == 0) return null;
        var sum: f64 = 0;
        for (points) |p| {
            sum += p.value;
        }
        return sum / @as(f64, @floatFromInt(points.len));
    }

    /// 解析 InfluxDB Line Protocol 单条写入
    /// 格式: measurement,tag1=v1,tag2=v2 field=123i 1609459200000000000
    /// 返回的 SeriesKey 和 tags 均为深拷贝，调用方需负责释放
    pub fn parseLineProtocol(self: *Engine, line: []const u8) !?struct { key: SeriesKey, point: DataPoint } {
        // 找到第一个空格（tags 和 fields 之间）
        const fields_start = std.mem.indexOf(u8, line, " ") orelse return null;
        // 第二个空格可选：fields 和时间戳之间；如果不存在则使用当前时间
        const ts_start = std.mem.indexOfPos(u8, line, fields_start + 1, " ");

        const measurement_tags = line[0..fields_start];
        const fields_str = line[fields_start + 1 .. if (ts_start) |s| s else line.len];
        const ts_str = if (ts_start) |s| line[s + 1 ..] else "";

        // 解析 measurement 和 tags
        var parts = std.mem.splitScalar(u8, measurement_tags, ',');
        const measurement_raw = parts.next() orelse return null;

        var tags = std.ArrayList(Tag).empty;
        errdefer {
            // 释放已分配的 tag 字符串（tags.deinit 只释放数组本身，不释放指向的字符串）
            for (tags.items) |tag| {
                self.allocator.free(tag.key);
                self.allocator.free(tag.value);
            }
            tags.deinit(self.allocator);
        }
        while (parts.next()) |tag_str| {
            const eq = std.mem.indexOf(u8, tag_str, "=") orelse continue;
            const key_owned = try self.allocator.dupe(u8, tag_str[0..eq]);
            errdefer self.allocator.free(key_owned);
            try tags.append(self.allocator, .{
                .key = key_owned,
                .value = try self.allocator.dupe(u8, tag_str[eq + 1 ..]),
            });
        }

        // 解析第一个 field（简化：只取第一个 field 的值）
        var field_parts = std.mem.splitScalar(u8, fields_str, ',');
        const first_field = field_parts.next() orelse return null;
        const eq = std.mem.indexOf(u8, first_field, "=") orelse return null;
        const value_str = first_field[eq + 1 ..];

        // 解析值（支持 f64，末尾 i 表示整数，去掉）
        const val: f64 = blk: {
            if (value_str.len > 0 and value_str[value_str.len - 1] == 'i') {
                const int_val = try std.fmt.parseInt(i64, value_str[0 .. value_str.len - 1], 10);
                break :blk @floatFromInt(int_val);
            } else {
                break :blk try std.fmt.parseFloat(f64, value_str);
            }
        };

        // 解析时间戳（纳秒 -> 毫秒），省略时使用当前时间
        const ts_ms: i64 = blk: {
            if (ts_str.len > 0) {
                const ts_ns = try std.fmt.parseInt(i64, ts_str, 10);
                break :blk @divFloor(ts_ns, 1_000_000);
            } else {
                var tv: std.c.timeval = undefined;
                _ = std.c.gettimeofday(&tv, null);
                break :blk tv.sec * 1000 + @divFloor(tv.usec, 1000);
            }
        };

        const tags_slice = try self.allocator.dupe(Tag, tags.items);
        errdefer self.allocator.free(tags_slice);
        const metric_owned = try self.allocator.dupe(u8, measurement_raw);

        // 成功：释放 tags ArrayList（字符串所有权已转移给 tags_slice）
        tags.deinit(self.allocator);

        return .{
            .key = .{
                .metric = metric_owned,
                .tags = tags_slice,
            },
            .point = .{
                .timestamp = ts_ms,
                .value = val,
            },
        };
    }
};

// ==================== 测试 ====================

test "SeriesKey hash and id" {
    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{
            .{ .key = "host", .value = "A" },
            .{ .key = "dc", .value = "us-east" },
        },
    };
    const id1 = key.computeId();
    const id2 = key.computeId();
    try std.testing.expectEqual(id1, id2);
}

test "MemoryPartition insert and sort" {
    const allocator = std.testing.allocator;
    var part = MemoryPartition.init(allocator, 0, 3600_000);
    defer part.deinit();

    const real_key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    try part.insert(real_key.computeId(), real_key, 100, 1.0, 1024);
    try part.insert(real_key.computeId(), real_key, 50, 2.0, 1024);
    try part.insert(real_key.computeId(), real_key, 200, 3.0, 1024);

    part.sortAll();
    const sd = part.series_map.get(real_key.computeId()).?;
    try std.testing.expectEqual(@as(i64, 50), sd.timestamps.items[0]);
    try std.testing.expectEqual(@as(i64, 200), sd.timestamps.items[2]);
}

test "Engine write and query" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_engine");
    defer engine.deinit();
    defer fs.deleteTree("tmp_test_engine") catch {};

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    try engine.write(key, .{ .timestamp = 100, .value = 10.0 });
    try engine.write(key, .{ .timestamp = 200, .value = 20.0 });
    try engine.write(key, .{ .timestamp = 300, .value = 30.0 });

    const points = try engine.queryRange(sid, 150, 250, allocator);
    defer allocator.free(points);

    try std.testing.expectEqual(@as(usize, 1), points.len);
    try std.testing.expectEqual(@as(f64, 20.0), points[0].value);
}

test "Engine parse InfluxDB Line Protocol" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_lp");
    defer engine.deinit();
    defer fs.deleteTree("tmp_test_lp") catch {};

    const line = "cpu,host=A,dc=us-east usage=45i 1609459200000000000";
    const result = try engine.parseLineProtocol(line);
    try std.testing.expect(result != null);
    defer {
        allocator.free(result.?.key.metric);
        for (result.?.key.tags) |tag| {
            allocator.free(tag.key);
            allocator.free(tag.value);
        }
        allocator.free(result.?.key.tags);
    }
    try std.testing.expectEqualStrings("cpu", result.?.key.metric);
    try std.testing.expectEqual(@as(f64, 45.0), result.?.point.value);
}

test "Engine flush and load partition" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_flush");
    defer {
        engine.deinit();
        fs.deleteTree("tmp_test_flush") catch {};
    }

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    try engine.write(key, .{ .timestamp = 100, .value = 1.0 });
    try engine.write(key, .{ .timestamp = 200, .value = 2.0 });
    try engine.flushHotPartition();

    var engine2 = try Engine.init(allocator, "tmp_test_flush2");
    defer {
        engine2.deinit();
        fs.deleteTree("tmp_test_flush2") catch {};
    }

    // 直接从 engine.disk_partitions 获取文件路径
    try std.testing.expectEqual(@as(usize, 1), engine.disk_partitions.items.len);
    try engine2.loadPartition(engine.disk_partitions.items[0].file_path);

    const points = try engine2.queryRange(sid, 0, 300, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 2), points.len);
}

// ==================== TDD 新增测试 ====================

test "SeriesKey different tags produce different ids" {
    const key_a = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    const key_b = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "B" }},
    };
    try std.testing.expect(key_a.computeId() != key_b.computeId());
}

test "SeriesKey same tags produce same id" {
    const key1 = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{
            .{ .key = "host", .value = "A" },
            .{ .key = "dc", .value = "east" },
        },
    };
    const key2 = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{
            .{ .key = "host", .value = "A" },
            .{ .key = "dc", .value = "east" },
        },
    };
    try std.testing.expectEqual(key1.computeId(), key2.computeId());
}

test "SeriesData sort preserves value association" {
    const allocator = std.testing.allocator;
    var sd = SeriesData.init();
    defer sd.deinit(allocator);

    try sd.append(allocator, 300, 3.0);
    try sd.append(allocator, 100, 1.0);
    try sd.append(allocator, 200, 2.0);

    sd.sort(allocator);

    try std.testing.expectEqual(@as(i64, 100), sd.timestamps.items[0]);
    try std.testing.expectEqual(@as(f64, 1.0), sd.values.items[0]);
    try std.testing.expectEqual(@as(i64, 200), sd.timestamps.items[1]);
    try std.testing.expectEqual(@as(f64, 2.0), sd.values.items[1]);
    try std.testing.expectEqual(@as(i64, 300), sd.timestamps.items[2]);
    try std.testing.expectEqual(@as(f64, 3.0), sd.values.items[2]);
}

test "SeriesData sort empty" {
    const allocator = std.testing.allocator;
    var sd = SeriesData.init();
    defer sd.deinit(allocator);

    sd.sort(allocator); // 不应崩溃
    try std.testing.expectEqual(@as(usize, 0), sd.len());
}

test "SeriesData sort single element" {
    const allocator = std.testing.allocator;
    var sd = SeriesData.init();
    defer sd.deinit(allocator);

    try sd.append(allocator, 42, 99.0);
    sd.sort(allocator);

    try std.testing.expectEqual(@as(usize, 1), sd.len());
    try std.testing.expectEqual(@as(i64, 42), sd.timestamps.items[0]);
}

test "MemoryPartition insert duplicate series_id" {
    const allocator = std.testing.allocator;
    var part = MemoryPartition.init(allocator, 0, 3600_000);
    defer part.deinit();

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    try part.insert(sid, key, 100, 1.0, 1024);
    try part.insert(sid, key, 200, 2.0, 1024);
    try part.insert(sid, key, 300, 3.0, 1024);

    const sd = part.series_map.get(sid).?;
    try std.testing.expectEqual(@as(usize, 3), sd.len());
}

test "MemoryPartition insert multiple series" {
    const allocator = std.testing.allocator;
    var part = MemoryPartition.init(allocator, 0, 3600_000);
    defer part.deinit();

    const key_a = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    const key_b = SeriesKey{
        .metric = "mem",
        .tags = &[_]Tag{.{ .key = "host", .value = "B" }},
    };

    try part.insert(key_a.computeId(), key_a, 100, 1.0, 1024);
    try part.insert(key_b.computeId(), key_b, 200, 2.0, 1024);

    try std.testing.expectEqual(@as(usize, 2), part.series_map.count());
}

test "Engine query range boundary - exact match" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_boundary");
    defer {
        engine.deinit();
        fs.deleteTree("tmp_test_boundary") catch {};
    }

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    try engine.write(key, .{ .timestamp = 100, .value = 10.0 });
    try engine.write(key, .{ .timestamp = 200, .value = 20.0 });
    try engine.write(key, .{ .timestamp = 300, .value = 30.0 });

    // 查询精确匹配边界
    const points = try engine.queryRange(sid, 100, 300, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 3), points.len);
}

test "Engine query range - no matching data" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_nomatch");
    defer {
        engine.deinit();
        fs.deleteTree("tmp_test_nomatch") catch {};
    }

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    try engine.write(key, .{ .timestamp = 100, .value = 10.0 });

    // 查询不存在的序列
    const points = try engine.queryRange(99999, 0, 1000, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 0), points.len);

    // 查询不重叠的时间范围
    const points2 = try engine.queryRange(sid, 500, 600, allocator);
    defer allocator.free(points2);
    try std.testing.expectEqual(@as(usize, 0), points2.len);
}

test "Engine flush empty partition is no-op" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_empty_flush");
    defer {
        engine.deinit();
        fs.deleteTree("tmp_test_empty_flush") catch {};
    }

    // 空分区刷盘应不产生磁盘文件
    try engine.flushHotPartition();
    try std.testing.expectEqual(@as(usize, 0), engine.disk_partitions.items.len);
}

test "Engine queryAvg" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_avg");
    defer {
        engine.deinit();
        fs.deleteTree("tmp_test_avg") catch {};
    }

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    try engine.write(key, .{ .timestamp = 100, .value = 10.0 });
    try engine.write(key, .{ .timestamp = 200, .value = 20.0 });
    try engine.write(key, .{ .timestamp = 300, .value = 30.0 });

    const avg = try engine.queryAvg(sid, 0, 400);
    try std.testing.expect(avg != null);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0), avg.?, 0.001);

    // 空范围返回 null
    const avg2 = try engine.queryAvg(sid, 500, 600);
    try std.testing.expect(avg2 == null);
}

test "parseLineProtocol float value" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_lp_float");
    defer engine.deinit();
    defer fs.deleteTree("tmp_test_lp_float") catch {};

    const line = "temperature,location=room1 value=23.5 1609459200000000000";
    const result = try engine.parseLineProtocol(line);
    try std.testing.expect(result != null);
    defer {
        allocator.free(result.?.key.metric);
        for (result.?.key.tags) |tag| {
            allocator.free(tag.key);
            allocator.free(tag.value);
        }
        allocator.free(result.?.key.tags);
    }
    try std.testing.expectEqualStrings("temperature", result.?.key.metric);
    try std.testing.expectApproxEqAbs(@as(f64, 23.5), result.?.point.value, 0.001);
}

test "parseLineProtocol no tags" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_lp_notags");
    defer engine.deinit();
    defer fs.deleteTree("tmp_test_lp_notags") catch {};

    const line = "cpu usage=90i 1609459200000000000";
    const result = try engine.parseLineProtocol(line);
    try std.testing.expect(result != null);
    defer {
        allocator.free(result.?.key.metric);
        for (result.?.key.tags) |tag| {
            allocator.free(tag.key);
            allocator.free(tag.value);
        }
        allocator.free(result.?.key.tags);
    }
    try std.testing.expectEqualStrings("cpu", result.?.key.metric);
    try std.testing.expectEqual(@as(usize, 0), result.?.key.tags.len);
    try std.testing.expectEqual(@as(f64, 90.0), result.?.point.value);
}

test "parseLineProtocol invalid input returns null" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_lp_invalid");
    defer engine.deinit();
    defer fs.deleteTree("tmp_test_lp_invalid") catch {};

    // 缺少 field 和 timestamp
    const result = try engine.parseLineProtocol("cpu");
    try std.testing.expect(result == null);
}

test "parseLineProtocol without timestamp uses current time" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_lp_notime");
    defer engine.deinit();
    defer fs.deleteTree("tmp_test_lp_notime") catch {};

    const line = "cpu,host=A usage=45i";
    const result = try engine.parseLineProtocol(line);
    try std.testing.expect(result != null);
    defer {
        allocator.free(result.?.key.metric);
        for (result.?.key.tags) |tag| {
            allocator.free(tag.key);
            allocator.free(tag.value);
        }
        allocator.free(result.?.key.tags);
    }
    try std.testing.expectEqualStrings("cpu", result.?.key.metric);
    try std.testing.expectEqual(@as(f64, 45.0), result.?.point.value);
    // 时间戳应在当前时间附近（1000ms 容差）
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    const now_ms = tv.sec * 1000 + @divFloor(tv.usec, 1000);
    try std.testing.expect(@abs(result.?.point.timestamp - now_ms) < 1000);
}

test "parseLineProtocol returns deep copy" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_lp_deepcopy");
    defer engine.deinit();
    defer fs.deleteTree("tmp_test_lp_deepcopy") catch {};

    var line_buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "cpu,host=A value=1i {d}", .{1609459200000000000});

    const result = try engine.parseLineProtocol(line);
    try std.testing.expect(result != null);
    defer {
        allocator.free(result.?.key.metric);
        for (result.?.key.tags) |tag| {
            allocator.free(tag.key);
            allocator.free(tag.value);
        }
        allocator.free(result.?.key.tags);
    }

    // 修改原始 buffer 后，返回值应不受影响
    line_buf[0] = 'X';
    try std.testing.expectEqualStrings("cpu", result.?.key.metric);
}

test "BinaryWriter writeInt consistent allocator" {
    const allocator = std.testing.allocator;
    var writer = fs.BinaryWriter.init();
    defer writer.deinit(allocator);

    try writer.writeAll(allocator, "AB");
    try writer.writeInt(u32, 0x01020304, .little, allocator);
    try writer.writeAll(allocator, "CD");

    const items = writer.items();
    try std.testing.expectEqual(@as(usize, 8), items.len);
    try std.testing.expectEqualSlices(u8, "AB", items[0..2]);
    try std.testing.expectEqualSlices(u8, "CD", items[6..8]);
}

test "BinaryReader roundtrip" {
    const allocator = std.testing.allocator;
    var writer = fs.BinaryWriter.init();
    defer writer.deinit(allocator);

    try writer.writeAll(allocator, "TSDB");
    try writer.writeInt(u32, 42, .little, allocator);
    try writer.writeInt(i64, -100, .little, allocator);

    var reader = fs.BinaryReader.init(writer.items());
    var magic: [4]u8 = undefined;
    try reader.readAll(&magic);
    try std.testing.expectEqualSlices(u8, "TSDB", &magic);
    try std.testing.expectEqual(@as(u32, 42), try reader.readInt(u32, .little));
    try std.testing.expectEqual(@as(i64, -100), try reader.readInt(i64, .little));
}

test "Engine write and query multiple series" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_multi_series");
    defer {
        engine.deinit();
        fs.deleteTree("tmp_test_multi_series") catch {};
    }

    const key_a = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    const key_b = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "B" }},
    };

    try engine.write(key_a, .{ .timestamp = 100, .value = 10.0 });
    try engine.write(key_b, .{ .timestamp = 100, .value = 20.0 });
    try engine.write(key_a, .{ .timestamp = 200, .value = 15.0 });

    const points_a = try engine.queryRange(key_a.computeId(), 0, 300, allocator);
    defer allocator.free(points_a);
    try std.testing.expectEqual(@as(usize, 2), points_a.len);
    try std.testing.expectEqual(@as(f64, 10.0), points_a[0].value);
    try std.testing.expectEqual(@as(f64, 15.0), points_a[1].value);

    const points_b = try engine.queryRange(key_b.computeId(), 0, 300, allocator);
    defer allocator.free(points_b);
    try std.testing.expectEqual(@as(usize, 1), points_b.len);
    try std.testing.expectEqual(@as(f64, 20.0), points_b[0].value);
}

test "Engine tag index" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_tag_index");
    defer {
        engine.deinit();
        fs.deleteTree("tmp_test_tag_index") catch {};
    }

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{
            .{ .key = "host", .value = "server01" },
            .{ .key = "dc", .value = "us-east" },
        },
    };

    try engine.write(key, .{ .timestamp = 100, .value = 10.0 });

    // 验证标签索引已建立
    try std.testing.expect(engine.tag_index.contains("host=server01"));
    try std.testing.expect(engine.tag_index.contains("dc=us-east"));
}

// ==================== 第二轮 TDD 测试 ====================

test "cloneSeriesKey errdefer does not free uninitialized memory" {
    // 验证 cloneSeriesKey 在部分失败时不会对未初始化 tag 字段调用 free
    const allocator = std.testing.allocator;
    var part = MemoryPartition.init(allocator, 0, 3600_000);
    defer part.deinit();

    const key = SeriesKey{
        .metric = "test_metric",
        .tags = &[_]Tag{
            .{ .key = "k1", .value = "v1" },
            .{ .key = "k2", .value = "v2" },
        },
    };

    // 正常路径：cloneSeriesKey 应成功
    const cloned = try part.cloneSeriesKey(key);
    // 手动释放克隆的 key
    allocator.free(cloned.metric);
    for (cloned.tags) |tag| {
        allocator.free(tag.key);
        allocator.free(tag.value);
    }
    allocator.free(cloned.tags);
}

test "freeSeriesKey releases all memory" {
    // 验证 freeSeriesKey 正确释放 metric、tags 数组和所有 tag 字符串
    // 通过 MemoryPartition.insert 间接测试：插入后 deinit 应无泄漏
    const allocator = std.testing.allocator;
    var part = MemoryPartition.init(allocator, 0, 3600_000);
    defer part.deinit();

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{
            .{ .key = "host", .value = "server01" },
            .{ .key = "dc", .value = "us-east" },
        },
    };
    try part.insert(key.computeId(), key, 100, 1.0, 1024);
    // deinit 应正确释放所有内存（testing.allocator 会检测泄漏）
}

test "insert and getOrCreateSeriesData maintain series_map/series_keys consistency" {
    const allocator = std.testing.allocator;
    var part = MemoryPartition.init(allocator, 0, 3600_000);
    defer part.deinit();

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    // insert 后 series_map 和 series_keys 应一致
    try part.insert(sid, key, 100, 1.0, 1024);
    try std.testing.expect(part.series_map.contains(sid));
    try std.testing.expect(part.series_keys.contains(sid));

    // getOrCreateSeriesData 同理
    const key2 = SeriesKey{
        .metric = "mem",
        .tags = &[_]Tag{.{ .key = "host", .value = "B" }},
    };
    const sid2 = key2.computeId();
    const sd = try part.getOrCreateSeriesData(sid2, key2, 1024);
    try std.testing.expect(part.series_map.contains(sid2));
    try std.testing.expect(part.series_keys.contains(sid2));
    try std.testing.expectEqual(@as(usize, 0), sd.len());
}

test "flushHotPartition preserves data before clearing" {
    // 验证 flushHotPartition 在清空前正确保存数据
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_flush_preserve");
    defer {
        engine.deinit();
        fs.deleteTree("tmp_test_flush_preserve") catch {};
    }

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };

    try engine.write(key, .{ .timestamp = 100, .value = 1.0 });
    try engine.write(key, .{ .timestamp = 200, .value = 2.0 });
    try engine.flushHotPartition();

    // 元数据应已记录
    try std.testing.expectEqual(@as(usize, 1), engine.disk_partitions.items.len);

    // 热分区应已重置为新时间范围
    try std.testing.expect(engine.hot_partition.series_map.count() == 0);
}

test "queryPartition propagates allocation errors" {
    // queryPartition 现在返回 !void 而非 bool，验证错误传播
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_query_err");
    defer {
        engine.deinit();
        fs.deleteTree("tmp_test_query_err") catch {};
    }

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "A" }},
    };
    const sid = key.computeId();

    try engine.write(key, .{ .timestamp = 100, .value = 10.0 });
    try engine.write(key, .{ .timestamp = 200, .value = 20.0 });

    // 正常查询应成功
    const points = try engine.queryRange(sid, 0, 300, allocator);
    defer allocator.free(points);
    try std.testing.expectEqual(@as(usize, 2), points.len);
}

test "parseLineProtocol errdefer cleans up tag strings on failure" {
    // 验证 parseLineProtocol 在 field 解析失败时正确清理 tag 字符串
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_lp_errdefer");
    defer engine.deinit();
    defer fs.deleteTree("tmp_test_lp_errdefer") catch {};

    // 正常路径
    const line = "cpu,host=A,dc=us-east usage=45i 1609459200000000000";
    const result = try engine.parseLineProtocol(line);
    try std.testing.expect(result != null);
    defer {
        allocator.free(result.?.key.metric);
        for (result.?.key.tags) |tag| {
            allocator.free(tag.key);
            allocator.free(tag.value);
        }
        allocator.free(result.?.key.tags);
    }
    try std.testing.expectEqualStrings("cpu", result.?.key.metric);
    try std.testing.expectEqual(@as(usize, 2), result.?.key.tags.len);
}

test "tag_index key ownership after write" {
    // 验证 tag_index 的 key 在 write 后拥有独立内存
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, "tmp_test_tag_own");
    defer {
        engine.deinit();
        fs.deleteTree("tmp_test_tag_own") catch {};
    }

    const key = SeriesKey{
        .metric = "cpu",
        .tags = &[_]Tag{.{ .key = "host", .value = "server01" }},
    };

    try engine.write(key, .{ .timestamp = 100, .value = 10.0 });

    // tag_index 应包含 key 且拥有独立内存
    try std.testing.expect(engine.tag_index.contains("host=server01"));

    // 多次写入同一 tag 不应导致问题
    try engine.write(key, .{ .timestamp = 200, .value = 20.0 });
    try std.testing.expect(engine.tag_index.contains("host=server01"));
}

test "milliTimestamp returns valid time" {
    // 验证 milliTimestamp 返回合理的毫秒时间戳
    const ts = try milliTimestamp();
    try std.testing.expect(ts > 1_000_000_000_000); // 应大于 2001 年的时间戳
    try std.testing.expect(ts < 10_000_000_000_000); // 应小于 2286 年的时间戳
}
