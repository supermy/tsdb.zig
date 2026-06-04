# TSDB GPU Acceleration Design Document

## 1. Why GPU Acceleration for TSDB

Time-series databases (TSDB) are inherently data-parallel workloads. GPU acceleration provides significant advantages in the following areas:

### 1.1 Parallel Aggregation
Time-series queries frequently involve aggregating millions of data points across large time windows (e.g., `AVG`, `SUM`, `MIN`, `MAX` over 1-hour buckets). GPUs can launch thousands of parallel threads to compute aggregations simultaneously, achieving **10x–100x throughput** compared to scalar CPU execution for batch operations.

### 1.2 Vectorized Scan
Range scans (`SELECT * FROM metric WHERE time > t1 AND time < t2`) must filter and copy columnar data. GPUs excel at coalesced memory access and can apply predicate pushdown across large columnar buffers using warp-level parallelism, reducing query latency for analytical workloads.

### 1.3 Compression & Decompression
Time-series data is highly compressible (Gorilla, Delta-of-Delta, LZ4). GPU-based decompression kernels can unpack compressed columnar blocks in parallel, allowing the query engine to keep more data in GPU memory and reducing PCIe transfer bottlenecks.

### 1.4 Anomaly Detection
Modern TSDBs integrate real-time anomaly detection (isolation forests, FFT-based spectral analysis). These algorithms are massively parallel and map naturally to GPU compute shaders or CUDA kernels, enabling sub-second detection on high-cardinality metrics.

---

## 2. Architecture Design

### 2.1 Design Principles
- **Backend Agnostic**: The query engine should not depend on a specific GPU vendor.
- **Zero-Copy Where Possible**: Columnar buffers should be transferable to GPU memory without serialization.
- **Comptime Backend Selection**: The active backend is chosen at compile time to avoid runtime dispatch overhead in hot paths.
- **Graceful Degradation**: If no GPU is available, the system falls back to CPU SIMD automatically.

### 2.2 Layered Architecture

```
┌─────────────────────────────────────────┐
│           Query Engine                  │
│   (Planner → Executor → Aggregator)     │
├─────────────────────────────────────────┤
│      GPU Acceleration Abstraction       │
│   (GpuAccelerator, GpuBackend enum)     │
├─────────────────────────────────────────┤
│  ┌─────────┐ ┌─────────┐ ┌──────────┐ │
│  │  CUDA   │ │  Metal  │ │  OpenCL  │ │
│  │ Backend │ │ Backend │ │ Backend  │ │
│  └─────────┘ └─────────┘ └──────────┘ │
├─────────────────────────────────────────┤
│      CPU SIMD Fallback (@Vector)        │
└─────────────────────────────────────────┘
```

### 2.3 GpuBackend Enum
```zig
pub const GpuBackend = enum {
    cpu_simd,   // Zig @Vector fallback (portable, no external deps)
    cuda,       // NVIDIA CUDA (cuBLAS, Thrust, custom kernels)
    metal,      // Apple Metal Performance Shaders (MPS)
    opencl,     // OpenCL 1.2+ (cross-platform, Intel/AMD/NVIDIA)
};
```

### 2.4 GpuAccelerator Interface
The `GpuAccelerator` struct provides a unified API:
- `init(allocator, backend)` – initialize the selected backend
- `deinit()` – release GPU memory and context
- `batchSum(input, output, batch_size)` – parallel sum aggregation
- `batchAvg(input, output, batch_size)` – parallel average aggregation
- `batchMin(input, output, batch_size)` – parallel minimum aggregation
- `batchMax(input, output, batch_size)` – parallel maximum aggregation

All batch operations accept contiguous `f64` slices and write one result per batch. The input length must be an integer multiple of `batch_size`.

### 2.5 Backend Selection Strategy
| Platform / Target | Preferred Backend | Fallback |
|-------------------|-------------------|----------|
| macOS (Apple Silicon) | Metal | CPU SIMD |
| macOS (Intel) | OpenCL | CPU SIMD |
| Linux + NVIDIA GPU | CUDA | OpenCL → CPU SIMD |
| Linux + AMD GPU | OpenCL | CPU SIMD |
| Windows + NVIDIA GPU | CUDA | OpenCL → CPU SIMD |
| WebAssembly / Embedded | — | CPU SIMD |

---

## 3. Specific Use Cases

### 3.1 Batch Aggregation (Downsampling)
**Scenario**: A dashboard requests `AVG(cpu_usage)` per 1-minute bucket over 24 hours for 10,000 series.  
**GPU Role**: Launch one thread per bucket. Each thread loads its bucket’s `f64` values, computes the sum via warp shuffle reductions, and writes the average.  
**Expected Speedup**: 20x–50x vs scalar CPU on large batches.

### 3.2 Range Scan (Filter + Project)
**Scenario**: `SELECT timestamp, value FROM temperature WHERE time > now() - 1h AND value > 90.0`.  
**GPU Role**: A kernel applies the time and value predicates in parallel, writing matching indices to a compacted output buffer using prefix-sum (stream compaction).  
**Expected Speedup**: 5x–15x for high-selectivity scans.

### 3.3 Data Decompression
**Scenario**: Loading compressed Gorilla-encoded columnar blocks from disk into memory.  
**GPU Role**: A custom CUDA/Metal kernel decodes delta-of-delta timestamps and XOR-difference values in parallel across the block.  
**Expected Speedup**: 3x–10x decompression throughput, freeing CPU cycles for query planning.

### 3.4 Anomaly Detection
**Scenario**: Real-time outlier detection on 100,000 metrics using sliding-window Z-score.  
**GPU Role**: Compute mean and standard deviation per window in shared memory, then flag anomalies in a second kernel.  
**Expected Speedup**: 50x+ for large-scale monitoring, enabling sub-second alerting.

---

## 4. Implementation Roadmap

### Phase 1: CPU SIMD Fallback (Current — `gpu_acceleration.zig`)
- **Goal**: Establish the abstraction layer and API contract without external dependencies.
- **Implementation**:
  - Define `GpuBackend` enum and `GpuAccelerator` struct.
  - Implement `batch_sum`, `batch_avg`, `batch_min`, `batch_max` using Zig `@Vector` types.
  - Vector width chosen at `comptime` based on target CPU features (default 256-bit / 4 × `f64`).
  - Add unit tests for aligned and non-aligned batch sizes.
- **Success Criteria**: All existing TSDB tests pass; new batch tests achieve **>2x speedup** over scalar loops on `ReleaseFast`.

### Phase 2: Metal & CUDA Backends
- **Metal (Apple platforms)**:
  - Link `Metal.framework` via Zig’s `@cImport`.
  - Implement aggregation kernels in Metal Shading Language (MSL).
  - Manage `MTLBuffer` allocation for columnar `f64` slices.
- **CUDA (Linux/Windows + NVIDIA)**:
  - Link `libcuda` and `libcudart` dynamically.
  - Write `.cu` kernels for sum/min/max reductions using warp shuffle.
  - Use `cudaMemcpyAsync` for overlapped H2D → compute → D2H.
- **Success Criteria**: Backend selected via `comptime` flag; single binary can switch backends at compile time.

### Phase 3: OpenCL Backend
- **Goal**: Provide a vendor-neutral GPU path for AMD, Intel, and older NVIDIA hardware.
- **Implementation**:
  - Link OpenCL ICD loader (`libOpenCL.so` / `OpenCL.framework`).
  - Compile aggregation kernels from OpenCL C source strings at runtime.
  - Reuse the same kernel logic as CUDA, adapted to OpenCL work-groups.
- **Success Criteria**: Passes identical test suite on AMD ROCm and Intel OpenCL runtimes.

---

## 5. Performance Expectations

| Workload | CPU Scalar | CPU SIMD | GPU (Metal/CUDA) | Notes |
|----------|-----------|----------|------------------|-------|
| Batch SUM (1M points) | 1.0× | 2.5×–4× | 15×–40× | PCIe transfer included for GPU |
| Batch AVG (1M points) | 1.0× | 2.5×–4× | 15×–40× | Same kernel as SUM + scalar div |
| Batch MIN/MAX (1M points) | 1.0× | 2×–3× | 10×–30× | Warp/wavefront reductions |
| Gorilla Decompress (1M) | 1.0× | — | 5×–10× | Custom kernel, memory bound |
| Range Scan + Filter (10M) | 1.0× | 1.5×–2× | 8×–20× | Stream compaction overhead |
| Sliding Window Anomaly (1M) | 1.0× | 2×–3× | 20×–60× | Shared memory optimizations |

> **Note**: Actual speedups depend on GPU model, memory bandwidth, PCIe generation, and batch size. The abstraction layer keeps benchmarks reproducible across backends.

---

## 6. Build Configuration (`comptime` Flags)

Zig’s `comptime` enables zero-cost backend selection without runtime branches.

### 6.1 Backend Selection Options
| Flag | Values | Default | Description |
|------|--------|---------|-------------|
| `-Dgpu_backend=` | `cpu_simd`, `cuda`, `metal`, `opencl` | `cpu_simd` | Active compute backend |
| `-Dgpu_vector_width=` | `2`, `4`, `8` | `4` | SIMD lane count for CPU fallback (`f64`) |
| `-Dcuda_path=` | path string | `/usr/local/cuda` | CUDA toolkit installation prefix |
| `-Dmetal_link_framework=` | `true`, `false` | `true` (macOS only) | Link Metal.framework |

### 6.2 Example Build Commands

```bash
# Default: CPU SIMD fallback
zig build

# Explicit CPU SIMD with 8-wide vectors
zig build -Dgpu_backend=cpu_simd -Dgpu_vector_width=8

# macOS with Metal
zig build -Dgpu_backend=metal

# Linux with CUDA
zig build -Dgpu_backend=cuda -Dcuda_path=/opt/cuda

# Linux with OpenCL
zig build -Dgpu_backend=opencl

# Run GPU-specific tests
zig build test -- -Dgpu_backend=metal
```

### 6.3 `build.zig` Integration Snippet
```zig
const gpu_backend = b.option(GpuBackend, "gpu_backend", "GPU backend") orelse .cpu_simd;
const gpu_vector_width = b.option(u32, "gpu_vector_width", "SIMD width") orelse 4;

const gpu_mod = b.createModule(.{
    .root_source_file = b.path("src/gpu_acceleration.zig"),
    .target = target,
    .optimize = optimize,
});
gpu_mod.addOptions("gpu_options", blk: {
    const opts = b.addOptions();
    opts.addOption(GpuBackend, "backend", gpu_backend);
    opts.addOption(u32, "vector_width", gpu_vector_width);
    break :blk opts;
});

if (gpu_backend == .metal and target.result.os.tag == .macos) {
    gpu_mod.linkFramework("Metal", .{});
    gpu_mod.linkFramework("Foundation", .{});
}
if (gpu_backend == .cuda) {
    gpu_mod.addIncludePath(b.path("/usr/local/cuda/include"));
    gpu_mod.addLibraryPath(b.path("/usr/local/cuda/lib64"));
    gpu_mod.linkSystemLibrary("cudart", .{});
}
if (gpu_backend == .opencl) {
    gpu_mod.linkSystemLibrary("OpenCL", .{});
}
```

### 6.4 Compile-Time Backend Dispatch
Inside `gpu_acceleration.zig`:
```zig
const gpu_options = @import("gpu_options");

pub const GpuBackend = enum { cpu_simd, cuda, metal, opencl };
pub const active_backend: GpuBackend = gpu_options.backend;

pub fn batchSum(...) !void {
    switch (active_backend) {
        .cpu_simd => return cpuBatchSum(...),
        .cuda => return cudaBatchSum(...),
        .metal => return metalBatchSum(...),
        .opencl => return openclBatchSum(...),
    }
}
```
Because `active_backend` is `comptime`-known, the compiler eliminates all unused backends from the final binary, ensuring minimal code size and zero runtime dispatch cost.

---

## 7. Future Work
- **Unified Memory (UVM)**: On CUDA and Metal, use unified memory to eliminate explicit `copyToDevice` / `copyToHost` calls for buffers that fit in GPU memory.
- **Kernel Fusion**: Fuse `decompress → filter → aggregate` into a single GPU kernel to reduce memory round-trips.
- **Multi-GPU**: Distribute time-series shards across multiple GPUs via NCCL (CUDA) or explicit command-buffer scheduling (Metal).
- **WebGPU**: For future WebAssembly targets, investigate Dawn/wgpu as a portable compute backend.

---

## 8. References
- Zig Language Reference: `@Vector`, `@reduce`, `comptime` — https://ziglang.org/documentation/0.16.0/
- CUDA C Programming Guide — https://docs.nvidia.com/cuda/cuda-c-programming-guide/
- Metal Shading Language Specification — https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf
- OpenCL 1.2 Reference Pages — https://www.khronos.org/registry/OpenCL/sdk/1.2/docs/man/xhtml/
- Gorilla: A Fast, Scalable, In-Memory Time Series Database (Facebook, 2015)
