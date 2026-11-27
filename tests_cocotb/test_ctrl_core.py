"""End-to-end cocotb tests for gddr5_ctrl_core (request in, device pins out).

Four independent checks run on every cycle of every test:

1. Policy. A Python tracker of open rows predicts the exact command sequence
   each accepted request needs (row hit: column; empty bank: ACT, column; row
   miss: PRE, ACT, column; with auto-precharge: ACT, column). The issued
   commands must match that sequence in order, with the right bank and address.
2. Legality. Every issued command is checked against the bank reference model
   (test_bank_fsm) and the cross-bank reference model (test_timing), which use
   absolute cycle numbers instead of counters.
3. Pins. The encoder outputs one cycle later must equal the encoder reference
   (test_cmd_enc) for the issued command, with ABI on and off at random.
4. Flags. No illegal-strobe flag from any module may ever rise, and `hold`
   must silence the command bus.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from test_bank_fsm import BankModel
from test_cmd_enc import CMDS, expected as pins_expected
from test_timing import PARAM_NAMES as TIMING_PARAMS, TimingModel

BANK_PARAMS = ("TRCDRD", "TRCDWR", "TRAS", "TRC", "TRP", "TRTP", "TW2PRE", "TRFCPB")
NAME = {v: k for k, v in CMDS.items()}
# internal code -> (model command, auto-precharge)
KIND = {"ACT": ("act", 0), "PRE": ("pre", 0), "RD": ("rd", 0), "RDA": ("rd", 1),
        "WOM": ("wr", 0), "WOMA": ("wr", 1)}


def read_params(dut):
    bank = {k: int(getattr(dut, k).value) for k in BANK_PARAMS}
    timing = {k: int(getattr(dut, k).value) for k in TIMING_PARAMS}
    return bank, timing, int(dut.AUTO_PRECHARGE.value) != 0


def plan(req, open_rows, auto_precharge):
    """Commands one request needs, from the policy only. Updates open_rows."""
    write, bank, row, col = req
    col_name = {(0, 0): "RD", (0, 1): "RDA", (1, 0): "WOM", (1, 1): "WOMA"}[(int(write), int(auto_precharge))]
    seq = []
    cur = open_rows.get(bank)
    if cur is None:
        seq.append(("ACT", bank, row))
    elif cur != row:
        seq.append(("PRE", bank, 0))
        seq.append(("ACT", bank, row))
    seq.append((col_name, bank, col))
    open_rows[bank] = None if auto_precharge else row
    return seq


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.req_valid.value = 0
    dut.req_write.value = 0
    dut.req_bank.value = 0
    dut.req_row.value = 0
    dut.req_col.value = 0
    dut.hold.value = 0
    dut.abi_enable.value = 0
    dut.cke_n_in.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def run_traffic(dut, requests, seed, p_send=0.7, p_hold_start=0.0, hold_len=8,
                      max_cycles=200000):
    """Send `requests` and check everything. Returns statistics."""
    rng = random.Random(seed)
    bank_p, timing_p, ap_mode = read_params(dut)
    bmodels = [BankModel(bank_p) for _ in range(16)]
    tmodel = TimingModel(timing_p)

    open_rows = {}
    expected_cmds = []          # policy prediction, in order
    seen = 0                    # commands observed so far
    pending = None              # request currently on the bus
    next_req = 0
    hold_left = 0
    prev = None                 # (name, bank, addr, abi) issued in the previous cycle
    stats = {"requests": 0, "commands": 0, "hit": 0, "empty": 0, "miss": 0,
             "held_with_work": 0, "done": 0, "ACT": 0, "PRE": 0, "col": 0}
    first_cmd_cycle = None
    done = 0

    await FallingEdge(dut.clk)
    for now in range(max_cycles):
        # ---- drive this cycle's inputs ------------------------------------
        if hold_left > 0:
            hold_left -= 1
            hold = 1
        elif rng.random() < p_hold_start:
            hold_left = rng.randint(1, hold_len)
            hold = 1
        else:
            hold = 0
        if pending is None and next_req < len(requests) and rng.random() < p_send:
            pending = requests[next_req]
        abi = rng.getrandbits(1)
        dut.hold.value = hold
        dut.abi_enable.value = abi
        dut.req_valid.value = int(pending is not None)
        if pending is not None:
            dut.req_write.value = int(pending[0])
            dut.req_bank.value = pending[1]
            dut.req_row.value = pending[2]
            dut.req_col.value = pending[3]
        await Timer(1, unit="ns")          # combinational outputs settle

        # ---- sample ---------------------------------------------------------
        cmd_valid = int(dut.cmd_valid.value)
        code = int(dut.cmd.value)
        bank = int(dut.cmd_bank.value)
        addr = int(dut.cmd_addr.value)
        ready = int(dut.req_ready.value)
        pins = (int(dut.cs_n.value), int(dut.ras_n.value), int(dut.cas_n.value),
                int(dut.we_n.value), int(dut.addr_ph1.value), int(dut.addr_ph2.value),
                int(dut.abi_n_ph1.value), int(dut.abi_n_ph2.value))

        # 3. pins: the encoder reflects the previous cycle's command
        if prev is not None:
            exp = pins_expected(prev[0], prev[1], prev[2], prev[3])
            assert pins == exp, (f"cycle {now}: pins {pins} != {exp} for {prev}")
        # 4. flags
        assert not int(dut.err_bank.value), f"cycle {now}: err_bank"
        assert not int(dut.err_timing.value), f"cycle {now}: err_timing"
        assert not int(dut.err_enc.value), f"cycle {now}: err_enc"
        if hold and cmd_valid:
            raise AssertionError(f"cycle {now}: command issued while hold is high")
        if hold and int(dut.busy.value):
            stats["held_with_work"] += 1

        # ---- the command issued this cycle ----------------------------------
        cmd_kind = None
        if cmd_valid:
            name = NAME[code]
            assert name in KIND, f"cycle {now}: unexpected command {name}"
            cmd_kind, ap = KIND[name]
            # 1. policy
            assert seen < len(expected_cmds), f"cycle {now}: command {name} with no request"
            want = expected_cmds[seen]
            assert (name, bank, addr) == want, (
                f"cycle {now}: issued {(name, bank, addr)}, policy expects {want}")
            seen += 1
            stats["commands"] += 1
            stats["ACT" if name == "ACT" else "PRE" if name == "PRE" else "col"] += 1
            if first_cmd_cycle is None:
                first_cmd_cycle = now
            # 2. legality
            tvec = tmodel.vectors(now)
            assert bmodels[bank].flags(now)["can_" + cmd_kind], (
                f"cycle {now}: {name} to bank {bank} is not legal for the bank")
            tlegal = {"act": tvec[0][bank], "rd": tvec[1][bank], "wr": tvec[2][bank],
                      "pre": tvec[3]}[cmd_kind]
            assert tlegal, f"cycle {now}: {name} to bank {bank} violates a cross-bank spacing"
            if cmd_kind in ("rd", "wr"):
                done += 1
                stats["done"] += 1
        else:
            tvec = tmodel.vectors(now)
            ap = 0

        # model updates for this cycle
        for b in range(16):
            if cmd_valid and b == bank:
                bmodels[b].step(now, cmd_kind, ap, addr)
            else:
                bmodels[b].step(now, None, 0, 0)
        tmodel.step(now, cmd_kind, bank, tvec)

        if int(dut.req_done.value):
            assert cmd_valid and cmd_kind in ("rd", "wr"), f"cycle {now}: req_done without column"
        prev = (NAME[code] if cmd_valid else "DES", bank if cmd_valid else 0,
                addr if cmd_valid else 0, abi)

        # ---- handshake ---------------------------------------------------------
        if pending is not None and ready:
            cur = open_rows.get(pending[1])
            stats["empty" if cur is None else "hit" if cur == pending[2] else "miss"] += 1
            if ap_mode:
                stats["hit"] += 0
            expected_cmds.extend(plan(pending, open_rows, ap_mode))
            stats["requests"] += 1
            pending = None
            next_req += 1

        if next_req == len(requests) and pending is None and seen == len(expected_cmds) \
                and not int(dut.busy.value):
            break
        await FallingEdge(dut.clk)
    else:
        raise AssertionError(f"timeout: {seen} of {len(expected_cmds)} commands issued")

    assert seen == len(expected_cmds)
    assert done == len(requests), f"{done} column commands for {len(requests)} requests"
    stats["first_cmd_cycle"] = first_cmd_cycle
    return stats


def random_requests(rng, n, banks=range(16), rows=(0x0000, 0x0001, 0x2000, 0x3FFF)):
    return [(rng.getrandbits(1), rng.choice(list(banks)), rng.choice(rows),
             rng.randrange(128)) for _ in range(n)]


@cocotb.test()
async def single_read_and_write(dut):
    """A read to an empty bank, then a write to the same row."""
    await start(dut)
    stats = await run_traffic(dut, [(0, 5, 0x123, 0x2A), (1, 5, 0x123, 0x7F)], seed=1, p_send=1.0)
    ap = int(dut.AUTO_PRECHARGE.value)
    assert stats["ACT"] == (2 if ap else 1)
    assert stats["PRE"] == 0


@cocotb.test()
async def row_hit_stream(dut):
    """Same bank and row: one ACT, no PRE (open page)."""
    await start(dut)
    rng = random.Random(2)
    reqs = [(rng.getrandbits(1), 3, 0x0155, rng.randrange(128)) for _ in range(60)]
    stats = await run_traffic(dut, reqs, seed=2, p_send=1.0)
    if int(dut.AUTO_PRECHARGE.value):
        assert stats["ACT"] == 60
    else:
        assert stats["ACT"] == 1 and stats["PRE"] == 0 and stats["hit"] == 59


@cocotb.test()
async def row_conflict_stream(dut):
    """Alternating rows in one bank: PRE and ACT for every request after the first."""
    await start(dut)
    reqs = [(i & 1, 9, (0x0100, 0x0101)[i & 1], i % 128) for i in range(40)]
    stats = await run_traffic(dut, reqs, seed=3, p_send=1.0)
    if not int(dut.AUTO_PRECHARGE.value):
        assert stats["PRE"] == 39 and stats["ACT"] == 40 and stats["miss"] == 39


@cocotb.test()
async def bank_spread(dut):
    """Every bank in turn, several rounds: drives tRRD, tFAW and t32AW."""
    await start(dut)
    reqs = [((r + b) & 1, b, 0x0200 + r, (3 * b + r) % 128)
            for r in range(6) for b in range(16)]
    stats = await run_traffic(dut, reqs, seed=4, p_send=1.0)
    assert stats["ACT"] >= 96


@cocotb.test()
async def random_mixed(dut):
    """Random reads and writes over all banks and a few rows, with hold bursts."""
    await start(dut)
    rng = random.Random(5)
    stats = await run_traffic(dut, random_requests(rng, 1500), seed=5, p_send=0.7,
                              p_hold_start=0.02)
    dut._log.info("stats: %s", stats)
    assert stats["held_with_work"] > 50
    if not int(dut.AUTO_PRECHARGE.value):
        assert stats["hit"] > 20 and stats["miss"] > 100 and stats["empty"] > 10


@cocotb.test()
async def random_sparse(dut):
    """Few requests with long gaps: banks go idle between them."""
    await start(dut)
    rng = random.Random(6)
    await run_traffic(dut, random_requests(rng, 400, banks=range(4)), seed=6, p_send=0.04)


@cocotb.test()
async def reset_clears_state(dut):
    """After a reset in the middle of traffic the controller is idle again."""
    await start(dut)
    dut.req_valid.value = 1
    dut.req_bank.value = 2
    dut.req_row.value = 0x77
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert int(dut.busy.value) == 1
    dut.req_valid.value = 0
    dut.rst_n.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await Timer(1, unit="ns")
    assert int(dut.busy.value) == 0
    assert int(dut.cmd_valid.value) == 0
    assert int(dut.bank_idle.value) == 0xFFFF
