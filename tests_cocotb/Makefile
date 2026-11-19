# cocotb test of gddr5_cmd_enc (Icarus Verilog, Verilog-2005)
#   make            run the tests
#   make clean      remove build output

SIM                 ?= icarus
TOPLEVEL_LANG       = verilog
TOPLEVEL            = gddr5_cmd_enc
COCOTB_TEST_MODULES = test_cmd_enc

RTL_DIR             := $(abspath $(CURDIR)/../rtl)
VERILOG_SOURCES     = $(RTL_DIR)/gddr5_cmd_enc.v
COMPILE_ARGS       += -g2005 -I$(RTL_DIR)

include $(shell cocotb-config --makefiles)/Makefile.sim
