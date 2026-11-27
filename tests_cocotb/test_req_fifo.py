"""cocotb tests for gddr5_req_fifo against a Python queue model.

The model is a plain list. Each cycle the testbench decides what to drive, samples
the DUT's combinational outputs before the clock edge, applies the handshake rules
to the model, and compares: ready/valid flags, head data, and level.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.in_valid.value = 0
    dut.in_data.value = 0
    dut.out_ready.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def run(dut, cycles, p_push, p_pop, seed, stats=None, reset_at=()):
    rng = random.Random(seed)
    depth = int(dut.DEPTH.value)
    width = int(dut.WIDTH.value)
    model = []
    n_push = n_pop = n_full = n_empty = n_both = 0
    await FallingEdge(dut.clk)
    for now in range(cycles):
        if now in reset_at:
            dut.rst_n.value = 0
            await FallingEdge(dut.clk)
            dut.rst_n.value = 1
            model.clear()
        valid = int(rng.random() < p_push)
        ready = int(rng.random() < p_pop)
        data = rng.getrandbits(width)
        dut.in_valid.value = valid
        dut.in_data.value = data
        dut.out_ready.value = ready
        await Timer(1, unit="ns")

        in_ready = int(dut.in_ready.value)
        out_valid = int(dut.out_valid.value)
        assert in_ready == int(len(model) < depth), f"cycle {now}: in_ready {in_ready}, level {len(model)}"
        assert out_valid == int(len(model) > 0), f"cycle {now}: out_valid {out_valid}, level {len(model)}"
        assert int(dut.level.value) == len(model), f"cycle {now}: level {int(dut.level.value)} != {len(model)}"
        if model:
            assert int(dut.out_data.value) == model[0], \
                f"cycle {now}: head {int(dut.out_data.value):#x} != {model[0]:#x}"

        push = valid and in_ready
        pop = ready and out_valid
        n_full += len(model) == depth
        n_empty += len(model) == 0
        n_both += bool(push and pop)
        if pop:
            model.pop(0)
            n_pop += 1
        if push:
            model.append(data)
            n_push += 1
        await FallingEdge(dut.clk)

    if stats is not None:
        stats.update(push=n_push, pop=n_pop, full=n_full, empty=n_empty, both=n_both)


@cocotb.test()
async def balanced(dut):
    await start(dut)
    st = {}
    await run(dut, 4000, 0.5, 0.5, 1, st)
    dut._log.info("stats: %s", st)
    assert st["push"] > 500 and st["pop"] > 500
    if int(dut.DEPTH.value) > 1:
        assert st["both"] > 200      # at DEPTH 1 a push never coincides with a pop
    assert st["empty"] > 20 and st["full"] > 20 or int(dut.DEPTH.value) > 16


@cocotb.test()
async def fill_heavy(dut):
    """Producer faster than consumer: the FIFO sits full."""
    await start(dut)
    st = {}
    await run(dut, 3000, 0.9, 0.2, 2, st)
    assert st["full"] > 500


@cocotb.test()
async def drain_heavy(dut):
    """Consumer faster than producer: the FIFO sits empty."""
    await start(dut)
    st = {}
    await run(dut, 3000, 0.2, 0.9, 3, st)
    assert st["empty"] > 500


@cocotb.test()
async def line_rate(dut):
    """Both sides always ready: one entry per cycle once primed."""
    await start(dut)
    st = {}
    await run(dut, 1000, 1.0, 1.0, 4, st)
    if int(dut.DEPTH.value) > 1:
        assert st["both"] > 900      # one entry per cycle once primed
    else:
        assert st["pop"] > 450       # DEPTH 1: fill, drain, fill, ...


@cocotb.test()
async def resets(dut):
    """Resets in the middle of traffic empty the FIFO."""
    await start(dut)
    await run(dut, 2000, 0.6, 0.4, 5, reset_at=(300, 301, 900, 1500))
