const std = @import("std");

/// DataFusion C FFI 封装桩
/// 生产环境应链接 libdatafusion_ffi（Rust 导出 C ABI），
/// 并通过 @cImport 引入 C 头文件。
/// 此处提供会话上下文、SQL 解析和物理计划执行的接口签名。

pub const DFError = error{
    SqlParseError,
    ExecutionError,
    SchemaError,
};

/// DataFusion 会话上下文（不透明指针包装）
pub const DFSessionContext = opaque {};

/// 执行结果（不透明指针）
pub const DFRecordBatch = opaque {};

pub const DataFusionCtx = struct {
    /// 初始化 DataFusion 会话（桩）
    pub fn init() !*DFSessionContext {
        std.log.info("DataFusionCtx.init: stub (real impl requires libdatafusion_ffi)", .{});
        return @ptrCast(@constCast("stub"));
    }

    /// 注册内存表（桩）
    pub fn registerTable(_: *DFSessionContext, name: []const u8, schema: []const u8) !void {
        std.log.info("Register table '{s}' with schema {s} (stub)", .{ name, schema });
        return;
    }

    /// 执行 SQL 查询（桩）
    pub fn sql(_: *DFSessionContext, query: []const u8) DFError![]*DFRecordBatch {
        std.log.info("Execute SQL: {s} (stub)", .{query});
        return &[_]*DFRecordBatch{};
    }
};

/// 时序专用 UDF/UDAF 注册（桩）
pub const TimeSeriesUDFs = struct {
    pub fn registerGapFill(_: *DFSessionContext) !void {}
    pub fn registerRate(_: *DFSessionContext) !void {}
    pub fn registerDerivative(_: *DFSessionContext) !void {}
    pub fn registerDedup(_: *DFSessionContext) !void {}
};

test "DataFusion stub" {
    const ctx = try DataFusionCtx.init();
    try DataFusionCtx.registerTable(ctx, "metrics", "timestamp: int64, value: double");
    _ = try DataFusionCtx.sql(ctx, "SELECT * FROM metrics");
}
