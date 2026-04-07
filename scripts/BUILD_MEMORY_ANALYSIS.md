# vLLM XPU Kernels Build — Memory Analysis

Build profiled on MSI Claw A1M (Meteor Lake, 16GB RAM, 16GB disk swap) with MAX_JOBS=2.
Build started at 13:12, xpu-kernels phase (933 ninja objects).

## Build Phases & Memory Profile

### Phase 1: oneDNN (objects 1–654)
- **RAM usage**: 4–5 GB consistently
- **Swap usage**: ~0
- **Build rate**: ~20 objects/min (light files), slowing to ~4/min for GEMM JIT generators
- **Duration**: ~45 min with 2 workers

### Phase 2: CUTLASS Grouped GEMM (objects 653–656)
- **RAM usage**: peaked at **14 GB**
- **Swap usage**: peaked at **8 GB**
- **Files** (3 total — the heaviest in the entire build):
  - `grouped_gemm_xe_default.cpp` (~7 GB per worker)
  - `grouped_gemm_kernel.cpp` (~7 GB per worker)
  - `grouped_gemm_xe2.cpp` (~7 GB per worker)
- **Duration**: ~10 min with 2 workers

### Phase 3: Attention Kernels (objects 655–933)
- **RAM usage**: oscillates 3–10 GB depending on template variant
- **Swap usage**: steady ~2 GB
- **Build rate**: ~1 kernel per 2–3 min per worker

#### File counts:
| Kernel Type | Files | Variants |
|-------------|-------|----------|
| `chunk_prefill` | 80 | 5 head sizes (64,96,128,192,256) x 16 bool combos |
| `paged_decode` | 160 | 5 head sizes x 2 page sizes (64,128) x 2 query sizes (q8,q16) x 8 bool combos |
| **Total attention** | **240** | |

#### Memory per worker by variant:
- `chunk_prefill` with `f*` prefix (fewer enabled paths): ~3 GB
- `chunk_prefill` with `t*` prefix (more enabled paths): ~5 GB
- `paged_decode`: ~2–3 GB (lighter than chunk_prefill)

## Peak Memory Estimates by Configuration

### Worst case: CUTLASS GEMM phase
All 3 GEMM files compile simultaneously (each ~7 GB) plus remaining workers on attention kernels (~5 GB each).

| Device | RAM | Workers | Peak GEMM | Peak Attention | Total Peak | Swap Available |
|--------|-----|---------|-----------|----------------|------------|----------------|
| Claw A1M (Meteor Lake) | 16 GB | 3 | 3 x 7 = 21 GB | — | **21 GB** | 16 GB disk |
| Claw 8 AI+ (Lunar Lake) | 32 GB | 6 | 3 x 7 = 21 GB | 3 x 5 = 15 GB | **36 GB** | 32 GB disk |

### Worst case formula
```
Peak memory = min(GEMM_files, workers) x 7GB + max(0, workers - GEMM_files) x 5GB
```

- **3 workers**: 3 x 7 = **21 GB** (all 3 on GEMM simultaneously)
- **4 workers**: 3 x 7 + 1 x 5 = **26 GB**
- **6 workers**: 3 x 7 + 3 x 5 = **36 GB**

### RAM + Swap requirements
| Workers | Peak | Min RAM+Swap needed |
|---------|------|---------------------|
| 2 | 14 GB | 16 GB (safe on 16GB + any swap) |
| 3 | 21 GB | 24 GB (needs 16GB RAM + 8GB swap minimum) |
| 4 | 26 GB | 28 GB (needs 32GB RAM or 16GB + 16GB swap) |
| 6 | 36 GB | 40 GB (needs 32GB RAM + 8GB swap minimum) |

## Observed Build Times

| Workers | Device | oneDNN (654 obj) | GEMM (3 obj) | Attention (240 obj) | Link+Install | Total |
|---------|--------|-------------------|--------------|---------------------|-------------|-------|
| 2 | Meteor Lake 16GB | ~45 min | ~10 min | ~200 min | ~5 min | **~5 hours** (measured) |
| 3 | Meteor Lake 16GB | ~30 min | ~7 min | ~80 min | ~5 min | **~2 hours** |
| 6 | Lunar Lake 32GB | ~15 min | ~5 min | ~40 min | ~5 min | **~65 min** (estimated) |

## Key Takeaways

1. **The 3 CUTLASS GEMM files are the memory bottleneck** — each uses ~7 GB per worker.
2. **240 attention kernel templates** are moderately heavy (~3–5 GB each) and dominate build time.
3. **oneDNN (654 files)** is lightweight and fast — could benefit from more workers if parallelism were adjustable mid-build.
4. With disk swap properly sized (>= RAM), even 3 workers on 16GB RAM builds successfully — swap peaks are brief during GEMM phase only.
5. **2 workers on 16GB is safe but slow** — virtually no swap pressure, but 150% longer build time vs 3 workers.

## Known Build Issue: AOT Linking Failure

The build can compile all 933 objects successfully but **fail at the linking step** (925/933) with:
```
FAILED: [code=1] libgrouped_gemm_xe_default.so
icpx: warning: ocloc tool could not be found [...]
llvm-foreach: No such file or directory
icpx: error: gen compiler command failed with exit code 1
```

**Root cause:** Two missing tools required for SYCL ahead-of-time (AOT) GPU compilation:
1. `ocloc` — Intel offline compiler for GPU binaries (from `intel-ocloc` package)
2. `llvm-foreach` — exists in oneAPI compiler tree but not on PATH

**Fix:**
```bash
sudo dnf install -y intel-ocloc
sudo ln -sf /opt/intel/oneapi/compiler/2025.3/bin/compiler/llvm-foreach /usr/local/bin/llvm-foreach
```

This has been added to the install script (Phase 6, Step D).
