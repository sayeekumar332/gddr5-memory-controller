# Top-level developer targets.
#   make lint      Verilator lint (Verilog-2005) of every RTL file
#   make sim       Verilog directed testbenches (Icarus, -g2005)
#   make cocotb    cocotb tests (Icarus)
#   make all       lint + sim + cocotb
#   make clean

IVERILOG ?= iverilog
VVP      ?= vvp
VERILATOR ?= verilator

RTL_FILES := $(filter-out %.vh,$(wildcard rtl/*.v))
BUILD     := build

CORE_SMALL := -Pgddr5_ctrl_core.TRCDRD=4 -Pgddr5_ctrl_core.TRCDWR=3 -Pgddr5_ctrl_core.TRAS=8 -Pgddr5_ctrl_core.TRC=14 -Pgddr5_ctrl_core.TRP=4 -Pgddr5_ctrl_core.TRTP=2 -Pgddr5_ctrl_core.TW2PRE=6 -Pgddr5_ctrl_core.TRFCPB=10 -Pgddr5_ctrl_core.TRRDS=2 -Pgddr5_ctrl_core.TRRDL=3 -Pgddr5_ctrl_core.TFAW=10 -Pgddr5_ctrl_core.T32AW=100 -Pgddr5_ctrl_core.TCCDS=2 -Pgddr5_ctrl_core.TCCDL=4 -Pgddr5_ctrl_core.TW2RS=6 -Pgddr5_ctrl_core.TW2RL=8 -Pgddr5_ctrl_core.TRTW=5 -Pgddr5_ctrl_core.TPPD=2
CORE_FAW   := -Pgddr5_ctrl_core.TRCDRD=2 -Pgddr5_ctrl_core.TRCDWR=2 -Pgddr5_ctrl_core.TRAS=4 -Pgddr5_ctrl_core.TRC=8 -Pgddr5_ctrl_core.TRP=2 -Pgddr5_ctrl_core.TRTP=1 -Pgddr5_ctrl_core.TW2PRE=3 -Pgddr5_ctrl_core.TRFCPB=10 -Pgddr5_ctrl_core.TRRDS=1 -Pgddr5_ctrl_core.TRRDL=2 -Pgddr5_ctrl_core.TFAW=24 -Pgddr5_ctrl_core.T32AW=60 -Pgddr5_ctrl_core.TCCDS=1 -Pgddr5_ctrl_core.TCCDL=2 -Pgddr5_ctrl_core.TW2RS=2 -Pgddr5_ctrl_core.TW2RL=3 -Pgddr5_ctrl_core.TRTW=3 -Pgddr5_ctrl_core.TPPD=1
CORE_W32   := -Pgddr5_ctrl_core.TRCDRD=2 -Pgddr5_ctrl_core.TRCDWR=2 -Pgddr5_ctrl_core.TRAS=4 -Pgddr5_ctrl_core.TRC=8 -Pgddr5_ctrl_core.TRP=2 -Pgddr5_ctrl_core.TRTP=1 -Pgddr5_ctrl_core.TW2PRE=3 -Pgddr5_ctrl_core.TRFCPB=10 -Pgddr5_ctrl_core.TRRDS=1 -Pgddr5_ctrl_core.TRRDL=2 -Pgddr5_ctrl_core.TFAW=8 -Pgddr5_ctrl_core.T32AW=150 -Pgddr5_ctrl_core.TCCDS=1 -Pgddr5_ctrl_core.TCCDL=2 -Pgddr5_ctrl_core.TW2RS=2 -Pgddr5_ctrl_core.TW2RL=3 -Pgddr5_ctrl_core.TRTW=3 -Pgddr5_ctrl_core.TPPD=1

.PHONY: all lint sim cocotb clean

all: lint sim cocotb

lint:
	@for f in $(RTL_FILES); do \
	  echo "lint $$f"; \
	  $(VERILATOR) --lint-only -Wall --language 1364-2005 -Irtl -y rtl $$f || exit 1; \
	done

TBS := tb_gddr5_cmd_enc tb_gddr5_bank_fsm tb_gddr5_act_window tb_gddr5_timing tb_gddr5_sched tb_gddr5_req_fifo

sim: $(addprefix $(BUILD)/,$(addsuffix .log,$(TBS)))

$(BUILD)/%.log: $(BUILD)/%.vvp
	$(VVP) $< | tee $@
	@grep -q '^PASS$$' $@

# Each testbench depends on every RTL file and header; Icarus compiles them all.
$(BUILD)/%.vvp: tb/%.v $(RTL_FILES) rtl/gddr5_cmds.vh
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2005 -Wall -Irtl -o $@ $(RTL_FILES) $<

# bank FSM tests run with the default timings and with two small sets
# (the second sets every spacing to 1 cycle, the smallest legal value).
BANK_SMALL := -Pgddr5_bank_fsm.TRCDRD=4 -Pgddr5_bank_fsm.TRCDWR=3 \
  -Pgddr5_bank_fsm.TRAS=8 -Pgddr5_bank_fsm.TRC=14 -Pgddr5_bank_fsm.TRP=4 \
  -Pgddr5_bank_fsm.TRTP=2 -Pgddr5_bank_fsm.TW2PRE=6 -Pgddr5_bank_fsm.TRFCPB=10
BANK_EDGE := -Pgddr5_bank_fsm.TRCDRD=1 -Pgddr5_bank_fsm.TRCDWR=1 \
  -Pgddr5_bank_fsm.TRAS=1 -Pgddr5_bank_fsm.TRC=1 -Pgddr5_bank_fsm.TRP=1 \
  -Pgddr5_bank_fsm.TRTP=1 -Pgddr5_bank_fsm.TW2PRE=1 -Pgddr5_bank_fsm.TRFCPB=1

# gddr5_timing variants: default values, small values where t32AW > 8*tFAW
# (so t32AW can bind), bank groups off, 8-bank grouping, and an unusual set in
# which the write-to-read and read-to-write spacings are shorter than tCCDL.
T := -Pgddr5_timing.
TIM_SMALL := $(T)TRRDS=2 $(T)TRRDL=3 $(T)TFAW=10 $(T)T32AW=100 $(T)TCCDS=2 \
  $(T)TCCDL=4 $(T)TW2RS=6 $(T)TW2RL=8 $(T)TRTW=5 $(T)TPPD=2
TIM_NOBG  := $(TIM_SMALL) $(T)BG_ENABLE=0
TIM_LSB1  := $(TIM_SMALL) $(T)GROUP_LSB=1
TIM_ODD   := $(TIM_SMALL) $(T)TCCDL=9 $(T)TW2RS=2 $(T)TW2RL=3 $(T)TRTW=2

cocotb:
	$(MAKE) -C tests_cocotb DUT=cmd_enc
	$(MAKE) -C tests_cocotb DUT=bank_fsm
	$(MAKE) -C tests_cocotb DUT=bank_fsm TAG=_small PARAMS="$(BANK_SMALL)"
	$(MAKE) -C tests_cocotb DUT=bank_fsm TAG=_edge PARAMS="$(BANK_EDGE)"
	$(MAKE) -C tests_cocotb DUT=timing
	$(MAKE) -C tests_cocotb DUT=timing TAG=_small PARAMS="$(TIM_SMALL)"
	$(MAKE) -C tests_cocotb DUT=timing TAG=_nobg PARAMS="$(TIM_NOBG)"
	$(MAKE) -C tests_cocotb DUT=timing TAG=_lsb1 PARAMS="$(TIM_LSB1)"
	$(MAKE) -C tests_cocotb DUT=timing TAG=_odd PARAMS="$(TIM_ODD)"
	$(MAKE) -C tests_cocotb DUT=sched
	$(MAKE) -C tests_cocotb DUT=sched TAG=_ap PARAMS="-Pgddr5_sched.AUTO_PRECHARGE=1"
	$(MAKE) -C tests_cocotb DUT=req_fifo
	$(MAKE) -C tests_cocotb DUT=req_fifo TAG=_d1 PARAMS="-Pgddr5_req_fifo.DEPTH=1"
	$(MAKE) -C tests_cocotb DUT=req_fifo TAG=_d16 PARAMS="-Pgddr5_req_fifo.DEPTH=16 -Pgddr5_req_fifo.WIDTH=26"
	$(MAKE) -C tests_cocotb DUT=req_fifo TAG=_d5 PARAMS="-Pgddr5_req_fifo.DEPTH=5 -Pgddr5_req_fifo.WIDTH=7"
	$(MAKE) -C tests_cocotb DUT=ctrl_core
	$(MAKE) -C tests_cocotb DUT=ctrl_core TAG=_ap PARAMS="-Pgddr5_ctrl_core.AUTO_PRECHARGE=1"
	$(MAKE) -C tests_cocotb DUT=ctrl_core TAG=_small PARAMS="$(CORE_SMALL)"
	$(MAKE) -C tests_cocotb DUT=ctrl_core TAG=_small_ap PARAMS="$(CORE_SMALL) -Pgddr5_ctrl_core.AUTO_PRECHARGE=1"
	$(MAKE) -C tests_cocotb DUT=ctrl_core TAG=_faw PARAMS="$(CORE_FAW)"
	$(MAKE) -C tests_cocotb DUT=ctrl_core TAG=_w32 PARAMS="$(CORE_W32)"

clean:
	rm -rf $(BUILD)
	$(MAKE) -C tests_cocotb clean
