# Agent 笔记

`tsdb.zig` 是一款基于 FDAP 技术栈（Apache Arrow、DataFusion、Apache Parquet、Arrow Flight）的专用时序数据库引擎。它并非通用的 OLAP 数仓。其目标是构建一个以 Zig 为主语言、精简且高性能的核心，通过 Zig 的 C 互操作直接对接 Arrow C Data/Stream Interface 与 DataFusion C FFI，从数据摄入到查询全程保持 Arrow 原生语义，并以 Parquet 作为唯一的持久化格式。

## 目标

- 保持生产路径为全链路 Arrow 原生处理：内存中使用 Arrow 数组、磁盘使用 Parquet、网络传输使用 Flight、查询规划使用 DataFusion。
- 对热数据保持基于 mmap 的模型加载；不要急于将完整的 Parquet 数据集复制到内存中。对历史文件采用对象存储风格的分层策略。
- 内存路径严格保持 Arrow 列式结构。热数据不要回退到行式结构。CPU 后端仅用于参考/调试。
- 先保正确性，再求速度。不要保留存在无法解释的时间戳排序、重复数据解析或聚合漂移等问题的更快路径。
- 通过实时分区重组（compaction）、Parquet 字典编码以及不引入查询时解压开销的磁盘分层，使长期数据保留具备可行性。
- 通过将标签字典保存在 Arrow Dictionary 数组中，并依赖 DataFusion 的谓词下推和布隆过滤器，支持无限基数。
- 以 Zig 为唯一主语言；所有 FDAP 依赖（Arrow、Parquet、DataFusion、Flight）均通过 C FFI / C ABI 接入，不引入 Rust 或 C++ 业务代码。

## 质量规则

- 在数据生命周期、分区边界、缓存有效期或内存策略无法从本地代码中直接看出时，为重要的摄入和查询代码添加注释。
- 相比单独的设计文档，更偏好直接在实现旁添加注释。
- 保持注释的教导性和简洁性：解释为何存在某种时间范围分区、排序方式、去重窗口或内存选择。
- 保持公共 API 的精简性。CLI/服务端代码不应了解 Arrow RecordBatch 的内部结构，仅限于模式元数据。
- 不要在 flag 后添加永久性的语义变体。诊断开关是允许的，只要它们用于验证唯一发布路径（例如 `verify_dedup` 用于交叉检查重复数据解析）。
- 主语言为 Zig；仅在 Arrow/Parquet/DataFusion 的 C FFI 绑定层使用 C 头文件。禁止在业务逻辑中引入 C++ 或 Rust 源码。

## 安全

- 避免对传入写入进行无界内存缓冲。摄入路径必须溢出到 Arrow RecordBatch 缓冲区，并在达到大小或时间阈值时刷新到 Parquet 文件，即使在持续的高基数负载下也应如此。
- 不要在同一分区上并发运行多个 compactor 进程。分区锁是设计意图；Parquet 文件是不可变的，重写操作非原子性。
- 优先使用简短的 Flight 冒烟测试进行构建验证。涉及大量回填的完整集成测试应针对对象存储模拟运行，而非生产存储桶。
- 防范基数爆炸：标签列必须使用 Arrow Dictionary 类型；在摄入网关处拒绝可能产生无界不同标签集的写入，而不是在查询时处理。
- Zig 的内存安全由显式分配器模式保证；所有 Arrow C 结构体的生命周期必须与 Zig 的 `std.heap` 分配器严格配对，禁止在 FFI 边界处泄漏未释放的 C 指针。

## 项目结构

- `tsdb.zig`：摄入路由器、Arrow C Data Interface 封装、Parquet 写入调度、DataFusion FFI 会话上下文、分区目录、保留策略运行器。
- `tsdb_cli.zig`：命令行、SQL/InfluxQL 的 REPL、批量加载、分区检查。
- `tsdb_server.zig`：Arrow Flight SQL 端点（通过 Flight C++ FFI 桥接）、HTTP API（兼容 OpenTelemetry/InfluxDB Line Protocol）、工作队列、流式查询分发、热分区磁盘缓存策略。nng 实现高性能的接口服务。
- `ffi/arrow.zig`：Arrow C Data Interface (`ArrowArray` / `ArrowSchema`) 的 Zig 封装、RecordBatch 构建器、内存对齐与释放适配器。
- `ffi/parquet.zig`：Parquet C++ API 的 Zig FFI 封装、列编码配置（时间戳 delta、标签 dictionary）、布隆过滤器构造器。
- `ffi/datafusion.zig`：DataFusion 的 C FFI 封装、SQL 解析、物理计划执行、自定义 UDF/UDAF 注册（时序专用：gap fill、rate、derivative、dedup）。
- `fdap/`：基于 Zig 的 DataFusion 物理优化器规则注册（时间范围剪枝）、以及 Zig 实现的时序辅助函数。
- `compaction.zig`：分区合并调度器、Parquet 文件重写、排序与去重逻辑。
- `tests/`：Zig 内置测试框架 (`zig test`) 的单元测试和集成测试，包含内存对象存储模拟。
- `misc/`：忽略的笔记、实验和旧规划材料。

## 构建与测试

使用 `zig build` 进行构建验证。使用 `zig build test` 进行单元/回归测试（需要 Arrow C 库与 DataFusion C FFI 库在链接路径中）。仅在有意测试 Flight SQL 或 HTTP API 表面时，才使用实时服务端测试。

Zig 构建脚本 (`build.zig`) 必须显式声明：
1. 对 `libarrow_cdata` 与 `libparquet` 的系统库链接。
2. 对 `libdatafusion_ffi` 的链接（由 Rust 侧提供 C ABI 导出）。
3. 编译时通过 `@cImport` 引入的 C 头文件路径。

摄入测试必须验证：
1. Arrow RecordBatch 模式合规性（时间戳、标签为 Dictionary、字段为原生类型）。
2. 读取后具有相同时间戳和标签排序的 Parquet 往返。
3. 在配置缓冲区窗口内对迟到数据的重复数据解析正确性。
4. Zig 分配器在 FFI 调用后无内存泄漏（使用 `std.testing.allocator` 的泄漏检测）。

查询测试必须验证：
1. DataFusion 计划包含对 Parquet 的时间范围谓词下推。
2. 字典编码的标签列在处理时不会产生物化开销。
3. 聚合结果与在相同 Arrow 数组上的参考实现一致。
4. FFI 边界处的错误码正确传播到 Zig 的错误联合类型 (`error!T`)。
