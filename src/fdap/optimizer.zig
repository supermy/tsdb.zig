const std = @import("std");

/// DataFusion 物理优化器规则注册（Zig 实现）
/// 生产环境通过 DataFusion 的扩展机制注册自定义规则，
/// 此处提供时间范围剪枝（Partition Pruning）的参考实现逻辑。

pub const PartitionMeta = struct { start: i64, end: i64, path: []const u8 };

/// 分区剪剪器：根据查询时间范围，筛选出需要扫描的磁盘分区
pub const PartitionPruner = struct {
    pub fn prunePartitions(
        partition_metas: []const PartitionMeta,
        query_start: i64,
        query_end: i64,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        var result = std.ArrayList([]const u8).empty;
        errdefer {
            for (result.items) |p| allocator.free(p);
            result.deinit(allocator);
        }

        for (partition_metas) |meta| {
            // 分区与查询范围相交则保留
            if (meta.end >= query_start and meta.start <= query_end) {
                try result.append(allocator, try allocator.dupe(u8, meta.path));
            }
        }
        return result.toOwnedSlice(allocator);
    }
};

/// 谓词下推检查器：验证 DataFusion 计划是否包含对时间戳的下推过滤
pub const PredicatePushdownChecker = struct {
    pub fn hasTimestampFilter(plan: []const u8) bool {
        // 简化：检查计划字符串中是否包含时间戳过滤表达式
        return std.mem.indexOf(u8, plan, "timestamp >=") != null or
            std.mem.indexOf(u8, plan, "timestamp >") != null;
    }
};

test "PartitionPruner" {
    const allocator = std.testing.allocator;
    const metas = &[_]PartitionMeta{
        .{ .start = 0, .end = 100, .path = "p0" },
        .{ .start = 100, .end = 200, .path = "p1" },
        .{ .start = 200, .end = 300, .path = "p2" },
    };

    const paths = try PartitionPruner.prunePartitions(metas, 150, 250, allocator);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }

    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("p1", paths[0]);
    try std.testing.expectEqualStrings("p2", paths[1]);
}

test "PredicatePushdownChecker" {
    try std.testing.expect(PredicatePushdownChecker.hasTimestampFilter("Filter: timestamp >= 100"));
    try std.testing.expect(!PredicatePushdownChecker.hasTimestampFilter("Project: *"));
}
