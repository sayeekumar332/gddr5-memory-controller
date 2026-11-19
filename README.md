# gddr5-memory-controller

A GDDR5 SGRAM memory controller written in Verilog-2005, built to the JEDEC standard **JESD212C.01** and verified with a Verilog testbench, cocotb, pyuvm and assertion-based checks. Everything is simulated; there is no silicon or FPGA board validation.

> **Status:** early development. The microarchitecture specification (`docs/microarchitecture.md`) is drafted; RTL has not started. See the phase plan in that document.

## Reference

The JEDEC standard is not included in this repository. Download JESD212C.01 (*GDDR5 SGRAM*) from [jedec.org](https://www.jedec.org) (free registration). Design documents cite it by section number.

## Layout

| Path | Contents |
|---|---|
| `docs/` | Microarchitecture specification and design notes |
| `rtl/` | Synthesizable Verilog-2005 source |
| `tb/` | Verilog-2005 testbenches and the behavioral DRAM model |
| `tests_cocotb/` | cocotb unit and block tests |
| `tests_pyuvm/` | pyuvm environment (constrained-random, scoreboard, coverage) |
| `sva/` | Assertion/checker modules (SystemVerilog, simulation and formal only) |
| `scripts/` | Simulation, synthesis and CI helper scripts |

## Toolchain (all open source)

Icarus Verilog, Verilator, cocotb, pyuvm, cocotb-coverage, Yosys, SymbiYosys, OpenSTA, OpenLane 2 (CI only). RTL is Verilog-2005 (`iverilog -g2005`). Setup scripts will arrive with the first RTL.

## Workflow

`main` is protected. All changes arrive through pull requests from feature branches. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Provenance

This project is developed by its owner with AI assistance. See [PROVENANCE.md](PROVENANCE.md).

## Licence

To be decided before the first release.
