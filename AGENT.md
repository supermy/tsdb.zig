# TSDB.zig Agent 目标与规则

`tsdb.zig` 是一款使用 Zig 0.16 语言编写的高性能时序数据库（Time-Series Database）引擎。采用列式存储与 LSM-Tree 风格的分层架构，专为高吞吐写入与低延迟查询设计。通过 NNG (Nanomsg Next Generation) 提供高性能接口服务，并内嵌类似 `llama-server` 的单页 Web 测试控制台。

---

## 核心目标

1. **构建高效的时序数据库引擎**
   - 列式存储：每个时间序列独立维护时间戳数组与数值数组，缓存友好且便于向量化处理。
   - 时间分区：数据按小时（可配置）切分为内存热分区，避免全表扫描并支持高效 TTL 与归档。
   - LSM-like 分层：热分区（内存）→ 刷盘生成不可变文件 → 后台 Compaction 合并去重。
   - InfluxDB Line Protocol：内置行协议解析器，兼容现有采集端（Telegraf、Prometheus remote_write 等）。时间戳可选，省略时自动使用服务器当前时间。
   - 标签索引：自动构建 `key=value` 到序列 ID 的倒排索引，支持按标签过滤。

2. **NNG 高性能接口服务**
   - NNG req/rep 模式提供 `write`、`query`、`stats` 等命令。
   - HTTP 测试页面运行在 NNG 端口 + 1，提供 RESTful API 与可视化测试控制台。

3. **GPU 加速备选方案**
   - 可插拔后端设计（CUDA / Metal / OpenCL），默认 CPU SIMD fallback。
   - GPU 加速抽象层见 `src/gpu_acceleration.zig`，仅在明确带来收益时启用，禁止为未经验证的 GPU 路径牺牲 CPU 路径的正确性。

4. **性能对标**
   - 目标：写入吞吐达到 InfluxDB 3 Core（开源）水平，约 **~320K rows/sec**（恒定，不随基数变化）。
   - 使用 QuestDB TSBS 独立测试套件进行基准验证，结果需可复现。

---

## 开发方法论

- **TDD（测试驱动开发）**：新功能必须先写测试，再写实现。所有 bug 修复必须附带回归测试。
- **深度 Code Review**：每次提交前必须完成自我审查，关键路径（摄入、刷盘、Compaction、查询）需额外审查。
- **文档同步**：代码变更必须同步更新 README.md、CHANGELOG.md 与注释。禁止代码与文档不一致。
- **GitHub 同步**：所有生产级代码必须及时同步到 GitHub 仓库，禁止长期本地游离开发。
- **生产部署审查**：发布前需审查部署流程、配置项、日志级别与监控埋点。

---

## Web 测试控制台规范

默认测试页面参见 `llama.cpp` 的 `llama-server` 默认测试页面风格，单页 HTML，零构建依赖。

- **页面位置**：`webui/index.html`（唯一源码，禁止重复副本）。
- **自动服务**：`tsdb serve <port>` 启动时，HTTP 测试页面自动在 `port + 1` 提供服务。
- **功能要求**：
  - 单条数据写入与批量数据写入测试。
  - 提供示例数据（CPU、Memory、Temperature 等预设）。
  - 数据查询（按 Series ID、按 Metric 名、时间范围过滤）。
  - 批量数据导入（拖拽上传 `.txt` / `.csv` / `.lp`）。
  - 数据导出（JSON、CSV、InfluxDB Line Protocol）。
  - 性能监控面板（写入/查询延迟实时图表）。
  - 服务状态与存储分区可视化。
  - **README.md 访问入口**：页面右上角提供 README 按钮，点击弹出模态框展示项目文档，方便用户快速上手。
- **调试支持**：前端所有关键操作必须输出 `console.log`，方便浏览器端调试。

---

## 测试策略（覆盖率 100%）

所有测试必须通过 `zig build test` 执行，且覆盖率达到 100%。

### 测试层级

1. **单元测试**：每个模块（`tsdb.zig`、`compaction.zig`、`server.zig`、`http_server.zig`、`fs_helper.zig`、`gpu_acceleration.zig`、`fdap/optimizer.zig` 等）必须包含 Zig 内置 `test` 块。
2. **集成测试**：验证模块间协作（如写入 → 刷盘 → 查询 → Compaction 全链路）。
3. **冒烟测试**：快速验证构建产物可启动、基本接口可响应。
   - 冒烟测试必须增加详细日志输出，方便调试构建或环境问题。
4. **回归测试**：每个已修复的 bug 必须对应一个回归测试，防止再次引入。
5. **验收测试**：验证功能是否符合用户需求（如批量导入 1000 条数据后查询结果正确）。
6. **系统测试**：端到端测试，覆盖完整数据生命周期。
7. **接口测试**：验证 NNG 与 HTTP API 的每个端点行为正确。
8. **端到端测试（E2E）**：通过浏览器或 curl 脚本验证完整功能链路正常。

### 测试要求

- 使用 `std.testing.allocator` 检测内存泄漏。
- Arrow C 结构体生命周期必须与 Zig 分配器严格配对，禁止 FFI 边界泄漏未释放的 C 指针。
- 测试失败时日志必须足够详细，能直接定位到失败模块与输入数据。

---

## CI/CD 规范

使用 **GitHub Actions** 实现多平台自动构建、测试和部署。

- **触发条件**：`push` 到 `main`、所有 Pull Request。
- **构建矩阵**：至少覆盖 macOS（x86_64 / aarch64）与 Linux（x86_64）。
- **步骤**：
  1. 检出代码。
  2. 安装 Zig 0.16 与 NNG 依赖。
  3. `zig build`（构建验证）。
  4. `zig build test`（单元/集成测试）。
  5. 冒烟测试（启动服务，验证端口响应）。
  6. 端到端测试（curl / 浏览器自动化）。
  7. 可选：TSBS 基准测试（ nightly 或 release 触发）。
- **产物**：自动上传构建产物（二进制、测试报告）。

---

## 质量规则

- **先保正确性，再求速度**。不要保留存在无法解释的时间戳排序、重复数据解析或聚合漂移等问题的更快路径。
- **主语言为 Zig 0.16**；仅在 Arrow/Parquet/DataFusion 的 C FFI 绑定层使用 C 头文件。禁止在业务逻辑中引入 C++ 或 Rust 源码。
- **内存安全**：Zig 的内存安全由显式分配器模式保证；所有外部结构体生命周期必须与 Zig 的 `std.heap` 分配器严格配对。
- **公共 API 精简性**：CLI/服务端代码不应了解底层内部结构，仅限于模式元数据。
- **注释规范**：在数据生命周期、分区边界、缓存有效期或内存策略无法从本地代码中直接看出时，为重要的摄入和查询代码添加注释。保持注释的教导性和简洁性。
- **不要引入 flag 后的永久语义变体**。诊断开关允许，只要它们用于验证唯一发布路径（例如 `verify_dedup` 用于交叉检查重复数据解析）。
- **防范基数爆炸**：标签列必须使用 Dictionary 类型；在摄入网关处拒绝可能产生无界不同标签集的写入，而不是在查询时处理。
- **分区锁是设计意图**：不要在同一分区上并发运行多个 compactor 进程。Parquet 文件是不可变的，重写操作非原子性。

---

## 安全

- 避免对传入写入进行无界内存缓冲。摄入路径必须溢出到缓冲区，并在达到大小或时间阈值时刷新到磁盘，即使在持续的高基数负载下也应如此。
- 优先使用简短的冒烟测试进行构建验证。涉及大量回填的完整集成测试应针对模拟环境运行，而非生产存储桶。
- 所有 HTTP API 必须设置 CORS 头（`Access-Control-Allow-Origin: *`），以便单页测试控制台跨域访问。

---

## 项目结构

| 文件/目录 | 说明 |
|-----------|------|
| `src/main.zig` | CLI 入口：提供 `serve`、`write`、`query` 等子命令。 |
| `src/tsdb.zig` | 核心引擎：摄入路由、序列管理、热分区、Arrow C Data Interface 封装、标签索引。 |
| `src/compaction.zig` | 分区合并调度器、不可变文件重写、排序与去重逻辑。 |
| `src/server.zig` | NNG 高性能 API 服务端（req/rep），消息格式为 JSON。 |
| `src/http_server.zig` | HTTP 测试服务器：提供 REST API 与静态页面（`webui/index.html`）。 |
| `src/nng.zig` | NNG C 库的 Zig 绑定与错误处理。 |
| `src/gpu_acceleration.zig` | GPU 加速抽象层（CUDA / Metal / OpenCL 可插拔后端）。 |
| `src/fs_helper.zig` | 文件系统辅助函数与磁盘格式序列化。 |
| `src/fdap/optimizer.zig` | DataFusion 物理优化器规则注册（时间范围剪枝）。 |
| `src/ffi/arrow.zig` | Arrow C Data Interface 的 Zig 封装。 |
| `src/ffi/parquet.zig` | Parquet C++ API 的 Zig FFI 封装。 |
| `src/ffi/datafusion.zig` | DataFusion C FFI 封装、SQL 解析与物理计划执行。 |
| `webui/index.html` | 单页 Web 测试控制台（唯一源码）。 |
| `build.zig` | Zig 构建脚本，声明 NNG 等系统库链接与测试目标。 |
| `tests/` | 额外集成测试与模拟环境（如对象存储模拟）。 |

---

## 构建与运行

```bash
# 构建
zig build

# 运行（带详细日志）
./zig-out/bin/tsdb serve 8080 -v
# HTTP 测试页面: http://localhost:8081
# NNG API:       tcp://localhost:8080

# 测试
zig build test
```

---

## API 端点速查

HTTP 测试服务器提供的 REST API：

- `POST /api/write` — 写入 InfluxDB Line Protocol 数据。
- `GET /api/query?series_id=ID&start=...&end=...` — 按序列 ID 查询。
- `GET /api/query_metric?metric=NAME&start=...&end=...` — 按指标名查询。
- `POST /api/resolve` — 将 metric + tags 解析为 Series ID。
- `GET /api/stats` — 获取服务器分区与存储统计。
- `POST /api/flush` — 将热分区数据刷写到磁盘。
- `GET /api/export` — 导出所有数据为 Line Protocol。
- `GET /api/readme` — 返回嵌入的 README.md 内容（JSON）。

NNG 服务使用 JSON 消息格式：`{"cmd":"write|query|stats", ...}`。
