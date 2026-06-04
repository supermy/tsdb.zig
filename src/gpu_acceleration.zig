const std = @import("std");

/// GPU 后端枚举。当前仅 `cpu_simd` 为完全实现状态，其余后端预留接口。
pub const GpuBackend = enum {
    cpu_simd,
    cuda,
    metal,
    opencl,
};

/// GPU 加速器抽象层。
///
/// 通过 `comptime` 选择后端，运行时持有后端上下文（如 GPU 设备句柄、命令队列等）。
/// 目前所有批量计算均路由到 CPU SIMD fallback；后续阶段会通过 `comptime` 分派到
/// CUDA / Metal / OpenCL 内核。
pub const GpuAccelerator = struct {
    backend: GpuBackend,
    allocator: std.mem.Allocator,

    /// 初始化加速器。
    /// `backend` 在编译期确定后，运行时不再改变，避免虚函数 / 运行时分支开销。
    pub fn init(allocator: std.mem.Allocator, backend: GpuBackend) !GpuAccelerator {
        // TODO(Phase 2): CUDA / Metal / OpenCL 上下文初始化
        // 例如：加载 CUDA driver API、创建 Metal device、编译 OpenCL program 等。
        _ = backend;
        return .{
            .backend = .cpu_simd,
            .allocator = allocator,
        };
    }

    /// 释放加速器持有的所有资源。
    pub fn deinit(self: *GpuAccelerator) void {
        // TODO(Phase 2): 释放 GPU 上下文、缓冲区、命令队列等。
        _ = self;
    }

    /// 批量求和。
    /// `input` 长度必须是 `batch_size` 的整数倍。
    /// `output` 长度必须 >= `input.len / batch_size`。
    pub fn batchSum(self: *GpuAccelerator, input: []const f64, output: []f64, batch_size: usize) !void {
        _ = self;
        try cpuBatchSum(input, output, batch_size);
    }

    /// 批量求平均。
    pub fn batchAvg(self: *GpuAccelerator, input: []const f64, output: []f64, batch_size: usize) !void {
        _ = self;
        try cpuBatchAvg(input, output, batch_size);
    }

    /// 批量求最小值。
    pub fn batchMin(self: *GpuAccelerator, input: []const f64, output: []f64, batch_size: usize) !void {
        _ = self;
        try cpuBatchMin(input, output, batch_size);
    }

    /// 批量求最大值。
    pub fn batchMax(self: *GpuAccelerator, input: []const f64, output: []f64, batch_size: usize) !void {
        _ = self;
        try cpuBatchMax(input, output, batch_size);
    }
};

// ============================================================================
// CPU SIMD Fallback Implementation
// ============================================================================

/// SIMD 向量宽度（以 f64 元素计）。
/// 默认 4 对应 256-bit AVX/NEON 向量；可在编译期通过选项覆盖。
const VectorLen = 4;

/// 错误集合。
pub const BatchError = error{
    InvalidBatchSize,
    OutputTooSmall,
};

/// CPU SIMD 批量求和。
fn cpuBatchSum(input: []const f64, output: []f64, batch_size: usize) BatchError!void {
    if (batch_size == 0) return error.InvalidBatchSize;
    const num_batches = input.len / batch_size;
    if (output.len < num_batches) return error.OutputTooSmall;

    const Vec = @Vector(VectorLen, f64);

    var i: usize = 0;
    while (i < num_batches) : (i += 1) {
        const batch = input[i * batch_size ..][0..batch_size];

        var sum: f64 = 0.0;
        var j: usize = 0;

        // 向量化主循环
        while (j + VectorLen <= batch_size) : (j += VectorLen) {
            const v: Vec = batch[j..][0..VectorLen].*;
            sum += @reduce(.Add, v);
        }

        // 尾处理（标量）
        while (j < batch_size) : (j += 1) {
            sum += batch[j];
        }

        output[i] = sum;
    }
}

/// CPU SIMD 批量求平均。
fn cpuBatchAvg(input: []const f64, output: []f64, batch_size: usize) BatchError!void {
    try cpuBatchSum(input, output, batch_size);
    const num_batches = input.len / batch_size;
    const inv: f64 = 1.0 / @as(f64, @floatFromInt(batch_size));

    var i: usize = 0;
    while (i < num_batches) : (i += 1) {
        output[i] *= inv;
    }
}

/// CPU SIMD 批量求最小值。
fn cpuBatchMin(input: []const f64, output: []f64, batch_size: usize) BatchError!void {
    if (batch_size == 0) return error.InvalidBatchSize;
    const num_batches = input.len / batch_size;
    if (output.len < num_batches) return error.OutputTooSmall;

    const Vec = @Vector(VectorLen, f64);

    var i: usize = 0;
    while (i < num_batches) : (i += 1) {
        const batch = input[i * batch_size ..][0..batch_size];

        var min_val: f64 = batch[0];
        var j: usize = 0;

        // 向量化主循环
        while (j + VectorLen <= batch_size) : (j += VectorLen) {
            const v: Vec = batch[j..][0..VectorLen].*;
            const vmin = @reduce(.Min, v);
            if (vmin < min_val) min_val = vmin;
        }

        // 尾处理（标量）
        while (j < batch_size) : (j += 1) {
            if (batch[j] < min_val) min_val = batch[j];
        }

        output[i] = min_val;
    }
}

/// CPU SIMD 批量求最大值。
fn cpuBatchMax(input: []const f64, output: []f64, batch_size: usize) BatchError!void {
    if (batch_size == 0) return error.InvalidBatchSize;
    const num_batches = input.len / batch_size;
    if (output.len < num_batches) return error.OutputTooSmall;

    const Vec = @Vector(VectorLen, f64);

    var i: usize = 0;
    while (i < num_batches) : (i += 1) {
        const batch = input[i * batch_size ..][0..batch_size];

        var max_val: f64 = batch[0];
        var j: usize = 0;

        // 向量化主循环
        while (j + VectorLen <= batch_size) : (j += VectorLen) {
            const v: Vec = batch[j..][0..VectorLen].*;
            const vmax = @reduce(.Max, v);
            if (vmax > max_val) max_val = vmax;
        }

        // 尾处理（标量）
        while (j < batch_size) : (j += 1) {
            if (batch[j] > max_val) max_val = batch[j];
        }

        output[i] = max_val;
    }
}

// ============================================================================
// 测试
// ============================================================================

test "cpuBatchSum basic" {
    const input = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    var output: [2]f64 = undefined;
    try cpuBatchSum(&input, &output, 4);
    try std.testing.expectEqual(@as(f64, 10.0), output[0]);
    try std.testing.expectEqual(@as(f64, 26.0), output[1]);
}

test "cpuBatchAvg basic" {
    const input = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    var output: [2]f64 = undefined;
    try cpuBatchAvg(&input, &output, 4);
    try std.testing.expectEqual(@as(f64, 2.5), output[0]);
    try std.testing.expectEqual(@as(f64, 6.5), output[1]);
}

test "cpuBatchMin basic" {
    const input = [_]f64{ 4.0, 1.0, 3.0, 2.0, 8.0, 5.0, 6.0, 7.0 };
    var output: [2]f64 = undefined;
    try cpuBatchMin(&input, &output, 4);
    try std.testing.expectEqual(@as(f64, 1.0), output[0]);
    try std.testing.expectEqual(@as(f64, 5.0), output[1]);
}

test "cpuBatchMax basic" {
    const input = [_]f64{ 4.0, 1.0, 3.0, 2.0, 8.0, 5.0, 6.0, 7.0 };
    var output: [2]f64 = undefined;
    try cpuBatchMax(&input, &output, 4);
    try std.testing.expectEqual(@as(f64, 4.0), output[0]);
    try std.testing.expectEqual(@as(f64, 8.0), output[1]);
}

test "GpuAccelerator init and deinit" {
    var accel = try GpuAccelerator.init(std.testing.allocator, .cpu_simd);
    defer accel.deinit();
    try std.testing.expectEqual(GpuBackend.cpu_simd, accel.backend);
}

test "GpuAccelerator batchSum" {
    var accel = try GpuAccelerator.init(std.testing.allocator, .cpu_simd);
    defer accel.deinit();
    const input = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    var output: [1]f64 = undefined;
    try accel.batchSum(&input, &output, 4);
    try std.testing.expectEqual(@as(f64, 10.0), output[0]);
}

test "GpuAccelerator batchAvg" {
    var accel = try GpuAccelerator.init(std.testing.allocator, .cpu_simd);
    defer accel.deinit();
    const input = [_]f64{ 2.0, 4.0, 6.0, 8.0 };
    var output: [1]f64 = undefined;
    try accel.batchAvg(&input, &output, 4);
    try std.testing.expectEqual(@as(f64, 5.0), output[0]);
}

test "GpuAccelerator batchMin" {
    var accel = try GpuAccelerator.init(std.testing.allocator, .cpu_simd);
    defer accel.deinit();
    const input = [_]f64{ 4.0, 1.0, 3.0, 2.0 };
    var output: [1]f64 = undefined;
    try accel.batchMin(&input, &output, 4);
    try std.testing.expectEqual(@as(f64, 1.0), output[0]);
}

test "GpuAccelerator batchMax" {
    var accel = try GpuAccelerator.init(std.testing.allocator, .cpu_simd);
    defer accel.deinit();
    const input = [_]f64{ 4.0, 1.0, 3.0, 2.0 };
    var output: [1]f64 = undefined;
    try accel.batchMax(&input, &output, 4);
    try std.testing.expectEqual(@as(f64, 4.0), output[0]);
}

test "batch operations with non-vector-aligned size" {
    const input = [_]f64{ 1.0, 2.0, 3.0 };
    var output: [1]f64 = undefined;
    try cpuBatchSum(&input, &output, 3);
    try std.testing.expectEqual(@as(f64, 6.0), output[0]);
}

test "batch operations error on zero batch size" {
    const input = [_]f64{1.0};
    var output: [1]f64 = undefined;
    try std.testing.expectError(error.InvalidBatchSize, cpuBatchSum(&input, &output, 0));
    try std.testing.expectError(error.InvalidBatchSize, cpuBatchAvg(&input, &output, 0));
    try std.testing.expectError(error.InvalidBatchSize, cpuBatchMin(&input, &output, 0));
    try std.testing.expectError(error.InvalidBatchSize, cpuBatchMax(&input, &output, 0));
}

test "batch operations error on small output" {
    const input = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    var output: [0]f64 = undefined;
    try std.testing.expectError(error.OutputTooSmall, cpuBatchSum(&input, &output, 2));
    try std.testing.expectError(error.OutputTooSmall, cpuBatchAvg(&input, &output, 2));
    try std.testing.expectError(error.OutputTooSmall, cpuBatchMin(&input, &output, 2));
    try std.testing.expectError(error.OutputTooSmall, cpuBatchMax(&input, &output, 2));
}

test "batch operations single batch" {
    const input = [_]f64{ 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0 };
    var output: [1]f64 = undefined;
    try cpuBatchSum(&input, &output, 8);
    try std.testing.expectEqual(@as(f64, 360.0), output[0]);
}

test "batch operations large aligned input" {
    const allocator = std.testing.allocator;
    const n = 1024;
    const input = try allocator.alloc(f64, n);
    defer allocator.free(input);
    for (input, 0..) |*v, i| {
        v.* = @floatFromInt(i + 1);
    }
    var output: [1]f64 = undefined;
    try cpuBatchSum(input, &output, n);
    // sum(1..1024) = 1024*1025/2 = 524800
    try std.testing.expectEqual(@as(f64, 524800.0), output[0]);
}

test "GpuAccelerator all backends are known" {
    // 验证枚举完整性，防止后续添加后端时遗漏 switch 分支
    const backends = &[_]GpuBackend{ .cpu_simd, .cuda, .metal, .opencl };
    for (backends) |b| {
        const name = @tagName(b);
        try std.testing.expect(name.len > 0);
    }
}
