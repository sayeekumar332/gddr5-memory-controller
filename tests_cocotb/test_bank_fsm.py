"""cocotb tests for gddr5_bank_fsm.

The reference model works from absolute cycle numbers: it remembers when each
command was issued and answers "may command X be issued in cycle N?" with
N >= t_issue + spacing. The RTL does the same job with down-counters, so the two
share no structure. Every cycle the DUT's can_* flags, state, row and error
outputs are compared with the model.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

S_IDLE, S_ACTIVATING, S_ACTIVE, S_PRECHARGE, S_REFRESH = range(5)
NEVER = -10**9


class BankModel:
    def __init__(self, p):
        self.p = p
        self.reset()

    def reset(self):
        self.phase = "idle"        # idle | open | pre | ref
        self.act_t = NEVER
        self.rd_t = NEVER
        self.wr_t = NEVER
        self.pre_t = NEVER         # cycle PRE (or auto-PRE) took effect
        self.ref_t = NEVER
        self.ap_pending = False
        self.row_valid = False
        self.open_row = 0
        self.err_next = 0          # cmd_err expected next cycle

    @staticmethod
    def _eff(n):
        return max(n, 1)           # a spacing of 0 or 1 both mean "next cycle"

    def idle(self, now):
        p = self.p
        if self.phase == "idle":
            return True
        if self.phase == "pre":
            return now >= self.pre_t + self._eff(p["TRP"])
        if self.phase == "ref":
            return now >= self.ref_t + self._eff(p["TRFCPB"])
        return False

    def flags(self, now):
        p, e = self.p, self._eff
        is_open = self.phase == "open"
        pre_ok = max(self.act_t + e(p["TRAS"]),
                     self.rd_t + e(p["TRTP"]),
                     self.wr_t + e(p["TW2PRE"]))
        f = {
            "can_rd": is_open and now >= self.act_t + e(p["TRCDRD"]) and not self.ap_pending,
            "can_wr": is_open and now >= self.act_t + e(p["TRCDWR"]) and not self.ap_pending,
            "can_pre": is_open and now >= pre_ok,
            "idle": self.idle(now),
        }
        f["can_act"] = f["idle"] and now >= self.act_t + e(p["TRC"])
        f["can_refpb"] = f["can_act"]
        if is_open:
            done = now >= self.act_t + max(e(p["TRCDRD"]), e(p["TRCDWR"]))
            f["state"] = S_ACTIVE if done else S_ACTIVATING
        elif f["idle"]:
            f["state"] = S_IDLE
        else:
            f["state"] = S_PRECHARGE if self.phase == "pre" else S_REFRESH
        return f

    def step(self, now, cmd, ap, row):
        """Apply one cycle. cmd is None or one of act/rd/wr/pre/refpb."""
        f = self.flags(now)
        legal = {"act": f["can_act"], "rd": f["can_rd"], "wr": f["can_wr"],
                 "pre": f["can_pre"], "refpb": f["can_refpb"]}
        self.err_next = int(cmd is not None and not legal[cmd])

        # Phase 1: resolve elapsed timers into the stored phase.
        if self.phase in ("pre", "ref") and f["idle"]:
            self.phase = "idle"

        # Phase 2: auto-precharge fires as soon as PRE would be legal.
        if self.ap_pending and f["can_pre"]:
            self.phase, self.pre_t = "pre", now
            self.row_valid, self.ap_pending = False, False

        # Phase 3: the command itself.
        if cmd is not None and legal[cmd]:
            if cmd == "act":
                self.phase, self.act_t = "open", now
                self.rd_t = self.wr_t = NEVER
                self.row_valid, self.open_row, self.ap_pending = True, row, False
            elif cmd == "rd":
                self.rd_t = now
                self.ap_pending = self.ap_pending or ap
            elif cmd == "wr":
                self.wr_t = now
                self.ap_pending = self.ap_pending or ap
            elif cmd == "pre":
                self.phase, self.pre_t = "pre", now
                self.row_valid, self.ap_pending = False, False
            elif cmd == "refpb":
                self.phase, self.ref_t = "ref", now


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for sig in (dut.act, dut.rd, dut.wr, dut.ap, dut.pre, dut.refpb):
        sig.value = 0
    dut.row.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


def params(dut):
    return {k: int(getattr(dut, k).value) for k in
            ("TRCDRD", "TRCDWR", "TRAS", "TRC", "TRP", "TRTP", "TW2PRE", "TRFCPB")}


def compare(dut, model, now, row_in, what):
    f = model.flags(now)
    got = {
        "can_act": int(dut.can_act.value), "can_rd": int(dut.can_rd.value),
        "can_wr": int(dut.can_wr.value), "can_pre": int(dut.can_pre.value),
        "can_refpb": int(dut.can_refpb.value), "idle": int(dut.idle.value),
        "state": int(dut.state.value),
    }
    for k, v in got.items():
        assert v == int(f[k]), f"{what} cycle {now}: {k} dut={v} model={int(f[k])}"
    assert int(dut.row_valid.value) == int(model.row_valid), f"{what} cycle {now}: row_valid"
    if model.row_valid:
        assert int(dut.open_row.value) == model.open_row, f"{what} cycle {now}: open_row"
    hit = int(model.row_valid and row_in == model.open_row)
    assert int(dut.row_hit.value) == hit, f"{what} cycle {now}: row_hit"
    assert int(dut.cmd_err.value) == model.err_next_seen, f"{what} cycle {now}: cmd_err"
    return f


async def drive_random(dut, cycles, seed, p_cmd, p_illegal, p_reset, what):
    rng = random.Random(seed)
    model = BankModel(params(dut))
    model.err_next_seen = 0
    counts = {"act": 0, "rd": 0, "wr": 0, "pre": 0, "refpb": 0, "ap_fire": 0, "illegal": 0}
    await FallingEdge(dut.clk)
    for now in range(cycles):
        row_in = rng.choice([0x000, 0x001, 0x155, 0x2155, 0x3FFF])
        dut.row.value = row_in
        await Timer(1, unit="ns")   # let the combinational row_hit settle
        f = compare(dut, model, now, row_in, what)

        cmd, ap = None, 0
        if rng.random() < p_cmd:
            legal = [c for c, k in (("act", "can_act"), ("rd", "can_rd"), ("wr", "can_wr"),
                                    ("pre", "can_pre"), ("refpb", "can_refpb")) if f[k]]
            if rng.random() < p_illegal:
                cmd = rng.choice(["act", "rd", "wr", "pre", "refpb"])
            elif legal:
                cmd = rng.choice(legal)
            ap = int(rng.random() < 0.15)

        do_reset = rng.random() < p_reset
        for name in ("act", "rd", "wr", "pre", "refpb"):
            getattr(dut, name).value = int(cmd == name)
        dut.ap.value = ap
        dut.rst_n.value = 0 if do_reset else 1

        if do_reset:
            model.reset()
            model.err_next_seen = 0
        else:
            was_ap = model.ap_pending and f["can_pre"]
            if cmd is not None and not f[{"act": "can_act", "rd": "can_rd", "wr": "can_wr",
                                          "pre": "can_pre", "refpb": "can_refpb"}[cmd]]:
                counts["illegal"] += 1
            elif cmd is not None:
                counts[cmd] += 1
            counts["ap_fire"] += int(was_ap)
            model.step(now, cmd, ap, row_in)
            model.err_next_seen = model.err_next
        await FallingEdge(dut.clk)
    return counts


@cocotb.test()
async def reset_state(dut):
    """After reset the bank is idle with no open row."""
    await start(dut)
    await FallingEdge(dut.clk)
    assert int(dut.state.value) == S_IDLE
    assert int(dut.row_valid.value) == 0
    assert int(dut.can_act.value) == 1
    assert int(dut.can_rd.value) == 0


@cocotb.test()
async def random_legal_traffic(dut):
    """Mostly legal commands; flags must match the model every cycle."""
    await start(dut)
    counts = await drive_random(dut, 6000, seed=1, p_cmd=0.6, p_illegal=0.0,
                                p_reset=0.0, what="legal")
    dut._log.info("command counts: %s", counts)
    for k in ("act", "rd", "wr", "pre", "refpb", "ap_fire"):
        assert counts[k] > 20, f"coverage: {k} only {counts[k]} times"


@cocotb.test()
async def random_with_illegal_commands(dut):
    """Illegal strobes must be ignored and flagged on cmd_err."""
    await start(dut)
    counts = await drive_random(dut, 6000, seed=2, p_cmd=0.7, p_illegal=0.4,
                                p_reset=0.0, what="illegal")
    dut._log.info("command counts: %s", counts)
    assert counts["illegal"] > 200, "coverage: too few illegal strobes"


@cocotb.test()
async def random_with_resets(dut):
    """Reset can arrive at any point and must clear all state."""
    await start(dut)
    await drive_random(dut, 6000, seed=3, p_cmd=0.6, p_illegal=0.1,
                       p_reset=0.01, what="reset")
