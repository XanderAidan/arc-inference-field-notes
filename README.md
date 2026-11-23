# Dual-Arc Inference Field Notes

Measured behaviour of an **Intel Arc Pro B70 (32 GB)** and an **Arc A770 (16 GB)**
running as a single production inference host on Linux: LLM serving, image
generation, and retrieval workloads.

Seven findings. Two are reproducible defects, one is a convincing false
bottleneck that will waste your afternoon, and two are negative results that
cost me more hours than any of the positives.

Measurements October to November 2026. Reproduction scripts in [`repro/`](repro/).

> These are field notes from a working host under real load, not a controlled
> benchmark suite. Figures are reported to the precision they were recorded at.
> Where a result is a negative or a hard limit, it is labelled as one.

---

## Test rig

| | |
|---|---|
| Host | Ryzen 9 7900X, 60 GB system RAM, Ubuntu on kernel `7.0.0-1015-oem` |
| GPU 0 | Intel Arc Pro B70, 32 GB |
| GPU 1 | Intel Arc A770, 16 GB |
| Runtimes | llama.cpp (Vulkan backend), OpenVINO Model Server, SYCL on a legacy path |
| Primary model | Qwen3-Coder-30B-A3B, sparse MoE, **30B total / 3B active**, Q4_K_M GGUF |
| Serving config | `--ctx-size 65536 --parallel 4` (16K per slot), KV cache `q8_0` on both K and V, flash attention enabled |
| Steady state | **~54 tok/s** decode, **~336 tok/s** prefill |

Full configuration in [`rig.md`](rig.md).

---

## Performance findings

### F-1. KV cache `q8_0` is lossless on this configuration

**Confirmed.** Quantising both K and V to `q8_0` with flash attention enabled
produced output **byte-identical** to `f16` across the validation set. Not
near-identical. Identical.

This halves the KV footprint at no measured quality cost, and it is what makes a
64K window fit on the B70 while a second workload shares the card.

| | |
|---|---|
| K and V cache type | `q8_0` |
| Output vs `f16` | byte-identical |
| Window achieved | 64K total, 16K per slot across 4 slots |

**Why it matters:** the B70's 32 GB is its main advantage for local inference.
`q8_0` KV is what converts that capacity into usable context length instead of
headroom that sits idle.

Reproduce: [`repro/kv-fidelity.sh`](repro/kv-fidelity.sh)

---

### F-2. Speculative decoding is a net loss on a low-active-parameter MoE

**Negative result.** Dual-GPU speculative decoding, draft model on the A770 and
target on the B70, measured roughly **3x slower** than straight decoding. Draft
acceptance was **32%**.

With only 3B parameters active per token, the target forward pass is already
cheap, so verification overhead and cross-device transfer dominate whatever the
draft saves.

**Takeaway:** speculative decoding assumes an expensive target. That assumption
fails on sparse MoE, and the intuition carries over unexamined from dense models
where it holds. If you want throughput on a model like this, add slots, not a
draft model. See F-3.

---

### F-3. Parallel slots scale where speculative decoding does not

**Confirmed.** Sweeping `--parallel` across 2, 4 and 8 raised aggregate
throughput from **71 to 120 tok/s**.

| `--parallel` | Aggregate throughput |
|---:|---:|
| 2 | 71 tok/s |
| 8 | 120 tok/s |

This is not free. Per-stream decode falls as slots rise, and the context budget
divides across slots, so slot count is a window-size against throughput trade
rather than a gain. Production sits at `--parallel 4`, which is where both stay
usable for interactive work.

Reproduce: [`repro/parallel-sweep.sh`](repro/parallel-sweep.sh)

---

## Defects and reporting artifacts

### F-4. Both Arc cards misreport PCIe link width

**Reporting artifact.** `sysfs` and `lspci` report **Gen1 x1** (2.5 GT/s, x1)
for both the B70 and the A770.

The detail that settles it: `max_link_speed` and `max_link_width` report
2.5 GT/s x1 as well. It is not only the negotiated link that reads wrong, the
**capability** registers do too. No Arc card is manufactured as a Gen1 x1
device, so the reported capability does not describe any real product and the
reading disproves itself. No bandwidth test is required.

```
device   : 0000:03:00.0
name     : Intel Corporation Battlemage G31 [Intel Graphics]
reported : 2.5 GT/s PCIe  x1
capable  : 2.5 GT/s PCIe  x1      <- a capability that does not exist

device   : 0000:0a:00.0
name     : Intel Corporation DG2 [Arc A770] (rev 08)
reported : 2.5 GT/s PCIe  x1
capable  : 2.5 GT/s PCIe  x1
```

This is an ASPM and driver reporting artifact rather than a real link state,
and measured transfer behaviour does not correspond to a Gen1 x1 link.

**This is worth documenting because it is a convincing false bottleneck.**
Anyone profiling Arc on Linux will find it, reasonably conclude the slot is
misconfigured or the riser is bad, and spend a day chasing a hardware fault that
does not exist. I nearly did.

Reproduce on any Arc host: [`repro/pcie-link-report.sh`](repro/pcie-link-report.sh)

---

### F-5. Large prompts can leave the B70 in a poisoned memory state

**Defect, mitigated.** On the OpenVINO path, prompts near and above **8k tokens**
drove the card into an out-of-memory condition that **persisted across
subsequent requests** rather than failing cleanly and recovering. Chunked
prefill is the effective mitigation.

The failure mode matters more than the limit here. A clean rejection would be an
ordinary capacity ceiling. A state that survives the request takes the server
down with it.

---

### F-6. DeltaNet-class architectures terminate the Vulkan backend

**Defect, reproducible.** Generation models using DeltaNet layers, tested across
the Qwen3-Next and Qwen3.6 families, fail with **Vulkan `DeviceLost`** on the
current build. Reproducible across attempts and model sizes.

This is why the production coder stayed on an existing Qwen3-Coder GGUF rather
than moving to a newer architecture. The architecture choice has to be made
before the port, and right now there is no way to know without trying it.

---

## Ecosystem gap

### F-7. Host memory binds above roughly 90 GB, and the escape hatch is CUDA-only

**Measured limit.** Qwen3-235B measured **0.13 tok/s** and showed no quality
advantage over an 80B at a runnable quantisation, so the ceiling is real rather
than a tuning problem. A 748B DeepSeek model did run via SSD expert streaming,
at **0.59 tok/s**, drive-bound.

| Model | Throughput | Bound by |
|---|---:|---|
| 235B (Q4-class) | 0.13 tok/s | host RAM, 60 GB available |
| 748B via SSD expert streaming | 0.59 tok/s | drive and host bus |

**The gap:** the SSD-streaming MoE runtime's GPU expert tier targets CUDA and
ROCm only. On Arc the experts fall back to CPU, so the drive and host bus set the
ceiling and the 32 GB of fast VRAM sits mostly unused.

A Level Zero or oneAPI expert-offload target is the difference between a
curiosity and a usable large-MoE host on a single 32 GB Arc card.

---

## What would move this work forward

1. **A Level Zero or oneAPI expert-offload target in the SSD-streaming MoE
   runtimes.** This is the single change that would put large sparse models
   within reach of a 32 GB Arc card. (F-7)
2. **Resolution or documentation of the PCIe link-width reporting**, because it
   currently misleads every Arc profiling effort on Linux. (F-4)
3. **Earlier visibility on Vulkan backend coverage for new attention
   architectures**, so an architecture choice can be made before the port rather
   than after a `DeviceLost`. (F-6)

---

## Author

AJ Fleming. Systems builder and published entomologist (Tachinidae taxonomy),
running a deliberately local-first, non-CUDA inference stack.

## License

Scripts in `repro/` are MIT. The prose is CC BY 4.0. Attribution appreciated if
the findings save you time.
