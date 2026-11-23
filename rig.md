# Rig configuration

Enough detail to make the findings in [README.md](README.md) actionable, and no
more. Host identifiers, service ports and workload specifics are deliberately
omitted.

## Hardware

| Component | Detail |
|---|---|
| CPU | AMD Ryzen 9 7900X |
| System RAM | 60 GB available to workloads |
| GPU 0 | Intel Arc Pro B70, 32 GB |
| GPU 1 | Intel Arc A770, 16 GB |

Both GPUs are in the same host. GPU 0 carries LLM serving. GPU 1 carried the
draft model in the speculative-decoding test behind F-2, and otherwise runs
workloads not covered here.

## Software

| Layer | Detail |
|---|---|
| Kernel | `7.0.0-1015-oem` |
| LLM runtime | llama.cpp, Vulkan backend |
| Alternate runtime | OpenVINO Model Server |
| Legacy path | SYCL (retained for one older dense model) |
| Compute runtime | Level Zero, device index `1` selects the A770 |

The Vulkan backend rather than SYCL is the production choice for the MoE coder.
SYCL is retained only where an older dense model still edges it.

## Serving configuration

```
--ctx-size 65536
--parallel 4
--cache-type-k q8_0
--cache-type-v q8_0
--flash-attn
```

Context divides across slots, so `--ctx-size 65536 --parallel 4` yields **16K
per slot**, not 64K per slot. This is the most common misreading of the flag
pair and it matters for capacity planning.

## Model under test

| Property | Value |
|---|---|
| Architecture | Qwen3-Coder-30B-A3B, sparse mixture of experts |
| Total parameters | 30B |
| Active per token | 3B |
| Quantisation | Q4_K_M GGUF |

The 3B active figure is the one that explains F-2. A target forward pass this
cheap leaves speculative decoding nothing to amortise.

## Measurement notes

- Figures are steady state on a host under normal working load, not an isolated
  bench run.
- Throughput was read from the server's own completion timings, averaged across
  a working session rather than a single request.
- "Aggregate throughput" in F-3 sums across concurrent slots. Per-stream decode
  is lower at higher slot counts and the two must not be compared directly.
