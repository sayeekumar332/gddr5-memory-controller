"""cocotb tests for gddr5_addr_map.

The reference model is written the other way round from the RTL: it builds an
address from (bank, row, col) with an explicit encode function, and the test
checks that the RTL decodes it back. A decode that is not the inverse of the
encode, or a map that is not one to one, fails.
"""

import random

import cocotb
from cocotb.triggers import Timer


def params(dut):
    return (int(dut.MODE.value), int(dut.XOR_BANK.value),
            int(dut.ROW_W.value), int(dut.COL_W.value))


def encode(mode, xor, row_w, col_w, bank, row, col):
    """(bank, row, col) -> flat address."""
    raw = bank ^ (row & 3) if xor else bank        # undo the XOR (same operation)
    if mode == 0:
        low = (raw << col_w) | col
        return (row << (col_w + 4)) | low
    # mode 1: raw bank = {b[1:0], b[3:2]}, so b = {raw[1:0], raw[3:2]}
    b = ((raw & 3) << 2) | (raw >> 2)
    return (row << (col_w + 4)) | ((col >> 2) << 6) | (b << 2) | (col & 3)


async def decode(dut, addr):
    dut.addr.value = addr
    await Timer(1, unit="ns")
    return int(dut.bank.value), int(dut.row.value), int(dut.col.value)


@cocotb.test()
async def round_trip(dut):
    """Random (bank, row, col): encode, let the RTL decode, get the same triple."""
    mode, xor, row_w, col_w = params(dut)
    rng = random.Random(1)
    for _ in range(3000):
        bank, row, col = rng.randrange(16), rng.randrange(1 << row_w), rng.randrange(1 << col_w)
        got = await decode(dut, encode(mode, xor, row_w, col_w, bank, row, col))
        assert got == (bank, row, col), f"{(bank, row, col)} -> {got}"


@cocotb.test()
async def corners(dut):
    """All-zero, all-one and single-bit addresses."""
    mode, xor, row_w, col_w = params(dut)
    aw = row_w + col_w + 4
    for addr in [0, (1 << aw) - 1] + [1 << i for i in range(aw)]:
        bank, row, col = await decode(dut, addr)
        assert encode(mode, xor, row_w, col_w, bank, row, col) == addr, f"addr {addr:#x}"


@cocotb.test()
async def one_to_one(dut):
    """Distinct addresses give distinct (bank, row, col): sample a dense region."""
    mode, xor, row_w, col_w = params(dut)
    rng = random.Random(2)
    base = rng.randrange(1 << (row_w + col_w + 4 - 12)) << 12
    seen = set()
    for a in range(4096):
        seen.add(await decode(dut, base + a))
    assert len(seen) == 4096


@cocotb.test()
async def stream_locality(dut):
    """The point of each mode, seen on a linear stream of 64 addresses."""
    mode, xor, row_w, col_w = params(dut)
    banks = []
    for a in range(64):
        b, r, c = await decode(dut, a)
        banks.append(b)
    if mode == 0:
        assert len(set(banks)) == 1                      # one bank, one row
    else:
        groups = [b >> 2 for b in banks]
        # consecutive groups of 4 addresses go to different bank groups
        for i in range(0, 60, 4):
            assert groups[i] != groups[i + 4], f"group repeats at {i}"
        assert len(set(banks)) == 16
