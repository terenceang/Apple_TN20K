// ============================================================================
//  fat_test.v -- raw FAT32 test on the TF card, no Apple core:
//  mount, create TEST.TXT, write "Hello World", read it back, delete it,
//  verify it is gone.  Progress and the verdict go out on uart_tx (115200 8N1);
//  the verdict line repeats every ~1.2 s so a terminal can attach late.
//
//  Needs an SDHC card formatted FAT32 (MBR or superfloppy), root cluster 2,
//  512 B sectors.  Touches only: root directory sector 0, FAT sector 0 of both
//  FATs, and the first sector of one free cluster.  FSInfo is not updated
//  (readers recompute it).
//
//  ponytail: no LFN, no subdirectories, one-sector files, free cluster must be
//  < 128 (FAT sector 0; a fresh format has cluster 3 free), an existing
//  TEST.TXT is not detected (delete it first), the root sector must have a
//  free entry.  Extend the scan to more sectors if a used card needs it.
// ============================================================================
`include "src/uart_defs.vh"
`default_nettype none

module fat_test #(
    parameter PWR_BITS    = 20,
    parameter REPEAT_BITS = 25,         // verdict repeat period, 2^N clocks
    parameter FORMAT      = 0           // 1: DESTROYS the first partition: make it FAT32 first
) (
    input  wire clk,
    input  wire reset,
    output wire sd_clk,
    output wire sd_mosi,
    input  wire sd_miso,
    output wire sd_cs_n,
    output reg  uart_tx = 1'b1,
    output reg  pass = 1'b0,
    output reg  failed = 1'b0
);
    // ---- block layer ----
    reg         rd, wr;
    reg  [31:0] lba;
    wire        bbusy, berr;
    wire [2:0]  bstage;
    wire [7:0]  blrx;
    reg  [8:0]  ba;
    reg         bwe;
    reg  [7:0]  bwd;
    wire [7:0]  brd;
    sd_blk #(.PWR_BITS(PWR_BITS)) u_blk (
        .clk(clk), .reset(reset), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .sd_cs_n(sd_cs_n), .rd(rd), .wr(wr), .lba(lba), .busy(bbusy), .err(berr),
        .estage(bstage), .lrx(blrx), .ba(ba), .bwe(bwe), .bwd(bwd), .brd(brd));

    // ---- constants ----
    localparam [87:0] HW = "Hello World";
    localparam [87:0] NM = "TEST    TXT";
    function [7:0] txt(input [8:0] i);
        txt = (i < 11) ? HW[8*(10-i) +: 8] : 8'h00;
    endfunction
    function [7:0] dent(input [4:0] i, input [7:0] c);        // 32-byte directory entry
        if (i < 11) dent = NM[8*(10-i) +: 8];
        else case (i)
            11: dent = 8'h20;          // archive
            26: dent = c;              // first cluster, low word (high word = 0)
            28: dent = 8'd11;          // size
            default: dent = 8'h00;
        endcase
    endfunction

    // ---- FORMAT: 512 MB volume, 8 sectors/cluster (131072 clusters, so it is FAT32), 2 FATs of 1025 ----
    function [7:0] vbr(input [8:0] i, input [31:0] hid);
        if (i >= 71 && i < 82) vbr = "NO NAME    " >> (8*(81-i));
        else if (i >= 3 && i < 11) vbr = "MSDOS5.0" >> (8*(10-i));
        else if (i >= 82 && i < 90) vbr = "FAT32   " >> (8*(89-i));
        else if (i >= 28 && i < 32) vbr = hid >> (8*(i-28));
        else case (i)
            0: vbr = 8'hEB; 1: vbr = 8'h58; 2: vbr = 8'h90;
            12: vbr = 8'h02; 13: vbr = 8'd8; 14: vbr = 8'd32; 16: vbr = 8'd2; 21: vbr = 8'hF8;
            24: vbr = 8'd63; 26: vbr = 8'd255;
            34: vbr = 8'h10;                                   // total sectors 0x00100000
            36: vbr = 8'h01; 37: vbr = 8'h04;                  // FAT size 1025
            44: vbr = 8'd2; 48: vbr = 8'd1; 50: vbr = 8'd6;    // root cluster, FSInfo, backup boot
            64: vbr = 8'h80; 66: vbr = 8'h29; 67: vbr = 8'h12; 68: vbr = 8'h34; 69: vbr = 8'h56; 70: vbr = 8'h78;
            510: vbr = 8'h55; 511: vbr = 8'hAA;
            default: vbr = 8'h00;
        endcase
    endfunction
    function [7:0] fsi(input [8:0] i);
        case (i)
            0: fsi = 8'h52; 1: fsi = 8'h52; 2: fsi = 8'h61; 3: fsi = 8'h41;
            484: fsi = 8'h72; 485: fsi = 8'h72; 486: fsi = 8'h41; 487: fsi = 8'h61;
            488, 489, 490, 491, 492, 493, 494, 495: fsi = 8'hFF;
            510: fsi = 8'h55; 511: fsi = 8'hAA;
            default: fsi = 8'h00;
        endcase
    endfunction
    function [7:0] fat0(input [3:0] i);                        // entries 0, 1 (media, EOC), 2 (root: EOC)
        fat0 = (i == 0) ? 8'hF8 : (i[1:0] == 3) ? 8'h0F : 8'hFF;
    endfunction

    // ---- messages ----
    localparam [7:0] MSG_FAIL = 6;
    function [7:0] ch(input [8*24-1:0] s, input [5:0] i);
        ch = s[8*(23-i) +: 8];
    endfunction
    function [7:0] hexc(input [3:0] v); hexc = v < 10 ? "0" + v : "A" + v - 10; endfunction
    reg [7:0] step, fst;
    reg [31:0] oem;                      // VBR bytes 3..6, for diagnosing the failure
    reg [31:0] part, fatsz, fat1, fat2, data, clba, cacc, acc;
    function [7:0] msg(input [7:0] id, input [5:0] i);
        case (id)
            0: msg = ch({"SD INIT OK\r\n",          {12{8'h00}}}, i);
            1: msg = ch({"MOUNT FAT32 OK\r\n",      {8{8'h00}}},  i);
            2: msg = ch({"CREATE test.txt OK\r\n",  {4{8'h00}}},  i);
            3: msg = ch({"READ OK: Hello World\r\n",{2{8'h00}}},  i);
            4: msg = ch({"DELETE OK\r\n",           {13{8'h00}}}, i);
            5: msg = ch({"PASS\r\n",                {18{8'h00}}}, i);
            7: msg = ch({"FORMAT FAT32 OK\r\n",    {7{8'h00}}},  i);
            default: case (i)              // FAIL s<step> e<sd cmd> @<state>
                0: msg = "F"; 1: msg = "A"; 2: msg = "I"; 3: msg = "L"; 4: msg = " ";
                5: msg = "s"; 6: msg = "0" + step; 7: msg = " "; 8: msg = "e";
                9: msg = "0" + (berr ? bstage : 3'd0); 10: msg = " "; 11: msg = "@";
                12: msg = hexc(fst[7:4]); 13: msg = hexc(fst[3:0]); 14: msg = " "; 15: msg = "r";
                16: msg = hexc(blrx[7:4]); 17: msg = hexc(blrx[3:0]); 18: msg = " "; 19: msg = "p";
                20: msg = hexc(part[31:28]); 21: msg = hexc(part[27:24]); 22: msg = hexc(part[23:20]); 23: msg = hexc(part[19:16]);
                24: msg = hexc(part[15:12]); 25: msg = hexc(part[11:8]); 26: msg = hexc(part[7:4]); 27: msg = hexc(part[3:0]);
                28: msg = " "; 29: msg = "a";
                30: msg = hexc(acc[15:12]); 31: msg = hexc(acc[11:8]); 32: msg = hexc(acc[7:4]); 33: msg = hexc(acc[3:0]);
                34: msg = " "; 35: msg = "o";
                36: msg = hexc(oem[31:28]); 37: msg = hexc(oem[27:24]); 38: msg = hexc(oem[23:20]); 39: msg = hexc(oem[19:16]);
                40: msg = hexc(oem[15:12]); 41: msg = hexc(oem[11:8]); 42: msg = hexc(oem[7:4]); 43: msg = hexc(oem[3:0]);
                44: msg = 8'h0D; 45: msg = 8'h0A;
                default: msg = 8'h00;
            endcase
        endcase
    endfunction

    // ---- program ----
    localparam [6:0]
        S_INIT = 0,  S_SAYW = 1,  S_M0 = 2,   S_M1 = 3,   S_M2 = 4,   S_M3 = 5,
        S_B0 = 6,    S_B1 = 7,    S_B2 = 8,   S_B3 = 9,   S_B4 = 10,  S_B5 = 11,  S_B6 = 12, S_B7 = 13,
        S_C0 = 14,   S_C1 = 15,   S_C2 = 16,
        S_F0 = 17,   S_F1 = 18,   S_F2 = 19,  S_F3 = 20,  S_F4 = 21,  S_F5 = 22,  S_F6 = 23,
        S_F7 = 24,   S_F7B = 25,  S_F8 = 26,  S_F9 = 27,  S_FA = 28,  S_FB = 29,
        S_R0 = 30,   S_R1 = 31,   S_R2 = 32,  S_R3 = 33,  S_R4 = 34,  S_R5 = 35,  S_R6 = 36,
        S_D0 = 37,   S_D1 = 38,   S_D2 = 39,  S_D3 = 40,  S_D4 = 41,  S_D5 = 42,  S_D6 = 43,
        S_V0 = 44,   S_V1 = 45,   S_V2 = 46,  S_V3 = 47,  S_V4 = 48,  S_PASS = 49, S_END = 50,
        S_F6B = 51,  S_FAB = 52,  S_FC = 53,  S_D6B = 54, S_B0B = 55,
        S_FM0 = 56, S_FM1 = 57, S_FM2 = 58, S_FM3 = 59, S_FM4 = 60, S_FM5 = 61, S_FM6 = 62, S_FM7 = 63,
        S_FM8 = 64, S_FM9 = 65, S_FM10 = 66, S_FM11 = 67, S_FM12 = 68, S_FM13 = 69, S_FM14 = 70,
        S_FM15 = 71, S_FM16 = 72, S_FM17 = 73, S_FM18 = 74, S_FM19 = 75, S_FM1B = 76;

    reg [6:0]  st, nst;
    reg [15:0] rsv;
    reg [7:0]  spc, nfat, cl, c;
    reg [7:0]  ccnt;
    reg [3:0]  de;
    reg [9:0]  k;                        // byte loop counter
    reg        opw, opdly;
    // field reader: acc <= gn little-endian bytes at buffer offset goff
    reg        gbusy;
    reg [8:0]  goff;
    reg [2:0]  gn, gi;
    reg [1:0]  gph;
    // printer
    reg [7:0]  pid;
    reg [5:0]  pidx;
    reg        pbusy, tbusy;
    reg [9:0]  tsh;
    reg [8:0]  tdiv;
    reg [3:0]  tbit;
    reg [7:0]  fin_id;
    reg [REPEAT_BITS-1:0] rcnt;

    wire [7:0] pc = msg(pid, pidx);

    task RD(input [31:0] l, input [6:0] nx);
        begin rd <= 1'b1; lba <= l; opw <= 1'b1; opdly <= 1'b1; st <= nx; end
    endtask
    task WR(input [31:0] l, input [6:0] nx);
        begin wr <= 1'b1; lba <= l; opw <= 1'b1; opdly <= 1'b1; st <= nx; end
    endtask
    task GET(input [8:0] off, input [2:0] nb, input [6:0] nx);
        begin goff <= off; gn <= nb; gi <= 0; gph <= 0; acc <= 0; gbusy <= 1'b1; st <= nx; end
    endtask
    task BW(input [8:0] a, input [7:0] d);
        begin ba <= a; bwd <= d; bwe <= 1'b1; end
    endtask
    task SAY(input [7:0] id, input [6:0] nx);
        begin pid <= id; pidx <= 0; pbusy <= 1'b1; nst <= nx; st <= S_SAYW; end
    endtask
    task FAIL;
        begin fst <= {1'b0, st}; failed <= 1'b1; fin_id <= MSG_FAIL;
              pid <= MSG_FAIL; pidx <= 0; pbusy <= 1'b1; nst <= S_END; st <= S_SAYW; end
    endtask

    always @(posedge clk) begin
        rd <= 1'b0; wr <= 1'b0; bwe <= 1'b0;
        // ---- printer: one char at a time through a 115200 8N1 shifter ----
        if (!tbusy && pbusy) begin
            if (pc == 0) pbusy <= 1'b0;
            else begin tsh <= {1'b1, pc, 1'b0}; tbusy <= 1'b1; tdiv <= 0; tbit <= 0; pidx <= pidx + 1'b1; end
        end else if (tbusy) begin
            if (tdiv != `UART_CLKS_PER_BIT - 1'b1) tdiv <= tdiv + 1'b1;
            else begin
                tdiv <= 0;
                if (tbit == 4'd10) tbusy <= 1'b0;
                else begin uart_tx <= tsh[0]; tsh <= {1'b1, tsh[9:1]}; tbit <= tbit + 1'b1; end
            end
        end

        if (reset) begin
            st <= S_INIT; opw <= 0; opdly <= 0; gbusy <= 0; pbusy <= 0; tbusy <= 0; uart_tx <= 1'b1;
            pass <= 0; failed <= 0; step <= 0; fst <= 0; rcnt <= 0; fin_id <= 5;
            de <= 0; k <= 0; c <= 0; cl <= 0;
        end else if (gbusy) begin
            case (gph)
                0: begin ba <= goff + gi; gph <= 2'd1; end
                1: gph <= 2'd2;
                default: begin
                    acc <= acc | ({24'd0, brd} << {gi[1:0], 3'b000});
                    gi <= gi + 1'b1;
                    if (gi + 1'b1 == gn) gbusy <= 1'b0; else gph <= 2'd0;
                end
            endcase
        end else if (opw) begin
            if (opdly) opdly <= 1'b0;
            else if (!bbusy) begin opw <= 1'b0; if (berr) FAIL; end
        end else case (st)
            S_SAYW: if (!pbusy && !tbusy) st <= nst;
            S_INIT: if (!bbusy) begin if (berr) FAIL; else SAY(0, FORMAT ? S_FM0 : S_M0); end
            // ---- format (FORMAT=1): partition type, VBR+backup, FSInfo, FATs, root cluster ----
            S_FM0: begin step <= 6; RD(0, S_FM1); end
            S_FM1: GET(9'h1FE, 2, S_FM1B);
            S_FM1B: if (acc[15:0] != 16'hAA55) FAIL; else GET(9'h1C6, 4, S_FM2);   // need a valid MBR
            S_FM2: if (acc < 2048) FAIL; else begin part <= acc; BW(9'h1C2, 8'h0C); st <= S_FM3; end
            S_FM3: WR(0, S_FM4);
            S_FM4: begin fat1 <= part + 32; fatsz <= 1025; st <= S_FM5; end
            S_FM5: begin fat2 <= fat1 + fatsz; st <= S_FM6; end
            S_FM6: begin data <= fat2 + fatsz; k <= 0; st <= S_FM7; end
            S_FM7: begin BW(k[8:0], 8'h00); k <= k + 1'b1; if (k == 511) begin cacc <= fat1; st <= S_FM8; end end
            S_FM8: if (cacc == data + 8) begin k <= 0; st <= S_FM9; end          // zero both FATs and the root cluster
                   else begin WR(cacc, S_FM8); cacc <= cacc + 1'b1; end
            S_FM9: begin BW(k[8:0], fat0(k[3:0])); k <= k + 1'b1; if (k == 11) st <= S_FM10; end
            S_FM10: WR(fat1, S_FM11);
            S_FM11: WR(fat2, S_FM12);
            S_FM12: begin k <= 0; st <= S_FM13; end
            S_FM13: begin BW(k[8:0], vbr(k[8:0], part)); k <= k + 1'b1; if (k == 511) st <= S_FM14; end
            S_FM14: WR(part, S_FM15);
            S_FM15: WR(part + 6, S_FM16);
            S_FM16: begin k <= 0; st <= S_FM17; end
            S_FM17: begin BW(k[8:0], fsi(k[8:0])); k <= k + 1'b1; if (k == 511) st <= S_FM18; end
            S_FM18: WR(part + 1, S_FM19);
            S_FM19: SAY(7, S_M0);
            // ---- mount ----
            S_M0: begin step <= 1; RD(0, S_M1); end
            S_M1: GET(9'h052, 1, S_M2);                          // "FAT32   " => this is the VBR
            S_M2: if (acc[7:0] == "F") begin part <= 0; st <= S_B0; end
                  else GET(9'h1C6, 4, S_M3);                     // MBR: first partition's start LBA
            S_M3: begin part <= acc; RD(acc, S_B0); end
            S_B0: GET(9'h003, 4, S_B0B);
            S_B0B: begin oem <= acc; GET(9'h00B, 2, S_B1); end
            S_B1: if (acc != 512) FAIL; else GET(9'h00D, 1, S_B2);
            S_B2: begin spc <= acc[7:0]; GET(9'h00E, 2, S_B3); end
            S_B3: begin rsv <= acc[15:0]; GET(9'h010, 1, S_B4); end
            S_B4: begin nfat <= acc[7:0]; GET(9'h024, 4, S_B5); end
            S_B5: begin fatsz <= acc; GET(9'h02C, 4, S_B6); end
            S_B6: if (acc != 2 || (nfat != 1 && nfat != 2)) FAIL;    // root cluster must be 2
                  else begin
                      fat1 <= part + rsv; fat2 <= part + rsv + fatsz; st <= S_B7;
                  end
            S_B7: begin data <= (nfat == 1) ? fat2 : fat2 + fatsz; SAY(1, S_C0); end
            // ---- create: free dir slot, free cluster, FAT, data, dir entry ----
            S_C0: begin step <= 2; de <= 0; RD(data, S_C1); end
            S_C1: GET({de, 5'b0}, 1, S_C2);
            S_C2: if (acc[7:0] == 8'h00 || acc[7:0] == 8'hE5) st <= S_F0;
                  else if (de == 15) FAIL;
                  else begin de <= de + 1'b1; st <= S_C1; end
            S_F0: begin c <= 3; RD(fat1, S_F1); end
            S_F1: GET({c[6:0], 2'b00}, 4, S_F2);
            S_F2: if (acc[27:0] == 0) begin cl <= c; k <= 0; st <= S_F3; end
                  else if (c == 127) FAIL;
                  else begin c <= c + 1'b1; st <= S_F1; end
            S_F3: begin                                          // end-of-chain mark
                      BW({cl[6:0], 2'b00} + k[1:0], k[1:0] == 3 ? 8'h0F : 8'hFF);
                      k <= k + 1'b1;
                      if (k == 3) st <= S_F4;
                  end
            S_F4: WR(fat1, S_F5);
            S_F5: if (nfat == 2) WR(fat2, S_F6); else st <= S_F6;
            S_F6: begin k <= 0; st <= S_F6B; end                 // fill the data sector
            S_F6B: begin
                      BW(k[8:0], txt(k[8:0]));
                      k <= k + 1'b1;
                      if (k == 511) st <= S_F7;
                  end
            S_F7: begin cacc <= data; ccnt <= cl - 8'd2; st <= S_F7B; end     // clba = data + (cl-2)*spc
            S_F7B: if (ccnt == 0) begin clba <= cacc; st <= S_F8; end
                   else begin cacc <= cacc + spc; ccnt <= ccnt - 1'b1; end
            S_F8: WR(clba, S_F9);
            S_F9: RD(data, S_FA);
            S_FA: begin k <= 0; st <= S_FAB; end
            S_FAB: begin                                         // patch the 32-byte entry in
                      BW({de, 5'b0} + k[4:0], dent(k[4:0], cl));
                      k <= k + 1'b1;
                      if (k == 31) st <= S_FB;
                  end
            S_FB: WR(data, S_FC);
            S_FC: SAY(2, S_R0);
            // ---- read back through the directory ----
            S_R0: begin step <= 3; RD(data, S_R1); end
            S_R1: GET({de, 5'b0}, 4, S_R2);
            S_R2: if (acc != 32'h54534554) FAIL;                 // bytes T,E,S,T, little-endian
                  else GET({de, 5'b0} + 9'd28, 4, S_R3);
            S_R3: if (acc != 11) FAIL; else GET({de, 5'b0} + 9'd26, 2, S_R4);
            S_R4: if (acc[7:0] != cl || acc[15:8] != 0) FAIL; else begin k <= 0; RD(clba, S_R5); end
            S_R5: GET(k[8:0], 1, S_R6);
            S_R6: if (acc[7:0] != txt(k[8:0])) FAIL;
                  else if (k == 10) SAY(3, S_D0);
                  else begin k <= k + 1'b1; st <= S_R5; end
            // ---- delete: free the dir entry and the cluster ----
            S_D0: begin step <= 4; RD(data, S_D1); end
            S_D1: begin BW({de, 5'b0}, 8'hE5); st <= S_D2; end
            S_D2: WR(data, S_D3);
            S_D3: RD(fat1, S_D4);
            S_D4: begin k <= 0; st <= S_D5; end
            S_D5: begin
                      BW({cl[6:0], 2'b00} + k[1:0], 8'h00);
                      k <= k + 1'b1;
                      if (k == 3) st <= S_D6;
                  end
            S_D6: WR(fat1, S_D6B);
            S_D6B: if (nfat == 2) WR(fat2, S_V0); else st <= S_V0;
            // ---- verify it is gone ----
            S_V0: begin step <= 5; RD(data, S_V1); end
            S_V1: GET({de, 5'b0}, 1, S_V2);
            S_V2: if (acc[7:0] != 8'hE5) FAIL; else RD(fat1, S_V3);
            S_V3: GET({cl[6:0], 2'b00}, 4, S_V4);
            S_V4: if (acc[27:0] != 0) FAIL; else SAY(4, S_PASS);
            S_PASS: begin pass <= 1'b1; fin_id <= 5; SAY(5, S_END); end
            S_END: begin rcnt <= rcnt + 1'b1; if (&rcnt) SAY(fin_id, S_END); end
            default: ;
        endcase
    end
endmodule

`default_nettype wire
