# Changelog

所有重要变更均记录于此文件，格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

## [Unreleased]

### Added
- **libevent 优化 HTTP 服务**：将 POSIX socket 阻塞式单连接模型替换为 libevent evhttp 事件驱动模型，支持高并发连接与 Keep-Alive。

### Fixed
- `handleHttpExport` 未加锁导致的数据竞争问题。
- 查询响应缓冲区过小（512 字节）导致的栈溢出风险，扩容至 1536 字节。
- URI 长度未校验导致的栈缓冲区溢出风险，限制最大 2048 字节。

## [0.2.0] - 2025-06-05

### Added
- 实现完整时序数据库引擎核心（`Engine`、`MemoryPartition`、`SeriesData`）。
- 列式存储：每个序列独立维护 `timestamps[]` 与 `values[]` 数组。
- 时间分区策略：默认按 1 小时切分热分区，支持自动旋转与刷盘。
- InfluxDB Line Protocol 解析器，支持 `metric,tags fields timestamp` 格式。
- 标签倒排索引：自动构建 `key=value → set(series_id)` 索引。
- 磁盘持久化：自定义二进制格式（Magic + Header + Series Blocks）。
- 分区加载：`Engine.loadPartition` 支持从磁盘文件恢复只读分区。
- Compaction 模块：合并多个分区、排序、按时间戳去重（保留最新值）。
- **NNG 高性能 API Server**：基于 NNG req/rep 模式，提供 `write`、`query`、`stats` 命令。
- **内嵌 Web 测试页面**：参考 llama-server 设计，启动服务后自动在 `port+1` 提供单页测试应用。
- **POSIX socket 极简 HTTP 服务器**：`http_server.zig` 使用 C 标准库 socket 实现，Zig 0.16 兼容。
- **GPU 加速抽象层** (`gpu_acceleration.zig`)：可插拔后端（CUDA / Metal / OpenCL / CPU SIMD fallback）。
- CLI 工具：`serve`、`write`、`query`、`flush`、`compact`、`nngwrite`、`nngquery`、`nngstats` 命令。
- 集成测试：覆盖写入 → 刷盘 → 加载 → 查询完整链路。
- 性能基准测试：测量写入吞吐量、查询延迟、内存分区排序性能。
- Zig 0.16.0 完整兼容层：
  - 自定义 `fs_helper.zig` 封装 POSIX `open/read/write/mkdir`。
  - 使用 `std.c.gettimeofday` 实现毫秒/纳秒时间戳。
  - 适配移除的 `std.heap.GeneralPurposeAllocator`、`std.process.argsAlloc`、`std.io.getStdOut` 等 API。
- 147 个测试覆盖核心数据结构、引擎操作、Line Protocol 解析、二进制序列化、GPU 加速、HTTP 参数解析等。
- **接口测试**：5 个 HTTP API 测试覆盖 write / query / query_metric / flush / export 端点。
- **端到端测试**：curl 命令行验证单条写入 → 查询 → 导出完整链路。
- **批量写入 API** (`Engine.writeBatch`)：同序列多点单次锁保护，显著提升写入吞吐。
- **多场景基准测试**：单点写入、单序列批量、多序列批量（100 series x 1000 pts）。
- **增强版 Web 测试页面**：
  - 单条/批量写入测试、示例数据预设（CPU / 内存 / 温度）
  - 快速单点写入表单（Metric + Tags + Value + Timestamp）
  - 批量数据生成器（可配置序列数、点数、时间范围）与进度监控
  - 数据导入（拖拽上传 txt/csv）与导出（JSON / CSV / Line Protocol）
  - 全部数据导出为 InfluxDB Line Protocol 格式
  - 查询表格显示 Metric / Tags / Value 四列，无行数限制
  - 浏览器 console.log 调试输出（8 个关键函数）
- **HTTP API 增强**：
  - `/api/query_metric` 端点：按指标名跨序列查询
  - `/api/export` 端点：导出全部数据为 InfluxDB Line Protocol
  - 查询响应包含 `metric`、`tags`、`series_id` 字段
- **日志开关**：`tsdb serve [-v|--verbose]` 运行时日志级别控制（debug/warn）
- **GitHub Actions CI/CD**：多平台自动构建（Linux x86_64 / macOS aarch64 / macOS x86_64）、测试、格式检查、Release 发布。

### Fixed
- **CRITICAL: cloneSeriesKey errdefer 未定义行为**：修复 errdefer 对未初始化 tag 字段调用 `free` 导致的 UB，改用逐字段 errdefer 模式。
- **CRITICAL: tag_index use-after-free**：修复 `Engine.write` 中 `tag_index.getOrPut` 后 `dupe` 失败导致 hashmap key 悬垂指针的问题。
- **HIGH: toZ 栈缓冲区溢出**：修复 `fs_helper.toZ` 在路径恰好 1024 字节时的越界写入，缓冲区改为 1025 并增加长度校验。
- **HIGH: flushHotPartition 数据丢失**：修复元数据追加失败时热分区已被清空的问题，改为先追加元数据再清空热分区。
- **HIGH: queryPartition 静默吞掉 OOM**：修复 `queryPartition` 将内存分配错误静默吞掉返回不完整结果的问题，改为正确传播错误。
- **Major: parseLineProtocol tag 字符串泄漏**：修复 tags ArrayList 的 `deinit` 不释放 tag key/value 字符串的问题，改用 errdefer 手动释放。
- **Major: parseLineProtocol tags_slice/metric_owned 部分失败泄漏**：添加 errdefer 确保部分 dupe 失败时已分配内存被释放。
- **Major: insert/getOrCreateSeriesData key 泄漏**：修复 `series_keys.put` 失败时 `cloneSeriesKey` 返回的 key 内存泄漏，添加 errdefer。
- **MEDIUM: handleWrite 单行错误导致整批失败**：修复 HTTP `/write` 端点中单行解析错误导致整个请求返回 500 的问题，改为跳过错误行继续处理。
- **MEDIUM: milliTimestamp assert**：修复 `gettimeofday` 失败时 `assert` 崩溃，改为返回 `error.TimeError`。
- **写入 2000 查询返回 200**：修复 Web UI 表格 `rows.slice(0, 200)` 显示限制，移除后显示全部数据。
- **CSV 导出 value 为空**：修复 API 响应格式，查询结果现在包含 `metric`、`tags`、`series_id` 字段；CSV 导出同步更新为 5 列格式。
- **series_id JS 精度丢失**：HTTP 响应中 `series_id` 以字符串形式返回，避免 JavaScript Number 53 位精度限制。
- **HTTP 大数据接收失败**：修复单 `recv` 调用无法接收超过 256KB 批量数据的问题，实现 Content-Length 解析循环 + 1MB 缓冲区。
- **data 目录为空**：将 `max_partition_points` 从 10M 降至 100K，并添加自动落盘日志。
- **内存安全**：修复 `MemoryPartition.deinit` 与 `loadPartition` 中的双重释放问题。
- **所有权**：`cloneSeriesKey` 深拷贝确保分区对 `metric` 与 `tags` 字符串拥有独立所有权。
- **模块冲突**：`main.zig` 从路径导入改为模块导入，避免 Zig 0.16 模块系统中文件重复归属错误。
- **基准测试依赖**：移除 `bench` 对 `install` 的强制依赖。

### Changed
- `queryPartition` 返回类型从 `bool` 改为 `!void`，正确传播内存分配错误。
- `milliTimestamp` 返回类型从 `i64` 改为 `!i64`，支持错误处理。
- `fs_helper.toZ` 缓冲区大小从 1024 改为 1025，增加 `error.NameTooLong` 错误。
- **API 响应格式变更**：查询接口 `/api/query` 和 `/api/query_metric` 现在返回增强格式，每个数据点包含 `metric`、`tags`、`series_id` 字段。
- **磁盘分区加载策略**：从时间范围过滤改为保守加载策略（加载所有磁盘分区），避免历史数据写入导致的时间范围不匹配问题。
- **性能优化**：
  - 增量热点计数器 (`hot_partition_points`) 替代每次 O(series_count) 遍历统计。
  - 已知序列跳过 `tag_index` 更新：避免重复字符串分配和 HashMap 操作。
  - `SeriesData` 预分配容量 (`series_prealloc=1024`)，减少 ArrayList 扩容开销。
  - `MemoryPartition.insert` / `getOrCreateSeriesData` 新增 `prealloc` 参数。
  - 写入吞吐从 ~145K pts/sec 提升至 **~8.9M pts/sec**（单点）/ **~6.7M pts/sec**（100 序列批量），显著超越 InfluxDB 3 Core 的 ~320K/s。

## [0.1.0] - 2026-06-04

### Added
- 项目初始化，搭建基础仓库结构（`src/`、`tests/`、`build.zig`）。
- 定义核心数据类型：`DataPoint`、`SeriesKey`、`Tag`、`PartitionMeta`。
- 实现 `Engine.init` 与 `Engine.deinit`，支持数据目录自动创建。
- 实现 `MemoryPartition.insert` 与 `sortAll`，支持无序数据摄入后排序。
- 实现 `Engine.write` 单点写入与热分区管理。
- 实现 `Engine.flushHotPartition`，将内存分区序列化为磁盘文件。
- 实现 `Engine.queryRange`，支持按序列 ID 与时间范围查询。
- 添加 `build.zig` 构建目标：`run`、`test`、`bench`。

---

[Unreleased]: https://github.com/yourusername/tsdb.zig/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yourusername/tsdb.zig/releases/tag/v0.1.0
