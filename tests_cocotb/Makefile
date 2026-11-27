# cocotb tests (Icarus Verilog, Verilog-2005)
#   make                       run the gddr5_cmd_enc tests
#   make DUT=bank_fsm          run the gddr5_bank_fsm tests
#   make DUT=ctrl_core        run the end-to-end controller-core tests
#   make DUT=ctrl_top         run the end-to-end top-level tests
#   make DUT=addr_map         run the gddr5_addr_map tests
#   make DUT=req_fifo         run the gddr5_req_fifo tests
#   make DUT=sched            run the gddr5_sched tests
#   make DUT=timing           run the gddr5_timing tests
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
else ifeq ($(DUT),timing)
TOPLEVEL            = gddr5_timing
COCOTB_TEST_MODULES = test_timing
else ifeq ($(DUT),sched)
TOPLEVEL            = gddr5_sched
COCOTB_TEST_MODULES = test_sched
else ifeq ($(DUT),ctrl_top)
TOPLEVEL            = gddr5_ctrl_top
COCOTB_TEST_MODULES = test_ctrl_top
else ifeq ($(DUT),addr_map)
TOPLEVEL            = gddr5_addr_map
COCOTB_TEST_MODULES = test_addr_map
else ifeq ($(DUT),req_fifo)
TOPLEVEL            = gddr5_req_fifo
COCOTB_TEST_MODULES = test_req_fifo
else ifeq ($(DUT),ctrl_core)
TOPLEVEL            = gddr5_ctrl_core
COCOTB_TEST_MODULES = test_ctrl_core
else
$(error unknown DUT '$(DUT)')
endif

ifneq ($(filter ctrl_core ctrl_top,$(DUT)),)
VERILOG_SOURCES     = $(filter-out %.vh,$(wildcard $(RTL_DIR)/*.v))
else
VERILOG_SOURCES     = $(RTL_DIR)/$(TOPLEVEL).v $(if $(filter timing,$(DUT)),$(RTL_DIR)/gddr5_act_window.v)
endif
COMPILE_ARGS       += -g2005 -I$(RTL_DIR) $(PARAMS)
SIM_BUILD           = sim_build_$(DUT)$(TAG)
COCOTB_RESULTS_FILE = results_$(DUT)$(TAG).xml

include $(shell cocotb-config --makefiles)/Makefile.sim

clean::
	rm -rf sim_build_* results_*.xml results.xml __pycache__
