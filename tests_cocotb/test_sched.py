"""cocotb tests for gddr5_sched.

Every cycle all inputs are randomised (bank flags, timing flags, open rows,
requests, hold) and the scheduler's outputs are compared with a reference
function written from the policy: row hit -> column command, row miss ->
PRECHARGE, empty bank -> ACTIVE, only when both legality flags are high.
The model also tracks the one request the scheduler holds.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

# Internal command codes (rtl/gddr5_cmds.vh)
NOP, ACT, RD, RDA, WOM, WOMA, PRE = 1, 3, 4, 5, 6, 7, 14
ROWS = [0x0000, 0x0001, 0x2000, 0x2001, 0x3FFF]


class SchedModel:
    def __init__(self, auto_precharge):
        self.ap = auto_precharge
        self.have = False
        self.req = None

    def outputs(self, i):
        """Expected combinational outputs for input dict i."""
        o = dict(cmd_valid=0, cmd=NOP, cmd_addr=0, bank_act=0, bank_rd=0, bank_wr=0,
                 bank_pre=0, t_act=0, t_rd=0, t_wr=0, t_pre=0, done=0)
        o["busy"] = int(self.have)
        o["bank_ap"] = int(self.ap)
        o["cmd_bank"] = self.req["bank"] if self.have else 0
        if self.have and not i["hold"]:
            r = self.req
            b = r["bank"]
            rv = (i["row_valid"] >> b) & 1
            open_row = (i["open_rows"] >> (14 * b)) & 0x3FFF
            hit = rv and open_row == r["row"]
            if r["write"]:
                col_ok = (i["can_wr"] >> b) & 1 and (i["t_wr_ok"] >> b) & 1
            else:
                col_ok = (i["can_rd"] >> b) & 1 and (i["t_rd_ok"] >> b) & 1
            sel = 1 << b
            if hit and col_ok:
                o.update(cmd_valid=1, done=1, cmd_addr=r["col"])
                if r["write"]:
                    o.update(cmd=WOMA if self.ap else WOM, bank_wr=sel, t_wr=1)
                else:
                    o.update(cmd=RDA if self.ap else RD, bank_rd=sel, t_rd=1)
            elif rv and not hit and (i["can_pre"] >> b) & 1 and i["t_pre_ok"]:
                o.update(cmd_valid=1, cmd=PRE, bank_pre=sel, t_pre=1)
            elif not rv and (i["can_act"] >> b) & 1 and (i["t_act_ok"] >> b) & 1:
                o.update(cmd_valid=1, cmd=ACT, cmd_addr=r["row"], bank_act=sel, t_act=1)
        o["req_ready"] = int((not self.have) or o["done"])
        return o

    def clock(self, i, o):
        if i["req_valid"] and o["req_ready"]:
            self.have = True
            self.req = dict(write=i["req_write"], bank=i["req_bank"],
                            row=i["req_row"], col=i["req_col"])
        elif o["done"]:
            self.have = False


def drive(dut, i):
    dut.req_valid.value = i["req_valid"]
    dut.req_write.value = i["req_write"]
    dut.req_bank.value = i["req_bank"]
    dut.req_row.value = i["req_row"]
    dut.req_col.value = i["req_col"]
    dut.hold.value = i["hold"]
    dut.bank_row_valid.value = i["row_valid"]
    dut.bank_open_row.value = i["open_rows"]
    dut.bank_can_act.value = i["can_act"]
    dut.bank_can_rd.value = i["can_rd"]
    dut.bank_can_wr.value = i["can_wr"]
    dut.bank_can_pre.value = i["can_pre"]
    dut.t_act_ok.value = i["t_act_ok"]
    dut.t_rd_ok.value = i["t_rd_ok"]
    dut.t_wr_ok.value = i["t_wr_ok"]
    dut.t_pre_ok.value = i["t_pre_ok"]


def random_inputs(rng, p_flag):
    def vec():
        return sum((rng.random() < p_flag) << k for k in range(16))
    open_rows = 0
    for b in range(16):
        open_rows |= rng.choice(ROWS) << (14 * b)
    return dict(
        req_valid=int(rng.random() < 0.6), req_write=rng.getrandbits(1),
        req_bank=rng.randrange(16), req_row=rng.choice(ROWS),
        req_col=rng.randrange(128), hold=int(rng.random() < 0.1),
        row_valid=sum((rng.random() < 0.6) << k for k in range(16)),
        open_rows=open_rows, can_act=vec(), can_rd=vec(), can_wr=vec(),
        can_pre=vec(), t_act_ok=vec(), t_rd_ok=vec(), t_wr_ok=vec(),
        t_pre_ok=int(rng.random() < p_flag),
    )


SIGNALS = {
    "req_ready": "req_ready", "cmd_valid": "cmd_valid", "cmd": "cmd",
    "cmd_bank": "cmd_bank", "cmd_addr": "cmd_addr", "bank_act": "bank_act",
    "bank_rd": "bank_rd", "bank_wr": "bank_wr", "bank_pre": "bank_pre",
    "bank_ap": "bank_ap", "t_act": "t_issue_act", "t_rd": "t_issue_rd",
    "t_wr": "t_issue_wr", "t_pre": "t_issue_pre", "busy": "busy", "done": "done",
}


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    drive(dut, random_inputs(random.Random(0), 0.5) | dict(req_valid=0))
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def run(dut, cycles, seed, p_flag, what):
    rng = random.Random(seed)
    model = SchedModel(int(dut.AUTO_PRECHARGE.value) != 0)
    cov = {"ACT": 0, "PRE": 0, "col": 0, "hold": 0, "taken_on_done": 0}
    await FallingEdge(dut.clk)
    for n in range(cycles):
        i = random_inputs(rng, p_flag)
        drive(dut, i)
        await Timer(1, unit="ns")
        o = model.outputs(i)
        for key, sig in SIGNALS.items():
            if key == "cmd_bank" and not o["cmd_valid"]:
                continue                      # bank is only meaningful with a command
            got = int(getattr(dut, sig).value)
            assert got == o[key], f"{what} cycle {n}: {sig} dut={got} model={o[key]}"
        if o["cmd"] == ACT:
            cov["ACT"] += 1
        elif o["cmd"] == PRE:
            cov["PRE"] += 1
        elif o["done"]:
            cov["col"] += 1
        cov["hold"] += int(i["hold"] and model.have)
        cov["taken_on_done"] += int(o["done"] and i["req_valid"])
        model.clock(i, o)
        await FallingEdge(dut.clk)
    return cov


@cocotb.test()
async def random_flags_mostly_ready(dut):
    """Legality flags are usually high, so requests make progress."""
    await start(dut)
    cov = await run(dut, 20000, 1, 0.85, "ready")
    dut._log.info("coverage: %s", cov)
    for k in ("ACT", "PRE", "col", "hold", "taken_on_done"):
        assert cov[k] > 100, f"coverage: {k} only {cov[k]}"


@cocotb.test()
async def random_flags_mostly_blocked(dut):
    """Flags are usually low: the scheduler must wait without issuing."""
    await start(dut)
    cov = await run(dut, 20000, 2, 0.25, "blocked")
    dut._log.info("coverage: %s", cov)
    assert cov["ACT"] > 50 and cov["col"] > 50 and cov["PRE"] > 50


@cocotb.test()
async def reset_mid_request(dut):
    """Reset drops the held request."""
    await start(dut)
    rng = random.Random(3)
    i = random_inputs(rng, 1.0) | dict(req_valid=1, hold=1)
    drive(dut, i)
    await FallingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert int(dut.busy.value) == 1
    dut.rst_n.value = 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await Timer(1, unit="ns")
    assert int(dut.busy.value) == 0
    assert int(dut.req_ready.value) == 1
