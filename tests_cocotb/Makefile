# cocotb tests (Icarus Verilog, Verilog-2005)
#   make                       run the gddr5_cmd_enc tests
#   make DUT=bank_fsm          run the gddr5_bank_fsm tests
#   make DUT=bank_fsm TAG=_small PARAMS="-Pgddr5_bank_fsm.TRCDRD=4 ..."
#                              same tests with other timing parameters
#   make clean                 remove build output

SIM                 ?= icarus
TOPLEVEL_LANG       = verilog
DUT                 ?= cmd_enc
TAG                 ?=

RTL_DIR             := $(abspath $(CURDIR)/../rtl)

ifeq ($(DUT),cmd_enc)
TOPLEVEL            = gddr5_cmd_enc
COCOTB_TEST_MODULES = test_cmd_enc
else ifeq ($(DUT),bank_fsm)
TOPLEVEL            = gddr5_bank_fsm
COCOTB_TEST_MODULES = test_bank_fsm
else
$(error unknown DUT '$(DUT)')
endif

VERILOG_SOURCES     = $(RTL_DIR)/$(TOPLEVEL).v
COMPILE_ARGS       += -g2005 -I$(RTL_DIR) $(PARAMS)
SIM_BUILD           = sim_build_$(DUT)$(TAG)
COCOTB_RESULTS_FILE = results_$(DUT)$(TAG).xml

include $(shell cocotb-config --makefiles)/Makefile.sim

clean::
	rm -rf sim_build_* results_*.xml results.xml __pycache__
