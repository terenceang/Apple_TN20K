// Behavioural model of the GW2AR-18's embedded 64 Mbit SDR SDRAM (4 banks x
// 2048 rows x 256 columns x 32 bits), just enough to catch a controller that
// mistimes it: CL=2, burst 1, auto-precharge, byte masks, refresh counting.
// Anything the real part would reject (read/write to a closed row, a command
// before the mode register is loaded, too few refreshes) prints a FAIL line.
`timescale 1ns / 1ps
`default_nettype none

module sdram_model (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n, ras_n, cas_n, we_n,
    input  wire [10:0] a,
    input  wire [1:0]  ba,
    input  wire [3:0]  dqm,
    inout  wire [31:0] dq
);
    reg [31:0] mem [0:2097151];
    reg [10:0] row  [0:3];
    reg        open [0:3];
    reg        mode_loaded = 1'b0;
    integer    refreshes = 0, errors = 0, i;

    // Read pipeline: CL=2, so data appears after the second clock edge that
    // follows the READ command's edge and lasts one clock.
    reg [2:0]  rd_v = 3'b000;
    reg [31:0] rd_d0, rd_d1, rd_d2;
    assign dq = rd_v[2] ? rd_d2 : 32'bz;

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
    reg [20:0] idx;

    initial for (i = 0; i < 4; i = i + 1) begin open[i] = 1'b0; row[i] = 11'd0; end

    always @(posedge clk) begin
        rd_v  <= {rd_v[1:0], 1'b0};
        rd_d1 <= rd_d0;
        rd_d2 <= rd_d1;
        if (cke) case (cmd)
            4'b0000: mode_loaded <= 1'b1;                          // LOAD MODE
            4'b0001: refreshes = refreshes + 1;                    // AUTO REFRESH
            4'b0010: begin                                         // PRECHARGE
                if (a[10]) for (i = 0; i < 4; i = i + 1) open[i] = 1'b0;
                else open[ba] = 1'b0;
            end
            4'b0011: begin                                         // ACTIVE
                if (open[ba]) begin $display("FAIL: sdram ACTIVE to open bank %0d", ba); errors = errors + 1; end
                open[ba] = 1'b1; row[ba] = a;
            end
            4'b0101, 4'b0100: begin                                // READ / WRITE
                idx = {ba, row[ba], a[7:0]};
                if (!mode_loaded || !open[ba]) begin
                    $display("FAIL: sdram %s to a closed bank/unloaded mode", cmd[0] ? "read" : "write");
                    errors = errors + 1;
                end else if (cmd == 4'b0101) begin
                    rd_d0 <= mem[idx];
                    rd_v[0] <= 1'b1;
                end else begin
                    if (!dqm[0]) mem[idx][7:0]   = dq[7:0];
                    if (!dqm[1]) mem[idx][15:8]  = dq[15:8];
                    if (!dqm[2]) mem[idx][23:16] = dq[23:16];
                    if (!dqm[3]) mem[idx][31:24] = dq[31:24];
                end
                if (a[10]) open[ba] = 1'b0;                        // auto-precharge
            end
            default: ;
        endcase
    end
endmodule

`default_nettype wire
