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

.PHONY: all lint sim cocotb clean

all: lint sim cocotb

lint:
	@for f in $(RTL_FILES); do \
	  echo "lint $$f"; \
	  $(VERILATOR) --lint-only -Wall --language 1364-2005 -Irtl -y rtl $$f || exit 1; \
	done

TBS := tb_gddr5_cmd_enc tb_gddr5_bank_fsm tb_gddr5_act_window tb_gddr5_timing tb_gddr5_sched

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

clean:
	rm -rf $(BUILD)
	$(MAKE) -C tests_cocotb clean
