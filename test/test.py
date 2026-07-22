# SPDX-FileCopyrightText: © 2026 ned
# SPDX-License-Identifier: Apache-2.0
"""
Tests for the Solaris 4x4 int8 systolic array.

Everything here drives only the real chip pins, so the identical suite runs
against the RTL and against the post-layout gate-level netlist:

    make              # RTL
    make GATES=yes    # gate level

The design is a matrix multiply engine. There is no way to check it by eyeballing
a waveform, so every test compares against an independently computed reference.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

# Must match the N baked into src/tt_um_mainpath_solaris.v
N = 4
AW = 32
NN = N * N
RESBYTES = NN * (AW // 8)

CLK_NS = 100  # 10 MHz -- comfortable for gate-level sim

# How long to wait after a clock edge before sampling an output.
#
# This must exceed the combinational settling time of the DUT. In RTL
# simulation signals settle instantly and any tiny value works -- which is
# exactly why a too-small value passes RTL and fails gate level. The gate-level
# build compiles with UNIT_DELAY=#1, giving every cell real propagation delay,
# and a 1 ns sample caught uo_out mid-flight: every result came back shifted one
# byte position (got == expected * 256 + 0xFF), because the byte read was the
# previous one. 20 ns is comfortably past settling and well short of CLK_NS.
SETTLE_NS = 20

# uio_in control bits
WR, START, RD, RSTPTR = 2, 3, 4, 5


def ctrl(wr=0, start=0, rd=0, rst_ptr=0):
    return (wr << WR) | (start << START) | (rd << RD) | (rst_ptr << RSTPTR)


def ref_matmul(A, B):
    """Plain nested-loop reference. Deliberately not numpy: the point is an
    independent implementation, and it keeps the test dependency-free."""
    return [[sum(A[i][k] * B[k][j] for k in range(N)) for j in range(N)]
            for i in range(N)]


async def reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def rewind(dut):
    dut.uio_in.value = ctrl(rst_ptr=1)
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0
    await RisingEdge(dut.clk)


async def load(dut, A, B):
    """A row-major then B row-major, one byte per clock."""
    stream = [v & 0xFF for row in A for v in row] + \
             [v & 0xFF for row in B for v in row]
    for byte in stream:
        dut.ui_in.value = byte
        dut.uio_in.value = ctrl(wr=1)
        await RisingEdge(dut.clk)
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    await RisingEdge(dut.clk)


async def compute(dut, timeout=500):
    dut.uio_in.value = ctrl(start=1)
    await RisingEdge(dut.clk)
    dut.uio_in.value = 0
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        await Timer(SETTLE_NS, unit="ns")
        if int(dut.uio_out.value) & 0b10:      # DONE
            return
    raise TimeoutError("DONE never asserted")


async def read_results(dut):
    await rewind(dut)
    # uo_out is REGISTERED, so one priming clock is needed before the first byte
    # is on the pin. Without it you read stale data and every result is shifted
    # by one byte.
    raw = []
    dut.uio_in.value = ctrl(rd=1)
    await RisingEdge(dut.clk)
    for _ in range(RESBYTES):
        await Timer(SETTLE_NS, unit="ns")
        raw.append(int(dut.uo_out.value) & 0xFF)
        await RisingEdge(dut.clk)
    dut.uio_in.value = 0

    out = []
    for w in range(NN):
        v = int.from_bytes(bytes(raw[w * 4:(w + 1) * 4]), "little")
        out.append(v - (1 << 32) if v & (1 << 31) else v)
    return [out[i * N:(i + 1) * N] for i in range(N)]


async def matmul(dut, A, B):
    await rewind(dut)
    await load(dut, A, B)
    await compute(dut)
    return await read_results(dut)


def show(name, M):
    return f"{name} =\n" + "\n".join("  " + " ".join(f"{v:>8}" for v in r) for r in M)


@cocotb.test()
async def test_identity(dut):
    """A @ I == A. The one case verifiable by inspection, so it is the first
    thing to check on a returned chip."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await reset(dut)

    A = [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13, 14, 15, 16]]
    ident = [[1 if i == j else 0 for j in range(N)] for i in range(N)]

    got = await matmul(dut, A, ident)
    assert got == A, f"A @ I should equal A\n{show('expected', A)}\n{show('got', got)}"
    dut._log.info("A @ I == A")


@cocotb.test()
async def test_random(dut):
    """Random signed int8 matrices against an independent reference."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await reset(dut)

    rng = random.Random(0x50142)
    for trial in range(4):
        A = [[rng.randint(-128, 127) for _ in range(N)] for _ in range(N)]
        B = [[rng.randint(-128, 127) for _ in range(N)] for _ in range(N)]

        got = await matmul(dut, A, B)
        want = ref_matmul(A, B)
        assert got == want, (f"trial {trial}\n{show('A', A)}\n{show('B', B)}\n"
                             f"{show('expected', want)}\n{show('got', got)}")
    dut._log.info("4 random 4x4 int8 matmuls correct")


@cocotb.test()
async def test_extremes(dut):
    """All -128: every product is +16384 and 4 accumulate, so |C| = 65536.
    That overflows a 16-bit accumulator by 2x -- this is the check that the
    32-bit accumulator and the signed byte-serial readout both survive."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await reset(dut)

    A = [[-128] * N for _ in range(N)]
    B = [[-128] * N for _ in range(N)]

    got = await matmul(dut, A, B)
    want = ref_matmul(A, B)
    assert got == want, f"{show('expected', want)}\n{show('got', got)}"
    dut._log.info("peak |C| = %d, survives 32-bit accumulate and readout",
                  max(abs(v) for r in want for v in r))


@cocotb.test()
async def test_back_to_back(dut):
    """Three matmuls with no chip reset between them. Catches accumulators that
    do not clear, pointers that do not rewind, and a DONE flag that never drops
    -- the failure modes that make a returned chip look dead."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await reset(dut)

    rng = random.Random(0xBADC0DE)
    for tile in range(3):
        A = [[rng.randint(-64, 63) for _ in range(N)] for _ in range(N)]
        B = [[rng.randint(-64, 63) for _ in range(N)] for _ in range(N)]
        got = await matmul(dut, A, B)
        want = ref_matmul(A, B)
        assert got == want, (f"tile {tile} leaked state\n"
                             f"{show('expected', want)}\n{show('got', got)}")
    dut._log.info("3 consecutive matmuls, no reset -- no state leakage")


@cocotb.test()
async def test_uio_oe(dut):
    """uio_oe must be exactly 0b00000011. If the chip drives a pin the harness
    also drives, that is contention on real silicon."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await reset(dut)
    await Timer(SETTLE_NS, unit="ns")
    oe = int(dut.uio_oe.value)
    assert oe == 0b00000011, f"uio_oe = {oe:#010b}, expected 0b00000011"
    dut._log.info("uio_oe correct: [1:0] driven, [7:2] inputs")
