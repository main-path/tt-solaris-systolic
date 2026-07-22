<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

This is a **4×4 int8 systolic array** — a hardware matrix multiply engine, the
same structure used at the heart of AI accelerators. It computes `C = A × B` for
4×4 matrices of signed 8-bit integers, producing 32-bit signed results.

### The array

16 processing elements (PEs) in a 4×4 grid. Each PE does one multiply-accumulate
per clock and passes its operands onward:

```
        B (weights) flow south
              │  │  │  │
              ▼  ▼  ▼  ▼
A       ──►  PE─PE─PE─PE
(activations) │  │  │  │
        ──►  PE─PE─PE─PE
              │  │  │  │
        ──►  PE─PE─PE─PE
              │  │  │  │
        ──►  PE─PE─PE─PE
              │  │  │  │
              ▼  ▼  ▼  ▼
           results drain south
```

It is **output-stationary**: `C[i][j]` accumulates in place inside PE(i,j) while
operands stream past. Two details make it actually work:

- **Input skew.** A value entering the west edge takes `j` cycles to reach column
  `j`; one entering the north edge takes `i` cycles to reach row `i`. So for
  operands of the same `k` to *meet* at PE(i,j), row `i` of A is delayed `i`
  cycles and column `j` of B is delayed `j` cycles. Without this the array
  computes confidently wrong answers.
- **Diagonal clear wavefront.** PE(i,j) begins accumulating at cycle `i+j`, not
  cycle 0, so the "start a new accumulation" signal propagates diagonally with
  the data. A broadcast clear would zero half the array mid-computation.

Accumulators are 32-bit. They have to be: int8 × int8 is 16 bits, and four of
them accumulate, so worst case (`-128 × -128 × 4`) is 65,536 — which overflows a
16-bit accumulator by 2×.

### Getting data in and out of 8 pins

A 4×4 int8 array wants 32 bits of A **and** 32 bits of B every cycle. Tiny
Tapeout gives you 8 input pins. So the chip is:

```
byte-serial load ──► on-chip operand buffer ──► array at full internal rate
                                                        │
                     byte-serial readout ◄── result buffer
```

This is not a workaround for a toy — it is the real architecture in miniature.
Every practical accelerator looks like this, because off-chip bandwidth, not
arithmetic, is the binding constraint.

## How to test

All control is on the bidirectional pins; data moves on `ui_in` / `uo_out`.

| Pin | Direction | Function |
|---|---|---|
| `ui[7:0]` | in | data byte in |
| `uo[7:0]` | out | data byte out (registered) |
| `uio[0]` | out | BUSY — high while computing |
| `uio[1]` | out | DONE — latches when a result is ready |
| `uio[2]` | in | WR — write `ui_in` to the operand buffer |
| `uio[3]` | in | START — begin the multiply |
| `uio[4]` | in | RD — advance the result read pointer |
| `uio[5]` | in | RST_PTR — rewind both pointers |

### Sequence

1. **Rewind.** Pulse `RST_PTR` for one clock.
2. **Load 32 bytes.** Hold `WR` high and present one byte per clock: the 16
   bytes of A (row-major), then the 16 bytes of B (row-major). Values are signed
   two's-complement int8.
3. **Compute.** Pulse `START`. `BUSY` goes high; wait for `DONE`. Takes about 20
   clocks.
4. **Read 64 bytes.** Pulse `RST_PTR`, then hold `RD` high. **`uo_out` is
   registered, so the first byte appears one clock after `RD` is asserted**, then
   one byte per clock. You get 16 results of 4 bytes each, little-endian within
   each result, C in row-major order.

### Easiest first check

Load `A` = anything, `B` = the identity matrix. The output must equal `A`.
That is the one case you can verify by eye, so it is the right first thing to try
on real hardware.

Then try the overflow case: set every element of both matrices to `-128`. Every
result should be exactly `65536` (`0x00010000`). If you instead read `0` or
`-32768`, the accumulator or the readout has a bug.

The included cocotb test bench (`test/test.py`) runs identity, random matrices
against an independent reference, the overflow extreme, and three back-to-back
multiplies with no reset in between. It runs against both the RTL and the
post-layout gate-level netlist.

## External hardware

None. Everything runs from the Tiny Tapeout demo board — the commander PCB or an
RP2040-based driver is enough to drive the pins and read results back.
