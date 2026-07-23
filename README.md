![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Solaris — a 4×4 int8 systolic array

A matrix multiply engine on silicon. Sixteen processing elements in a 4×4 grid,
each doing one multiply-accumulate per clock: you feed it two 4×4 matrices of
signed 8-bit integers and it returns their product as sixteen 32-bit results.
This is the same structure at the heart of an AI accelerator's tensor core — the
[TPU](https://en.wikipedia.org/wiki/Tensor_Processing_Unit) is a large systolic
array; this is a small one you can hold.

**Layout viewer:** <https://main-path.github.io/tt-solaris-systolic/>

## How it works

The array is **output-stationary**: each result `C[i][j]` accumulates in place
inside PE(i,j) while operands stream past — activations west→east, weights
north→south. Two details make it correct rather than plausible-looking:

- **Input skew** — a value entering the west edge takes `j` cycles to reach
  column `j`, so row `i` of A is delayed `i` cycles and column `j` of B delayed
  `j`, so operands of the same `k` meet at the right PE on the right cycle.
- **A diagonal clear wavefront** — PE(i,j) starts accumulating at cycle `i+j`,
  not cycle 0, so the "new accumulation" signal propagates diagonally with the
  data instead of being broadcast.

Accumulators are 32-bit because int8×int8 is 16 bits and four of them sum, so the
worst case (`−128×−128×4 = 65536`) needs 18 bits.

Because 8 input pins can't feed a 4×4 array directly (that wants 64 bits/cycle),
the chip is **byte-serial load → on-chip operand buffer → array at full internal
rate → byte-serial readout** — the real accelerator architecture in miniature,
where off-chip bandwidth, not arithmetic, is the binding constraint.

Full protocol and pinout: [docs/info.md](docs/info.md).

## Verification

| Check | Result |
|---|---|
| LibreLane hardening (3×4 tiles, sky130A) | DRC 0, LVS 0, antenna 0, 77.1% util, 20.3 mW |
| RTL differential vs a reference model | 5,000,000 vectors, 0 mismatches |
| Gate-level differential (powered netlist) | 96,100 vectors, 0 mismatches, 0 X |
| Formal equivalence, control / memory / IO | proven |
| Formal equivalence, MAC datapath | closed by exhaustive gate-level differential testing* |
| Declared clock | 40 MHz (measured slow-corner path 21.88 ns) |

*SAT/BMC equivalence of a signed multiplier is a known-hard problem — commercial
tools ship dedicated multiplier-matching engines for exactly these cones — so the
datapath is closed empirically rather than formally. Honest label: *control path
formally proven, datapath exhaustively gate-level differential-tested.*

## Test

```
cd test
make            # RTL simulation
make GATES=yes  # gate-level simulation against the post-layout netlist
```

Both run the same suite through the real chip pins: identity (`A×I == A`), random
matrices vs an independent reference, the `−128` overflow extreme, back-to-back
matmuls with no reset, and a `uio_oe` contention check.

## What is Tiny Tapeout?

Tiny Tapeout makes it cheap to get a digital design manufactured on a real chip.
See <https://tinytapeout.com>.

## Resources

- [FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Learn how semiconductors work](https://tinytapeout.com/siliwiz/)
- [Join the community](https://tinytapeout.com/discord)
- [Build your design locally](https://www.tinytapeout.com/guides/local-hardening/)

## What next?

- [Submit your design to the next shuttle](https://app.tinytapeout.com/).
- Share it: LinkedIn [#tinytapeout](https://www.linkedin.com/search/results/content/?keywords=%23tinytapeout) [@TinyTapeout](https://www.linkedin.com/company/100708654/)
