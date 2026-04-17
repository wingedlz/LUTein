# 🔷 LUTein Sparse Core (Verilog Implementation)

This project implements a simplified version of a **Radix-4 LUT-based Slice-Tensor Processing Units** inspired by the LUTein architecture(https://ieeexplore.ieee.org/document/10476468?denied=).

The focus is on:
- implementing and testing the functionality of Radix-4 LUT-based PE unit
- Dense / Sparse mode
- RLE (Run-Length Encoding) based compaction
- Zero-Skipping (ZS)
- Indexed sparse weight access
- Verilog-based hardware validation using Icarus Verilog

---

## 🚀 Overview

This repository contains a step-by-step implementation of a **4×4 PE array** supporting:

### ✅ Dense Mode
- Standard systolic-style data propagation
- Columnwise weight broadcasting

### ✅ Sparse Mode
- Zero-row detection & Zero-skipping
- RLE unit activated
- Indexed weight fetching (`weight[col][row_idx]`)
- Zero-skipping execution

---

## 🧠 Architecture

### 🔹 Dataflow
<img width="760" height="1074" alt="image" src="https://github.com/user-attachments/assets/80e8971b-2eb7-4527-8234-5344013265db" />

---

### 🔹 Key Components

| Module | Description |
|------|------------|
| `lutein_sparse_rle_core_4x4` | Top-level core |
| `RLE Compactor` | Removes zero rows and packs valid inputs |
| `Sparse Weight Bank` | Stores weights indexed by original row index |
| `Systolic Pipeline` | Propagates data and index across columns |
| `lutein_slice_tensor_pe` | Processing Element (MAC unit) |

---

## ⚙️ Features


## 🔍 RLE + ZS Implementation

### Dense
Row0 → PE
Row1 → PE (even if zero)
Row2 → PE
Row3 → PE


### Sparse
Row0 → Slot0
Row2 → Slot1
Row3 → Slot2
(empty) → Slot3


- Slot index ≠ row index
- Original index is preserved and used for weight lookup

## 🧪 Simulation

### Requirements
- Icarus Verilog (`iverilog`)
- GTKWave (optional)

### 1. PE testbench

Run the PE testbench with:

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

Run the sparse core testbench with:

```bash
iverilog -g2012 -o simv pe_modules.v lutein_dense_core.v lutein_dense_core_tb.v
```

#### Expected output

```text
[PASS] dense tile check passed at time=146
[DONE] dense core tb finished
lutein_dense_core_tb.v:191: $finish called at 185 (1s)
```

### 3. Sparse core testbench

Run the sparse core testbench with:

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
