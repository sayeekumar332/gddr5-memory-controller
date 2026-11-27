"""End-to-end cocotb tests for gddr5_ctrl_top (flat host address in, device pins out).

Checks, every cycle:

1. Mapping and order. The flat address is decoded in Python (written from the map
   definition, not from the RTL). The expected command sequence for each accepted
   host request comes from an open-row tracker, in host order.
2. Legality. Every issued command is legal for the bank and cross-bank reference
   models (absolute cycle numbers).
3. Pins. The encoder outputs one cycle later equal the encoder reference.
4. Flags. No error flag rises, `hold` silences the command bus, the FIFO level and
   `h_ready` agree with the number of requests accepted and completed, and every
   request completes.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from test_bank_fsm import BankModel
from test_cmd_enc import expected as pins_expected
from test_ctrl_core import BANK_PARAMS, KIND, NAME, plan
from test_timing import PARAM_NAMES as TIMING_PARAMS, TimingModel

ROW_W, COL_W = 14, 7


def decode(mode, xor, addr):
    """Flat address -> (bank, row, col), from the map definition."""
    row = addr >> (COL_W + 4)
    low = addr & ((1 << (COL_W + 4)) - 1)
    if mode == 0:
        col, bank = low & ((1 << COL_W) - 1), low >> COL_W
    else:
        col = ((low >> 6) << 2) | (low & 3)
        b = (low >> 2) & 15                       # bank field as it sits in the address
        bank = ((b & 3) << 2) | (b >> 2)          # group from the low bits
    if xor:
        bank ^= row & 3
    return bank, row, col


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.h_valid.value = 0
    dut.h_write.value = 0
    dut.h_addr.value = 0
    dut.hold.value = 0
    dut.abi_enable.value = 0
    dut.cke_n_in.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def run_traffic(dut, host_reqs, seed, p_send=0.7, p_hold_start=0.0, hold_len=8,
                      max_cycles=300000):
    rng = random.Random(seed)
    mode, xor = int(dut.MAP_MODE.value), int(dut.MAP_XOR.value)
    depth = int(dut.FIFO_DEPTH.value)
    ap_mode = int(dut.AUTO_PRECHARGE.value) != 0
    bank_p = {k: int(getattr(dut, k).value) for k in BANK_PARAMS}
    timing_p = {k: int(getattr(dut, k).value) for k in TIMING_PARAMS}
    bmodels = [BankModel(bank_p) for _ in range(16)]
    tmodel = TimingModel(timing_p)

    open_rows, expected_cmds = {}, []
    seen = done = accepted = hold_left = next_req = 0
    pending = None
    prev = None
    stats = {"full_cycles": 0, "max_level": 0, "held_with_work": 0, "ACT": 0, "PRE": 0}

    await FallingEdge(dut.clk)
    for now in range(max_cycles):
        if hold_left > 0:
            hold_left -= 1
            hold = 1
        elif rng.random() < p_hold_start:
            hold_left = rng.randint(1, hold_len)
            hold = 1
        else:
            hold = 0
        if pending is None and next_req < len(host_reqs) and rng.random() < p_send:
            pending = host_reqs[next_req]
        abi = rng.getrandbits(1)
        dut.hold.value = hold
        dut.abi_enable.value = abi
        dut.h_valid.value = int(pending is not None)
        if pending is not None:
            dut.h_write.value = int(pending[0])
            dut.h_addr.value = pending[1]
        await Timer(1, unit="ns")

        valid = int(dut.cmd_valid.value)
        code, bank, addr = int(dut.cmd.value), int(dut.cmd_bank.value), int(dut.cmd_addr.value)
        ready = int(dut.h_ready.value)
        level = int(dut.fifo_level.value)
        pins = (int(dut.cs_n.value), int(dut.ras_n.value), int(dut.cas_n.value),
                int(dut.we_n.value), int(dut.addr_ph1.value), int(dut.addr_ph2.value),
                int(dut.abi_n_ph1.value), int(dut.abi_n_ph2.value))

        if prev is not None:
            exp = pins_expected(*prev)
            assert pins == exp, f"cycle {now}: pins {pins} != {exp} for {prev}"
        for f in ("err_bank", "err_timing", "err_enc"):
            assert not int(getattr(dut, f).value), f"cycle {now}: {f}"
        assert 0 <= level <= depth, f"cycle {now}: level {level}"
        assert ready == int(level < depth), f"cycle {now}: h_ready {ready} at level {level}"
        assert level <= accepted - done, f"cycle {now}: level {level} > queued {accepted - done}"
        if accepted > done:
            assert int(dut.busy.value), f"cycle {now}: busy low with {accepted - done} requests queued"
        stats["full_cycles"] += level == depth
        stats["max_level"] = max(stats["max_level"], level)
        if hold and valid:
            raise AssertionError(f"cycle {now}: command issued during hold")
        if hold and int(dut.busy.value):
            stats["held_with_work"] += 1

        kind = None
        if valid:
            name = NAME[code]
            assert name in KIND, f"cycle {now}: unexpected {name}"
            kind, ap = KIND[name]
            assert seen < len(expected_cmds), f"cycle {now}: {name} with no request"
            assert (name, bank, addr) == expected_cmds[seen], (
                f"cycle {now}: issued {(name, bank, addr)}, expected {expected_cmds[seen]}")
            seen += 1
            key = name if name in ("ACT", "PRE") else "col"
            stats[key] = stats.get(key, 0) + 1
            tvec = tmodel.vectors(now)
            assert bmodels[bank].flags(now)["can_" + kind], f"cycle {now}: {name} bank-illegal"
            ok = {"act": tvec[0][bank], "rd": tvec[1][bank], "wr": tvec[2][bank],
                  "pre": tvec[3]}[kind]
            assert ok, f"cycle {now}: {name} violates a cross-bank spacing"
            if kind in ("rd", "wr"):
                done += 1
        else:
            tvec = tmodel.vectors(now)
            ap = 0
        for b in range(16):
            if valid and b == bank:
                bmodels[b].step(now, kind, ap, addr)
            else:
                bmodels[b].step(now, None, 0, 0)
        tmodel.step(now, kind, bank, tvec)
        prev = (NAME[code] if valid else "DES", bank if valid else 0, addr if valid else 0, abi)

        if pending is not None and ready:
            b, r, c = decode(mode, xor, pending[1])
            expected_cmds.extend(plan((pending[0], b, r, c), open_rows, ap_mode))
            accepted += 1
            next_req += 1
            pending = None

        if next_req == len(host_reqs) and pending is None and done == len(host_reqs) \
                and seen == len(expected_cmds) and not int(dut.busy.value):
            break
        await FallingEdge(dut.clk)
    else:
        raise AssertionError(f"timeout: {done} of {len(host_reqs)} requests complete")

    assert done == len(host_reqs)
    return stats


def addrs(rng, n, rows=4, span=1 << 25):
    """Random addresses concentrated on a few rows so that hits and misses both occur."""
    base_rows = [rng.randrange(1 << ROW_W) for _ in range(rows)]
    out = []
    for _ in range(n):
        row = rng.choice(base_rows)
        low = rng.randrange(1 << (COL_W + 4))
        out.append((rng.getrandbits(1), (row << (COL_W + 4)) | low))
    return out


@cocotb.test()
async def linear_stream(dut):
    """Sequential addresses, reads then writes."""
    await start(dut)
    reqs = [(0, a) for a in range(300)] + [(1, 5000 + a) for a in range(300)]
    stats = await run_traffic(dut, reqs, seed=1, p_send=1.0)
    dut._log.info("stats: %s", stats)


@cocotb.test()
async def random_addresses(dut):
    """Random flat addresses over a few rows, with hold bursts."""
    await start(dut)
    rng = random.Random(2)
    stats = await run_traffic(dut, addrs(rng, 1500), seed=2, p_send=0.8, p_hold_start=0.02)
    dut._log.info("stats: %s", stats)
    assert stats["held_with_work"] > 50
    assert stats["full_cycles"] > 50 or int(dut.FIFO_DEPTH.value) > 16


@cocotb.test()
async def burst_then_idle(dut):
    """Fill the FIFO with a burst, then let it drain."""
    await start(dut)
    rng = random.Random(3)
    stats = await run_traffic(dut, addrs(rng, 200), seed=3, p_send=1.0)
    assert stats["max_level"] == int(dut.FIFO_DEPTH.value)


@cocotb.test()
async def sparse(dut):
    """Few requests with long gaps."""
    await start(dut)
    rng = random.Random(4)
    stats = await run_traffic(dut, addrs(rng, 120, rows=16), seed=4, p_send=0.01)
    assert stats["max_level"] <= 2
