# TSDB.zig

一个使用 Zig 语言编写的高性能时序数据库（Time-Series Database）引擎，采用列式存储与 LSM-Tree 风格的分层架构，专为高吞吐写入与低延迟查询设计。

## 核心特性

- **列式存储**：每个时间序列独立维护时间戳数组与数值数组，缓存友好且便于向量化处理。
- **时间分区**：数据按小时（可配置）切分为内存热分区，避免全表扫描并支持高效 TTL 与归档。
- **LSM-like 分层**：热分区（内存）→ 刷盘生成不可变文件 → 后台 Compaction 合并去重。
- **InfluxDB Line Protocol**：内置行协议解析器，兼容现有采集端（Telegraf、Prometheus remote_write 等）。时间戳可选，省略时自动使用服务器当前时间。
- **标签索引**：自动构建 `key=value` 到序列 ID 的倒排索引，支持按标签过滤。
- **NNG 高性能 API**：基于 NNG (Nanomsg Next Generation) 的 req/rep 模式，提供 `write`、`query`、`stats` 命令。
- **内嵌 Web 测试页面**：启动服务后自动提供类似 llama-server 的默认测试页面（`http://localhost:port+1`）。
- **GPU 加速抽象层**：可插拔后端设计（CUDA / Metal / OpenCL），默认 CPU SIMD fallback。
- **Zig 0.16 原生兼容**：完全基于 Zig 0.16.0 标准库，无外部依赖（除 NNG 库外）。

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

## 接口测试命令

以下命令使用 `curl` 对 HTTP API 进行端到端测试，无需浏览器：

```bash
# 1. 启动服务（带详细日志）
./tsdb serve 8080 -v

# 2. 单条写入
curl -s -X POST http://localhost:8081/api/write \
  -d 'cpu,host=server01,region=us-west usage=42.5 1609459200000000000'
# 响应：{"status":"ok","written":1,"series_id":"1273906692725521564"}

# 3. 按 series_id 查询
curl -s "http://localhost:8081/api/query?series_id=1273906692725521564&start=0&end=9999999999999999999"
# 响应：{"status":"ok","points":[{"ts":1609459200000,"v":42.500000,"metric":"cpu","tags":"host=server01,region=us-west","series_id":"1273906692725521564"}]}

# 4. 按 metric 名查询（跨所有序列）
curl -s "http://localhost:8081/api/query_metric?metric=cpu&start=0&end=9999999999999999999"

# 5. 手动落盘
curl -s -X POST http://localhost:8081/api/flush
# 响应：{"status":"ok","msg":"flushed"}

# 6. 导出全部数据（InfluxDB Line Protocol 格式）
curl -s "http://localhost:8081/api/export"
# 响应：cpu,host=server01,region=us-west value=42.5 1609459200000000000

# 7. 批量写入（多行 Line Protocol）
curl -s -X POST http://localhost:8081/api/write \
  --data-binary @data.txt \
  -H "Content-Type: text/plain"

# 8. 获取服务统计
curl -s "http://localhost:8081/api/stats"
# 响应：{"status":"ok","hot_partition_series":1,"hot_partition_points":1,"readonly_partitions":0,"disk_partitions":1}
```

## 快速开始

### 环境要求

- [Zig](https://ziglang.org/) 0.16.0
- [NNG](https://nng.nanomsg.org/) 1.11+ (用于高性能 API 服务)
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

示例输出（ReleaseFast 模式）：

```
=== TSDB.zig Performance Benchmark ===

Write Throughput (Single Point):
  Points written: 100000
  Elapsed: 11.25 ms
  Throughput: 8889679 points/sec

Write Throughput (Batch, 1 series):
  Points written: 100000
  Elapsed: 12.75 ms
  Throughput: 7846214 points/sec

Write Throughput (Multi Series, 100 series x 1000 pts):
  Points written: 100000
  Elapsed: 14.88 ms
  Throughput: 6719978 points/sec

Query Latency:
  Queries: 1000
  Range: 10,000 points per query
  Avg latency: 421.44 us

Memory Partition Sort:
  Points: 1000000
  Elapsed: 181.82 ms
  Sorted: true
```

## CLI 用法

```bash
# 启动 NNG 服务（默认端口 8080，HTTP 测试页面在 8081）
./tsdb serve 8080

# 启用详细日志（显示每次写入、查询、落盘信息）
./tsdb serve 8080 -v
./tsdb serve --verbose
```
# 通过 NNG 写入单条数据（时间戳可选，省略时使用当前时间）
./tsdb nngwrite "tcp://127.0.0.1:8080" "cpu,host=server01 value=42.0"

# 通过 NNG 写入带时间戳的数据（纳秒级时间戳）
./tsdb nngwrite "tcp://127.0.0.1:8080" "cpu,host=server01 value=42.0 1609459200000000000"

# 通过 NNG 查询序列范围
./tsdb nngquery "tcp://127.0.0.1:8080" <series_id> <start_ms> <end_ms>

# 通过 NNG 获取统计
./tsdb nngstats "tcp://127.0.0.1:8080"

# 本地写入（直接操作数据文件）
./tsdb write "cpu,host=server01 value=42.0"

# 本地查询
./tsdb query <series_id> <start_ms> <end_ms>

# 手动刷盘
./tsdb flush

# 合并分区
./tsdb compact
```

## API 接口

### NNG Req/Rep 接口（高性能）

NNG 服务使用 JSON 消息格式：

**写入数据**
```bash
echo '{"cmd":"write","data":"cpu_usage,host=server01,dc=us-east value=75.2 1699123200000"}' | nng req tcp://127.0.0.1:8080
```

**查询数据**
```bash
echo '{"cmd":"query","series_id":123456,"start":1699123200000,"end":1699126800000}' | nng req tcp://127.0.0.1:8080
```

**服务状态**
```bash
echo '{"cmd":"stats"}' | nng req tcp://127.0.0.1:8080
```

### HTTP 测试接口（Web UI）

启动服务后，浏览器访问 `http://localhost:8081`（假设 NNG 端口为 8080）：

- `GET /` 或 `GET /index.html` → 内嵌测试页面（单页应用）
- `POST /api/write` → 写入数据（body 为 line protocol）
- `GET /api/query?series_id=...&start=...&end=...` → 按序列 ID 查询
- `GET /api/query_metric?metric=...&start=...&end=...` → 按指标名查询（跨所有序列）
- `GET /api/export` → 导出全部数据（InfluxDB Line Protocol 格式）
- `GET /api/stats` → 服务器统计

**查询响应格式**（包含 metric、tags、series_id）：
```json
{
  "status": "ok",
  "points": [
    {
      "ts": 1609459200000,
      "v": 42.500000,
      "metric": "cpu",
      "tags": "host=server01,region=us-west",
      "series_id": "1273906692725521564"
    }
  ]
}
```

Web UI 功能：
- **单条写入测试**：支持手动输入 Line Protocol，或点击预设示例（CPU / 内存 / 温度）
- **快速单点写入**：通过 Metric、Tags、Value、Timestamp 表单快速构建并发送
- **批量写入测试**：生成模拟数据（指定序列数、每序列点数、时间范围），逐行批量写入，实时显示进度与吞吐
- **数据导入**：支持拖拽上传 `.txt` / `.csv` 文件，解析并批量写入
- **数据导出**：查询结果可导出为 JSON / CSV / InfluxDB Line Protocol；支持全部数据导出为 `.lp` 文件
- **查询可视化**：Canvas 折线图 + 数据表格（显示 Timestamp / Metric / Tags / Value），支持暗色/亮色模式
- **性能监控**：实时写入/查询延迟柱状图与 Min/Avg/Max 统计

## GPU 加速

TSDB.zig 提供可插拔的 GPU 加速抽象层，支持以下后端：

| 后端 | 状态 | 说明 |
|------|------|------|
| CPU SIMD | ✅ 可用 | Zig `@Vector` 实现的 fallback，零外部依赖 |
| CUDA | 🚧 预留 | 通过 ` GpuBackend.cuda ` 编译时选择 |
| Metal | 🚧 预留 | macOS / iOS GPU 加速 |
| OpenCL | 🚧 预留 | 跨平台 GPU 加速 |

适用场景：
- 大规模并行聚合（SUM / AVG / MIN / MAX）
- 向量化范围扫描
- 数据压缩/解压
- 实时异常检测

详见 [docs/GPU_ACCELERATION.md](docs/GPU_ACCELERATION.md)。

## 项目结构

```
.
├── build.zig              # 构建配置（含 test / bench / run）
├── src/
│   ├── tsdb.zig           # 核心引擎：Engine、MemoryPartition、SeriesData
│   ├── main.zig           # CLI 入口
│   ├── server.zig         # NNG API Server + HTTP 测试页面服务
│   ├── http_server.zig    # POSIX socket 极简 HTTP 服务器
│   ├── nng.zig            # NNG C 绑定
│   ├── gpu_acceleration.zig # GPU 加速抽象层
│   ├── compaction.zig     # 分区合并与去重
│   ├── fs_helper.zig      # POSIX 文件系统封装（Zig 0.16 兼容）
│   ├── fdap/
│   │   └── optimizer.zig  # 查询优化器（FDAP）
│   └── ffi/
│       ├── arrow.zig      # Arrow FFI 接口
│       ├── datafusion.zig # DataFusion 集成
│       └── parquet.zig    # Parquet 读写支持
├── webui/
│   └── index.html         # 默认测试页面（单页应用）
├── tests/
│   ├── integration.zig    # 端到端集成测试
│   └── benchmark.zig      # 性能基准测试
├── docs/
│   └── GPU_ACCELERATION.md # GPU 加速设计文档
├── README.md
├── CHANGELOG.md
└── TODOS.md               # 开发计划
```

## 核心数据类型

### DataPoint / DataPointEx

```zig
const DataPoint = struct {
    timestamp: i64, // 毫秒时间戳
    value: f64,
};

const DataPointEx = struct {
    timestamp: i64,
    value: f64,
    series_id: u64,
    metric: []const u8,
    tags: []const Tag,
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

// 单点写入
try engine.write(key, .{ .timestamp = 1699123200000, .value = 42.0 });

// 批量写入（同序列，单次锁保护，性能更优）
var points = try allocator.alloc(tsdb.DataPoint, 1000);
// ... fill points ...
try engine.writeBatch(key, points);

// 查询（基础版：仅返回 ts + value）
const points = try engine.queryRange(sid, start, end, allocator);
defer allocator.free(points);

// 增强查询（返回带 metric/tags/series_id 的数据）
const pointsEx = try engine.queryRangeEx(sid, start, end, allocator);
defer allocator.free(pointsEx);

// 按指标名查询（跨所有序列）
const metricPoints = try engine.queryByMetricEx("cpu", start, end, allocator);
defer allocator.free(metricPoints);
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
- NNG 服务器与 HTTP 测试服务器运行在不同线程中，均通过 Engine 的锁保证并发安全。

### GPU 加速

- 通过 `GpuAccelerator` 结构体提供统一接口，`comptime` 选择后端。
- CPU SIMD fallback 使用 Zig `@Vector(4, f64)` 配合 `@reduce` 实现向量化主循环。
- 预留 CUDA / Metal / OpenCL 扩展路径，未来可通过 `build.zig` 条件编译切换。

### 兼容性说明

本项目针对 Zig 0.16.0 的 API 变化做了以下适配：
- 使用 `std.c.gettimeofday` 替代已移除的 `std.time.milliTimestamp`
- 使用 `std.Io.File.writeStreamingAll` 替代已移除的 `std.io.getStdOut().writeAll`
- 使用 `std.process.Init` 替代已移除的 `std.process.argsAlloc`
- 使用 `std.heap.page_allocator` 替代已移除的 `std.heap.GeneralPurposeAllocator`
- 自定义 `fs_helper.zig` 封装 POSIX 文件操作，绕过 `std.fs` 的 API 变更
- 使用 POSIX socket 实现 HTTP 服务器（`std.net` 已移除）

## CI/CD

本项目使用 GitHub Actions 实现自动化流水线，配置位于 `.github/workflows/ci.yml`：

| 阶段 | 说明 |
|------|------|
| **Lint** | `zig fmt --check` 代码格式检查 |
| **Test** | Ubuntu / macOS 双平台运行 `zig build test` 与基准测试 |
| **Build** | 交叉编译：`x86_64-linux-gnu`、`aarch64-macos-none`、`x86_64-macos-none` |
| **Release** | 推送 `v*` 标签时自动创建 GitHub Release 并上传多平台二进制 |

## 路线图

- [ ] Parquet 格式持久化
- [ ] DataFusion / Arrow 查询层集成
- [ ] FDAP 查询优化器（谓词下推、列裁剪）
- [ ] WAL（Write-Ahead Log）保证崩溃安全
- [ ] 多线程 Compaction
- [ ] 分布式分片（Sharding）
- [ ] CUDA / Metal / OpenCL GPU 后端实现

## License

MIT
