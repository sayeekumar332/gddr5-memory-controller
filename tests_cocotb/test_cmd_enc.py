"""cocotb tests for gddr5_cmd_enc.

The reference model below is written from JESD212C.01 Table 17 (section 7.1),
Table 6 (section 4.1) and section 4.2 as data tables, independently of the RTL's
case statement. Each vector is compared against the DUT's registered outputs.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

# Internal command codes (rtl/gddr5_cmds.vh)
CMDS = {
    "DES": 0, "NOP": 1, "MRS": 2, "ACT": 3, "RD": 4, "RDA": 5,
    "WOM": 6, "WOMA": 7, "WSM": 8, "WSMA": 9, "WDM": 10, "WDMA": 11,
    "RDTR": 12, "WRTR": 13, "PRE": 14, "PREALL": 15, "REFPB": 16,
    "REF": 17, "SRE": 18,
}

# Table 17: command pins (CS_n, RAS_n, CAS_n, WE_n)
PINS = {
    "DES": (1, 1, 1, 1), "NOP": (0, 1, 1, 1), "MRS": (0, 0, 0, 0),
    "ACT": (0, 0, 1, 1),
    "RD": (0, 1, 0, 1), "RDA": (0, 1, 0, 1), "RDTR": (0, 1, 0, 1),
    "WOM": (0, 1, 0, 0), "WOMA": (0, 1, 0, 0), "WSM": (0, 1, 0, 0),
    "WSMA": (0, 1, 0, 0), "WDM": (0, 1, 0, 0), "WDMA": (0, 1, 0, 0),
    "WRTR": (0, 1, 0, 0),
    "PRE": (0, 0, 1, 0), "PREALL": (0, 0, 1, 0),
    "REFPB": (0, 0, 0, 1), "REF": (0, 0, 0, 1), "SRE": (0, 0, 0, 1),
}

# Table 6: logical address bit on each physical pin, MSB first
PHASE1_ORDER = ["BA3", "BA2", "BA1", "BA0", "A12", "A11", "A10", "A9", "A8"]
PHASE2_ORDER = ["A3", "A4", "A5", "A2", "A13", "A6", "A0", "A1", "A7"]

# Mask variants: (A11, A10) and whether auto-precharge is on
WRITE_MASK = {"WOM": (0, 0, 0), "WOMA": (0, 0, 1), "WSM": (0, 1, 0),
              "WSMA": (0, 1, 1), "WDM": (1, 0, 0), "WDMA": (1, 0, 1)}


def logical_bits(name, bank, addr):
    """Return dict of logical pin values (BA3..BA0, A13..A0) for a command.

    Pins marked "V" (any valid level) in Table 17 are driven high by the RTL.
    """
    v = {f"BA{i}": 1 for i in range(4)}
    v.update({f"A{i}": 1 for i in range(14)})

    def set_bank():
        for i in range(4):
            v[f"BA{i}"] = (bank >> i) & 1

    def set_col():
        for i in range(8):
            v[f"A{i}"] = (addr >> i) & 1

    if name == "MRS":
        set_bank()
        for i in range(12):
            v[f"A{i}"] = (addr >> i) & 1
        v["A12"] = 0
        v["A13"] = 0
    elif name == "ACT":
        set_bank()
        for i in range(14):
            v[f"A{i}"] = (addr >> i) & 1
    elif name in ("RD", "RDA"):
        set_bank(); set_col()
        v["A11"], v["A10"], v["A8"] = 0, 0, int(name == "RDA")
    elif name in WRITE_MASK:
        a11, a10, ap = WRITE_MASK[name]
        set_bank(); set_col()
        v["A11"], v["A10"], v["A8"] = a11, a10, ap
    elif name in ("RDTR", "WRTR"):
        v["A11"], v["A10"], v["A8"] = 1, 1, 0
    elif name in ("PRE", "REFPB"):
        set_bank()
        v["A8"] = 0
    elif name in ("PREALL", "REF", "SRE"):
        v["A8"] = 1
    return v


def pack(order, v):
    return sum(v[n] << (len(order) - 1 - i) for i, n in enumerate(order))


def expected(name, bank, addr, abi, has_a12a13=1, abi_max_low=5):
    """Expected (cs, ras, cas, we, ph1, ph2, abi_n1, abi_n2) for one command."""
    v = logical_bits(name, bank, addr)
    ph = []
    abi_n = []
    for order in (PHASE1_ORDER, PHASE2_ORDER):
        word = pack(order, v)
        zeros = 0
        for i, n in enumerate(order):
            if n in ("A12", "A13") and not has_a12a13:
                continue
            if not (word >> (len(order) - 1 - i)) & 1:
                zeros += 1
        if abi and zeros > abi_max_low:
            word ^= 0x1FF
            abi_n.append(0)
        else:
            abi_n.append(1)
        ph.append(word)
    return PINS[name] + (ph[0], ph[1], abi_n[0], abi_n[1])


async def reset(dut):
    dut.rst_n.value = 0
    dut.cmd_valid.value = 0
    dut.cmd.value = 0
    dut.bank.value = 0
    dut.addr.value = 0
    dut.abi_enable.value = 0
    dut.cke_n_in.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def apply_and_read(dut, code, bank, addr, abi, valid=1):
    await FallingEdge(dut.clk)
    dut.cmd_valid.value = valid
    dut.cmd.value = code
    dut.bank.value = bank
    dut.addr.value = addr
    dut.abi_enable.value = abi
    await RisingEdge(dut.clk)
    await ReadOnly()
    return (int(dut.cs_n.value), int(dut.ras_n.value), int(dut.cas_n.value),
            int(dut.we_n.value), int(dut.addr_ph1.value), int(dut.addr_ph2.value),
            int(dut.abi_n_ph1.value), int(dut.abi_n_ph2.value),
            int(dut.cmd_err.value))


@cocotb.test()
async def random_vectors(dut):
    """Random bank/address for every supported command, ABI on and off."""
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset(dut)
    rng = random.Random(212)  # JESD212
    n = 0
    for _ in range(40):
        for name, code in CMDS.items():
            bank = rng.randrange(16)
            addr = rng.randrange(1 << 14)
            abi = rng.randrange(2)
            got = await apply_and_read(dut, code, bank, addr, abi)
            exp = expected(name, bank, addr, abi) + (0,)
            assert got == exp, (
                f"{name} bank={bank:#x} addr={addr:#06x} abi={abi}\n"
                f"  got      {got}\n  expected {exp}")
            n += 1
    dut._log.info("%d vectors checked", n)


@cocotb.test()
async def invalid_cycle_is_deselect(dut):
    """cmd_valid low drives DESELECT regardless of cmd."""
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset(dut)
    got = await apply_and_read(dut, CMDS["ACT"], 5, 0x1234, 0, valid=0)
    assert got[:4] == (1, 1, 1, 1) and got[8] == 0, got


@cocotb.test()
async def undefined_codes_flag_error(dut):
    """Reserved (LDFF) and undefined codes drive DESELECT and set cmd_err."""
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset(dut)
    for code in (19, 20, 25, 31):
        got = await apply_and_read(dut, code, 0, 0, 0)
        assert got[:4] == (1, 1, 1, 1), (code, got)
        assert got[8] == 1, (code, got)


@cocotb.test()
async def abi_never_exceeds_limit(dut):
    """With ABI on, no phase ever has more than 5 low pins (9-pin devices)."""
    cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
    await reset(dut)
    rng = random.Random(5)
    for _ in range(300):
        name = rng.choice(list(CMDS))
        got = await apply_and_read(dut, CMDS[name], rng.randrange(16),
                                   rng.randrange(1 << 14), 1)
        for ph in (got[4], got[5]):
            assert bin(ph ^ 0x1FF).count("1") <= 5, (name, got)
