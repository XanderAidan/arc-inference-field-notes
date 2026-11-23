# Reproduction scripts

Three scripts, in order of how easily they reproduce.

| Script | Reproduces | Needs |
|---|---|---|
| `pcie-link-report.sh` | F-4, the PCIe link-width artifact | any Arc host, no model |
| `kv-fidelity.sh` | F-1, `q8_0` KV being lossless | `llama-cli` and a GGUF |
| `parallel-sweep.sh` | F-3, slot count against aggregate throughput | `llama-server` and a GGUF |

`pcie-link-report.sh` needs nothing but an Arc card and will show the artifact in
about a second. Start there.

The other two take a model path and run against a local server you start
yourself. Nothing here phones home, writes outside its working directory, or
assumes a particular host or port.

## Caveat on flag names

llama.cpp flag names move. These scripts target the flag spellings current as of
November 2026 (`--cache-type-k`, `--cache-type-v`, `--flash-attn`, `--parallel`).
If your build rejects a flag, check `llama-cli --help` before assuming the
finding does not reproduce.
