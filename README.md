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

---

## 🧪 Simulation

### Requirements
- Icarus Verilog (iverilog)
- GTKWave (optional)

### Run

```bash
iverilog -g2012 -o simv pe_modules.v lutein_sparse_core.v
vvp simv


### Expected Output
[PASS] mode=0 time=295000
[PASS] mode=1 time=395000
[DONE] sparse rle core tb finished
lutein_sparse_core.v:490: $finish called at 395000 (1ps) 
