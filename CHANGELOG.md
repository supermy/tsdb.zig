# Changelog

所有重要变更均记录于此文件，格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)。

## [Unreleased]

### Added
- 实现完整时序数据库引擎核心（`Engine`、`MemoryPartition`、`SeriesData`）。
- 列式存储：每个序列独立维护 `timestamps[]` 与 `values[]` 数组。
- 时间分区策略：默认按 1 小时切分热分区，支持自动旋转与刷盘。
- InfluxDB Line Protocol 解析器，支持 `metric,tags fields timestamp` 格式。
- 标签倒排索引：自动构建 `key=value → set(series_id)` 索引。
- 磁盘持久化：自定义二进制格式（Magic + Header + Series Blocks）。
- 分区加载：`Engine.loadPartition` 支持从磁盘文件恢复只读分区。
- Compaction 模块：合并多个分区、排序、按时间戳去重（保留最新值）。
- HTTP API Server：提供 `/write`、`/query`、`stats` 端点。
- CLI 工具：`serve`、`write`、`query`、`flush`、`compact` 命令。
- 集成测试：覆盖写入 → 刷盘 → 加载 → 查询完整链路。
- 性能基准测试：测量写入吞吐量、查询延迟、内存分区排序性能。
- Zig 0.16.0 完整兼容层：
  - 自定义 `fs_helper.zig` 封装 POSIX `open/read/write/mkdir`。
  - 使用 `std.c.gettimeofday` 实现毫秒/纳秒时间戳。
  - 适配移除的 `std.heap.GeneralPurposeAllocator`、`std.process.argsAlloc`、`std.io.getStdOut` 等 API。
- 32 个单元测试覆盖核心数据结构、引擎操作、Line Protocol 解析、二进制序列化等。

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
- **内存安全**：修复 `MemoryPartition.deinit` 与 `loadPartition` 中的双重释放问题。
- **所有权**：`cloneSeriesKey` 深拷贝确保分区对 `metric` 与 `tags` 字符串拥有独立所有权。
- **模块冲突**：`main.zig` 从路径导入改为模块导入，避免 Zig 0.16 模块系统中文件重复归属错误。
- **基准测试依赖**：移除 `bench` 对 `install` 的强制依赖。

### Changed
- `queryPartition` 返回类型从 `bool` 改为 `!void`，正确传播内存分配错误。
- `milliTimestamp` 返回类型从 `i64` 改为 `!i64`，支持错误处理。
- `fs_helper.toZ` 缓冲区大小从 1024 改为 1025，增加 `error.NameTooLong` 错误。

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
