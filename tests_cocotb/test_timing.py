"""cocotb tests for gddr5_timing.

The reference model keeps the full history of recent commands and checks each
pair against the spacing rules (JESD212C.01 Table 9, tFAW and t32AW):
"may command X go to bank b in cycle N?" is true when, for every earlier
command E in the window, N >= t(E) + spacing(E, X, same_group). The RTL uses
down-counters and a slot array instead, so the two share no structure.
All 16 per-bank legality bits, pre_ok and cmd_err are compared every cycle.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

PARAM_NAMES = ("BG_ENABLE", "GROUP_LSB", "TRRDS", "TRRDL", "TFAW", "T32AW",
               "TCCDS", "TCCDL", "TW2RS", "TW2RL", "TRTW", "TPPD")


def eff(n):
    return max(n, 1)


class TimingModel:
    def __init__(self, p):
        self.p = p
        self.reset()

    def reset(self):
        self.acts = []      # (t, group)
        self.cols = []      # (t, "rd"|"wr", group)
        self.pres = []      # t
        self.err_next = 0

    def group(self, bank):
        p = self.p
        return (bank >> p["GROUP_LSB"]) & 3

    def same(self, ga, gb):
        return self.p["BG_ENABLE"] != 0 and ga == gb

    def act_ok(self, now, bank):
        p, g = self.p, self.group(bank)
        if sum(1 for t, _ in self.acts if now < t + eff(p["TFAW"])) >= 4:
            return False
        if sum(1 for t, _ in self.acts if now < t + eff(p["T32AW"])) >= 32:
            return False
        for t, ga in self.acts:
            need = eff(p["TRRDS"])
            if self.same(ga, g):
                need = max(need, eff(p["TRRDL"]))
            if now < t + need:
                return False
        return True

    def col_ok(self, now, bank, kind):
        p, g = self.p, self.group(bank)
        for t, k, ga in self.cols:
            if k == "rd" and kind == "rd":
                s, l = p["TCCDS"], p["TCCDL"]
            elif k == "wr" and kind == "wr":
                s, l = p["TCCDS"], p["TCCDL"]
            elif k == "wr" and kind == "rd":
                s, l = p["TW2RS"], p["TW2RL"]
            else:                                   # rd then wr
                s, l = p["TRTW"], 0
            need = eff(s)
            if self.same(ga, g):
                need = max(need, eff(l))
            if now < t + need:
                return False
        return True

    def pre_ok(self, now):
        return all(now >= t + eff(self.p["TPPD"]) for t in self.pres)

    def vectors(self, now):
        return (
            [self.act_ok(now, b) for b in range(16)],
            [self.col_ok(now, b, "rd") for b in range(16)],
            [self.col_ok(now, b, "wr") for b in range(16)],
            self.pre_ok(now),
        )

    def step(self, now, cmd, bank, vec):
        a, r, w, pr = vec
        legal = {"act": a[bank], "rd": r[bank], "wr": w[bank], "pre": pr}
        self.err_next = int(cmd is not None and not legal[cmd])
        if cmd is not None and legal[cmd]:
            g = self.group(bank)
            if cmd == "act":
                self.acts.append((now, g))
            elif cmd in ("rd", "wr"):
                self.cols.append((now, cmd, g))
            else:
                self.pres.append(now)
        horizon = max(self.p[k] for k in PARAM_NAMES if k not in ("BG_ENABLE", "GROUP_LSB")) + 8
        self.acts = [e for e in self.acts if now - e[0] < horizon]
        self.cols = [e for e in self.cols if now - e[0] < horizon]
        self.pres = [t for t in self.pres if now - t < horizon]


def params(dut):
    return {k: int(getattr(dut, k).value) for k in PARAM_NAMES}


def bits(sig):
    v = int(sig.value)
    return [bool((v >> i) & 1) for i in range(16)]


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.issue_act.value = 0
    dut.issue_rd.value = 0
    dut.issue_wr.value = 0
    dut.issue_pre.value = 0
    dut.bank.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def run(dut, cycles, seed, weights, p_illegal, p_reset, what):
    rng = random.Random(seed)
    model = TimingModel(params(dut))
    seen_err = 0
    # Start every run from a clean DUT.
    await FallingEdge(dut.clk)
    dut.issue_act.value = 0
    dut.issue_rd.value = 0
    dut.issue_wr.value = 0
    dut.issue_pre.value = 0
    dut.rst_n.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    cov = {"act": 0, "rd": 0, "wr": 0, "pre": 0, "illegal": 0, "faw_block": 0, "aw32_block": 0}
    await FallingEdge(dut.clk)
    for now in range(cycles):
        vec = model.vectors(now)
        a, r, w, pr = vec
        got = (bits(dut.act_ok), bits(dut.rd_ok), bits(dut.wr_ok), bool(int(dut.pre_ok.value)))
        for name, g, m in (("act_ok", got[0], a), ("rd_ok", got[1], r),
                           ("wr_ok", got[2], w)):
            assert g == m, f"{what} cycle {now}: {name} dut={g} model={m}"
        assert got[3] == pr, f"{what} cycle {now}: pre_ok dut={got[3]} model={pr}"
        assert int(dut.cmd_err.value) == seen_err, f"{what} cycle {now}: cmd_err"

        # Coverage: cycles where only a rolling window blocks an ACT.
        p = model.p
        spacing_ok = all(now >= t + eff(p["TRRDS"]) for t, _ in model.acts)
        if spacing_ok and not a[0]:
            n4 = sum(1 for t, _ in model.acts if now < t + eff(p["TFAW"]))
            n32 = sum(1 for t, _ in model.acts if now < t + eff(p["T32AW"]))
            if n32 >= 32:
                cov["aw32_block"] += 1
            elif n4 >= 4:
                cov["faw_block"] += 1

        cmd, bank = None, rng.randrange(16)
        if rng.random() < weights["p_cmd"]:
            kind = rng.choices(["act", "rd", "wr", "pre"], weights["mix"])[0]
            legal_banks = [b for b in range(16)
                           if {"act": a, "rd": r, "wr": w}.get(kind, [pr] * 16)[b]]
            if rng.random() < p_illegal:
                cmd = kind
            elif legal_banks:
                cmd, bank = kind, rng.choice(legal_banks)

        do_reset = rng.random() < p_reset
        dut.issue_act.value = int(cmd == "act")
        dut.issue_rd.value = int(cmd == "rd")
        dut.issue_wr.value = int(cmd == "wr")
        dut.issue_pre.value = int(cmd == "pre")
        dut.bank.value = bank
        dut.rst_n.value = 0 if do_reset else 1

        if do_reset:
            model.reset()
            seen_err = 0
        else:
            legal = {"act": a[bank], "rd": r[bank], "wr": w[bank], "pre": pr}
            if cmd is not None:
                cov["illegal" if not legal[cmd] else cmd] += 1
            model.step(now, cmd, bank, vec)
            seen_err = model.err_next
        await FallingEdge(dut.clk)
    return cov


MIX = {"p_cmd": 0.7, "mix": [3, 3, 3, 1]}
ACT_STORM = {"p_cmd": 1.0, "mix": [1, 0, 0, 0]}


@cocotb.test()
async def mixed_traffic(dut):
    """Legal traffic of all four command kinds."""
    await start(dut)
    cov = await run(dut, 5000, 1, MIX, 0.0, 0.0, "mixed")
    dut._log.info("coverage: %s", cov)
    for k in ("act", "rd", "wr", "pre"):
        assert cov[k] > 50, f"coverage: {k} only {cov[k]}"


@cocotb.test()
async def activate_storm(dut):
    """Back-to-back activates drive tFAW and t32AW to their limits."""
    await start(dut)
    cov = await run(dut, 4000, 2, ACT_STORM, 0.0, 0.0, "storm")
    dut._log.info("coverage: %s", cov)
    assert cov["faw_block"] > 10, "tFAW never limited an ACT"
    if int(dut.T32AW.value) > 8 * int(dut.TFAW.value):
        assert cov["aw32_block"] > 5, "t32AW never limited an ACT"


@cocotb.test()
async def illegal_strobes(dut):
    """Illegal strobes are ignored (no counter or window update) and flagged."""
    await start(dut)
    cov = await run(dut, 5000, 3, MIX, 0.35, 0.0, "illegal")
    assert cov["illegal"] > 200, "too few illegal strobes"
    cov = await run(dut, 4000, 4, ACT_STORM, 0.3, 0.0, "illegal-storm")
    assert cov["illegal"] > 50, "too few illegal ACT strobes"


@cocotb.test()
async def random_resets(dut):
    """Reset at random points clears all history."""
    await start(dut)
    await run(dut, 5000, 5, MIX, 0.1, 0.01, "reset")
