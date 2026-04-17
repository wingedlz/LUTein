# 🔷 LUTein Sparse Core (Verilog Implementation)

This repository contains a simplified Verilog implementation inspired by the LUTein architecture for Radix-4 LUT-based slice-tensor processing.

The project focuses on:
- a Radix-4 LUT multiplier and slice-level PE implementation
- a dense 4×4 PE array
- a hybrid sparse/dense 4×4 core
- zero-row compaction
- row-index-aware sparse weight access
- functional validation with Icarus Verilog

---

## 🚀 Overview

The repository is organized around three layers:

- PE layer
  - radix-4 LUT-based 4-bit multiplier
  - slice-level tensor PE with valid/ready handshaking
  - channel-wise accumulation and forwarding

- Dense core
  - left-edge input buffering
  - column-wise dense weight buffering
  - horizontal PE-to-PE forwarding across a 4×4 array

- Hybrid sparse/dense core
  - zero-row detection and row compaction
  - row-index buffering
  - sparse indexed weight lookup
  - dense-style horizontal forwarding with sparse-aware front-end logic

---

## 🧠 Architecture

### Dense Core
- Input slices are injected from the left edge of each row.
- Each column stores one dense weight block.
- The input slice is forwarded horizontally across the PE chain.
- Row order is preserved.

### Hybrid Sparse/Dense Core
- Rows are first checked for nonzero activity.
- In sparse mode, only nonzero rows are packed into active slots.
- The original row index is preserved and forwarded with the data.
- Each PE selects either:
  - a dense column weight block, or
  - an indexed sparse weight block using `weight[col][row_idx]`.

---

## 🔍 Dataflow Summary

### Dense Mode
- All rows are processed in order.
- Zero rows are still carried through the array.
- Each column uses one fixed dense weight block.

### Sparse Mode
- Zero rows are removed before entering the PE chain.
- Surviving rows are packed into compacted slots.
- The original row index is preserved and used for sparse weight lookup.

Example:

Dense:
Row0 -> Row slot 0
Row1 -> Row slot 1
Row2 -> Row slot 2
Row3 -> Row slot 3

Sparse:
Row0 -> Slot0
Row2 -> Slot1
Row3 -> Slot2
(empty) -> Slot3

Notes:
- slot index is not the same as original row index
- sparse weight access uses the preserved original row index

---

## ⚙️ Main Modules

| File | Role |
|------|------|
| `pe_modules.v` | Radix-4 LUT multiplier blocks and slice-level PE |
| `lutein_dense_core.v` | Dense input/weight buffering and 4×4 dense core |
| `lutein_sparse_core.v` | Index-aware PE and hybrid sparse/dense 4×4 core |
| `pe_tb.v` | PE-level functional testbench |
| `lutein_dense_core_tb.v` | Dense core testbench |
| `lutein_sparse_core_tb.v` | Hybrid sparse/dense core testbench |

---

## ✅ Verified Functionality

### PE-level
- radix-4 LUT multiplication
- signed input handling
- repeated accumulation
- zero-input hold / zero-skip behavior
- output back-pressure
- forward-path validation
- directed and random stress tests

### Dense Core
- left-edge row injection
- horizontal forwarding across columns
- dense column weight usage
- tile-level output correctness

### Hybrid Sparse/Dense Core
- dense-mode metadata and output correctness
- sparse row compaction
- packed row-index metadata correctness
- indexed sparse weight selection
- single surviving-row sparse case

---

## 🧪 Simulation

### Requirements
- Icarus Verilog (`iverilog`)
- GTKWave (optional)

### 1. PE testbench

```bash
iverilog -g2012 -o simv pe_modules.v pe_tb.v
vvp simv
```

#### Expected output

```text
============================================================
TB SUMMARY: total=61 pass=61 fail=0
============================================================
ALL TESTS PASSED
pe_tb.v:499: $finish called at 2555 (1s)
```

### 2. Dense core testbench

```bash
iverilog -g2012 -o simv pe_modules.v lutein_dense_core.v lutein_dense_core_tb.v
vvp simv
```

#### Expected output

```text
[PASS] dense tile check passed at time=146
[DONE] dense core tb finished
lutein_dense_core_tb.v:191: $finish called at 185 (1s)
```

### 3. Hybrid sparse/dense core testbench

```bash
iverilog -g2012 -o simv pe_modules.v lutein_sparse_core.v lutein_dense_core.v lutein_sparse_core_tb.v
vvp simv
```

#### Expected output

```text
[PASS] TC01_dense_metadata packed metadata time=266000
[PASS] TC01_dense_outputs outputs time=426000
[PASS] TC02_sparse_metadata packed metadata time=736000
[PASS] TC02_sparse_outputs outputs time=896000
[PASS] TC03_sparse_single_row_metadata packed metadata time=1206000
[PASS] TC03_sparse_single_row_outputs outputs time=1366000
============================================================
TB SUMMARY: total=6 pass=6 fail=0
============================================================
ALL TESTS PASSED
lutein_sparse_core_tb.v:477: $finish called at 1465000 (1ps)
```
