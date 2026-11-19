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
	  $(VERILATOR) --lint-only -Wall --language 1364-2005 -Irtl $$f || exit 1; \
	done

sim: $(BUILD)/tb_gddr5_cmd_enc.vvp
	$(VVP) $< | tee $(BUILD)/tb_gddr5_cmd_enc.log
	@grep -q '^PASS$$' $(BUILD)/tb_gddr5_cmd_enc.log

$(BUILD)/tb_gddr5_cmd_enc.vvp: rtl/gddr5_cmd_enc.v rtl/gddr5_cmds.vh tb/tb_gddr5_cmd_enc.v
	@mkdir -p $(BUILD)
	$(IVERILOG) -g2005 -Wall -Irtl -o $@ rtl/gddr5_cmd_enc.v tb/tb_gddr5_cmd_enc.v

cocotb:
	$(MAKE) -C tests_cocotb

clean:
	rm -rf $(BUILD)
	$(MAKE) -C tests_cocotb clean
