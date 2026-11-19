// gddr5_cmds.vh - internal command codes for the GDDR5 controller.
//
// These codes are internal to the controller; they are NOT device pin values.
// Pin-level encodings are produced by gddr5_cmd_enc from JESD212C.01 Table 17
// (section 7.1). Symbol names follow the standard's Table 17.
//
// Verilog-2005: macros are used instead of packages/enums.

`ifndef GDDR5_CMDS_VH
`define GDDR5_CMDS_VH

`define GDDR5_CMD_W      5

`define GDDR5_CMD_DES    5'd0    // DESELECT
`define GDDR5_CMD_NOP    5'd1    // NO OPERATION
`define GDDR5_CMD_MRS    5'd2    // MODE REGISTER SET
`define GDDR5_CMD_ACT    5'd3    // ACTIVE
`define GDDR5_CMD_RD     5'd4    // READ
`define GDDR5_CMD_RDA    5'd5    // READ with auto-precharge
`define GDDR5_CMD_WOM    5'd6    // WRITE without mask
`define GDDR5_CMD_WOMA   5'd7    // WRITE without mask, auto-precharge
`define GDDR5_CMD_WSM    5'd8    // WRITE with single-byte mask
`define GDDR5_CMD_WSMA   5'd9    // WRITE with single-byte mask, auto-precharge
`define GDDR5_CMD_WDM    5'd10   // WRITE with double-byte mask
`define GDDR5_CMD_WDMA   5'd11   // WRITE with double-byte mask, auto-precharge
`define GDDR5_CMD_RDTR   5'd12   // READ training
`define GDDR5_CMD_WRTR   5'd13   // WRITE training
`define GDDR5_CMD_PRE    5'd14   // PRECHARGE (one bank)
`define GDDR5_CMD_PREALL 5'd15   // PRECHARGE ALL
`define GDDR5_CMD_REFPB  5'd16   // PER-BANK REFRESH
`define GDDR5_CMD_REF    5'd17   // REFRESH (all banks)
`define GDDR5_CMD_SRE    5'd18   // SELF REFRESH ENTRY (CKE_n driven high by the power manager)
// 5'd19 is reserved for LDFF (load FIFO); its data-bit placement is an open
// item in docs/microarchitecture.md and it is not yet encoded.

`endif
