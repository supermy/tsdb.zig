# TSDB.zig

一个使用 Zig 语言编写的高性能时序数据库（Time-Series Database）引擎，采用列式存储与 LSM-Tree 风格的分层架构，专为高吞吐写入与低延迟查询设计。

## 核心特性

- **列式存储**：每个时间序列独立维护时间戳数组与数值数组，缓存友好且便于向量化处理。
- **时间分区**：数据按小时（可配置）切分为内存热分区，避免全表扫描并支持高效 TTL 与归档。
- **LSM-like 分层**：热分区（内存）→ 刷盘生成不可变文件 → 后台 Compaction 合并去重。
- **InfluxDB Line Protocol**：内置行协议解析器，兼容现有采集端（Telegraf、Prometheus remote_write 等）。
- **标签索引**：自动构建 `key=value` 到序列 ID 的倒排索引，支持按标签过滤。
- **HTTP API**：提供 `/write`、`/query`、`/stats` 端点，便于集成到监控与告警系统。
- **Zig 0.16 原生兼容**：完全基于 Zig 0.16.0 标准库，无外部依赖。

## 架构概览

```
┌─────────────────────────────────────────┐
│           Ingestion (Line Protocol)      │
├─────────────────────────────────────────┤
│  Hot Partition (Memory, Columnar)        │
│  ├── SeriesMap: series_id → timestamps[] │
│  └── SeriesMap: series_id → values[]     │
├─────────────────────────────────────────┤
│  Read-only Partitions (Memory)           │
├─────────────────────────────────────────┤
│  Disk Partitions (Immutable Files)       │
│  └── Binary Format: header + series blocks
├─────────────────────────────────────────┤
│  Compactor (Merge & Deduplicate)         │
└─────────────────────────────────────────┘
```

### 存储格式

磁盘分区采用自定义二进制格式：
- **Magic**: `TSDB` (4 bytes)
- **Version**: `1` (u32 little-endian)
- **Header**: 起始时间、结束时间、序列数量、总点数
- **Series Blocks**: 每个序列包含 metric、tags、timestamps[]、values[]

## 快速开始

### 环境要求

- [Zig](https://ziglang.org/) 0.16.0
- macOS / Linux / Windows (POSIX 兼容环境)

### 构建

```bash
zig build
```

### 运行测试

```bash
zig build test
```

### 运行基准测试

```bash
zig build bench
```

示例输出：

```
=== TSDB.zig Performance Benchmark ===

Write Throughput:
  Points written: 100000
  Elapsed: 691.20 ms
  Throughput: 144676 points/sec

Query Latency:
  Queries: 1000
  Range: 10,000 points per query
  Avg latency: 425.37 us

Memory Partition Sort:
  Points: 1000000
  Elapsed: 262.42 ms
  Sorted: true
```

## CLI 用法

```bash
# 启动 HTTP 服务（默认端口 8080）
zig build run -- serve 8080

# 写入单条数据
zig build run -- write "cpu,host=server01 value=42.0"

# 查询序列范围
zig build run -- query <series_id> <start_ms> <end_ms>

# 手动刷盘
zig build run -- flush
```

## HTTP API

### 写入数据

```bash
curl -X POST http://localhost:8080/write \
  -d 'cpu_usage,host=server01,dc=us-east value=75.2 1699123200000'
```

### 查询数据

```bash
curl -X POST http://localhost:8080/query \
  -d '{"series_id": 123456, "start": 1699123200000, "end": 1699126800000}'
```

### 服务状态

```bash
curl http://localhost:8080/stats
```

## 项目结构

```
.
├── build.zig              # 构建配置（含 test / bench / run）
├── src/
│   ├── tsdb.zig           # 核心引擎：Engine、MemoryPartition、SeriesData
│   ├── main.zig           # CLI 入口
│   ├── server.zig         # HTTP API Server
│   ├── compaction.zig     # 分区合并与去重
│   ├── fs_helper.zig      # POSIX 文件系统封装（Zig 0.16 兼容）
│   ├── fdap/
│   │   └── optimizer.zig  # 查询优化器（FDAP）
│   └── ffi/
│       ├── arrow.zig      # Arrow FFI 接口
│       ├── datafusion.zig # DataFusion 集成
│       └── parquet.zig    # Parquet 读写支持
├── tests/
│   ├── integration.zig    # 端到端集成测试
│   └── benchmark.zig      # 性能基准测试
└── TODOS.md               # 开发计划
```

## 核心数据类型

### DataPoint

```zig
const DataPoint = struct {
    timestamp: i64, // 毫秒时间戳
    value: f64,
};
```

### SeriesKey

```zig
const SeriesKey = struct {
    metric: []const u8,
    tags: []const Tag,
};
```

系列 ID 由 `metric + tags` 的 Wyhash 哈希值确定。

### Engine

```zig
var engine = try tsdb.Engine.init(allocator, "data");
defer engine.deinit();

// 写入
try engine.write(key, .{ .timestamp = 1699123200000, .value = 42.0 });

// 查询
const points = try engine.queryRange(sid, start, end, allocator);
defer allocator.free(points);
```

## 技术细节

### 内存管理

- 所有动态分配均通过传入的 `std.mem.Allocator` 进行，便于测试注入检测分配器。
- `SeriesKey` 与 `Tag` 字符串在插入分区时进行深拷贝，确保分区拥有独立所有权。
- `Engine.deinit` 会级联释放所有分区、索引与目录路径内存。
- 所有关键路径均使用 `errdefer` 确保部分分配失败时的内存正确回收，避免泄漏。
- `cloneSeriesKey` 使用逐字段 errdefer，避免对未初始化内存调用 `free`（未定义行为防护）。

### 并发安全

- `Engine` 内部使用自旋锁（`std.atomic.Mutex` 包装器）保护热分区与索引。
- 查询路径在读取磁盘分区时不上锁，磁盘分区为不可变结构，天然线程安全。

### 兼容性说明

本项目针对 Zig 0.16.0 的 API 变化做了以下适配：
- 使用 `std.c.gettimeofday` 替代已移除的 `std.time.milliTimestamp`
- 使用 `std.Io.File.writeStreamingAll` 替代已移除的 `std.io.getStdOut().writeAll`
- 使用 `std.process.Init` 替代已移除的 `std.process.argsAlloc`
- 使用 `std.heap.page_allocator` 替代已移除的 `std.heap.GeneralPurposeAllocator`
- 自定义 `fs_helper.zig` 封装 POSIX 文件操作，绕过 `std.fs` 的 API 变更

## 路线图

- [ ] Parquet 格式持久化
- [ ] DataFusion / Arrow 查询层集成
- [ ] FDAP 查询优化器（谓词下推、列裁剪）
- [ ] WAL（Write-Ahead Log）保证崩溃安全
- [ ] 多线程 Compaction
- [ ] 分布式分片（Sharding）

## License

MIT
