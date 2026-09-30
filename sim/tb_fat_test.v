// tb_fat_test: fat_test + sd_blk against a behavioural SDHC card (SPI mode) holding an
// MBR + FAT32 volume (2 sectors/cluster, 2 FATs, a pre-existing file in dir slot 0 and
// cluster 3, so the new file must land in slot 1 / cluster 4 / LBA 152).  Decodes the UART
// and checks the on-card result: Hello World data sector, directory entry and FAT chain
// as written, and after the delete the entry is 0xE5 and both FAT entries are free.
`timescale 1ns/1ps
module tb_fat_test;
`ifdef FMT   // FORMAT=1: the card starts as junk with only an MBR; the DUT must make it FAT32
    localparam PART = 2048, FAT1 = 2080, FATSZ = 1025, FAT2 = 3105, DATA = 4130, CLBA4 = 4138, SLOT = 0, CL = 3, FMTP = 1;
`else
    localparam PART = 100, FAT1 = 132, FATSZ = 8, FAT2 = 140, DATA = 148, CLBA4 = 152, SLOT = 1, CL = 4, FMTP = 0;
`endif
    reg clk = 0, reset = 1;
    always #18.5 clk = ~clk;

    wire sd_clk, sd_mosi, sd_cs_n, uart_tx, pass, failed;
    wire sd_miso;
    fat_test #(.PWR_BITS(8), .REPEAT_BITS(18), .FORMAT(FMTP)) dut (
        .clk(clk), .reset(reset), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso),
        .sd_cs_n(sd_cs_n), .uart_tx(uart_tx), .pass(pass), .failed(failed));

    // ---- the card: 8192 sectors ----
    reg [7:0] card [0:8192*512-1];
    integer i;
    task put32(input integer a, input [31:0] v);
        begin card[a] = v[7:0]; card[a+1] = v[15:8]; card[a+2] = v[23:16]; card[a+3] = v[31:24]; end
    endtask
    task format;
        integer b;
        begin
            for (i = 0; i < 8192*512; i = i + 1) card[i] = FMTP ? 8'hA5 : 8'h00;
            for (i = 0; i < 512; i = i + 1) card[i] = 0;
            card[446+4] = FMTP ? 8'h07 : 8'h0C; put32(446+8, PART); card[510] = 8'h55; card[511] = 8'hAA;   // MBR
            if (!FMTP) begin
            b = PART*512;
            card[b] = 8'hEB; card[b+11] = 0; card[b+12] = 2;            // 512 B/sector
            card[b+13] = 2; card[b+14] = 32; card[b+16] = 2; put32(b+36, FATSZ); put32(b+44, 2);
            card[b+82]="F"; card[b+83]="A"; card[b+84]="T"; card[b+85]="3"; card[b+86]="2";
            card[b+510] = 8'h55; card[b+511] = 8'hAA;
            for (i = 0; i < 2; i = i + 1) begin                          // both FATs
                put32((i ? FAT2 : FAT1)*512 + 0, 32'h0FFFFFF8);
                put32((i ? FAT2 : FAT1)*512 + 4, 32'h0FFFFFFF);
                put32((i ? FAT2 : FAT1)*512 + 8, 32'h0FFFFFFF);          // root
                put32((i ? FAT2 : FAT1)*512 + 12, 32'h0FFFFFFF);         // cluster 3: VOLUME.DAT
            end
            card[DATA*512+0]="V"; card[DATA*512+1]="O"; card[DATA*512+8]="D";   // slot 0 in use
            card[DATA*512+11] = 8'h20; card[DATA*512+26] = 3;
            end
        end
    endtask

    integer wblks = 0;
    reg [7:0] snap_data [0:10]; reg [7:0] snap_dir [0:31]; reg [31:0] snap_fat4;
    reg got_data = 0, got_dir = 0, got_fat = 0;
    integer wst = 0, wn = 0, wlba = 0, errs = 0;
    reg [7:0] q [0:2047]; integer qh = 0, qt = 0;
    reg [7:0] rxs, txs = 8'hFF, nxt; reg pend = 0; integer nb = 0, cn = 0, a41 = 0, k;
    reg [7:0] cmd [0:5];
    wire [31:0] carg = {cmd[1], cmd[2], cmd[3], cmd[4]};
    assign sd_miso = sd_cs_n ? 1'b1 : txs[7];
    task push(input [7:0] b); begin q[qt % 2048] = b; qt = qt + 1; end endtask
    always @(posedge sd_clk) begin
        rxs = {rxs[6:0], sd_mosi}; nb = nb + 1;
        if (nb == 8) begin
            nb = 0;
            if (wst != 0) begin
                if (wst == 1) begin if (rxs == 8'hFE) begin wst = 2; wn = 0; end end
                else if (wst == 2) begin
                    card[wlba*512 + wn] = rxs; wn = wn + 1;
                    if (wn == 512) begin wst = 3; wn = 0; end
                end else begin
                    wn = wn + 1;
                    if (wn == 2) begin
                        wst = 0; push(8'hE5); push(0); push(0); push(0); wblks = wblks + 1;
                        if (wlba == CLBA4 && !got_data && dut.step >= 2 && dut.step <= 5) begin
                            got_data = 1; for (k = 0; k < 11; k = k + 1) snap_data[k] = card[CLBA4*512 + k];
                        end
                        if (wlba == DATA && !got_dir && dut.step >= 2 && dut.step <= 5) begin
                            got_dir = 1; for (k = 0; k < 32; k = k + 1) snap_dir[k] = card[DATA*512 + SLOT*32 + k];
                        end
                        if (wlba == FAT1 && !got_fat && dut.step >= 2 && dut.step <= 5) begin
                            got_fat = 1; snap_fat4 = {card[FAT1*512+CL*4+3], card[FAT1*512+CL*4+2], card[FAT1*512+CL*4+1], card[FAT1*512+CL*4]};
                        end
                    end
                end
            end else if (cn > 0 || rxs[7:6] == 2'b01) begin
                cmd[cn] = rxs; cn = cn + 1;
                if (cn == 6) begin
                    cn = 0; push(8'hFF);
                    case (cmd[0][5:0])
                        0: push(8'h01);
                        8: begin push(8'h01); push(0); push(0); push(1); push(8'hAA); end
                        55: push(8'h01);
                        41: begin a41 = a41 + 1; push(a41 < 2 ? 8'h01 : 8'h00); end
                        17: begin
                            if (carg >= 8192) errs = errs + 1;
                            push(0); push(8'hFF); push(8'hFF); push(8'hFE);
                            for (k = 0; k < 512; k = k + 1) push(card[carg*512 + k]);
                            push(0); push(0);
                        end
                        24: begin push(0); wst = 1; wlba = carg; end
                        default: errs = errs + 1;
                    endcase
                end
            end
            pend = 1;
            if (qh < qt) begin nxt = q[qh % 2048]; qh = qh + 1; end else nxt = 8'hFF;
        end
    end
    always @(negedge sd_clk) begin
        if (pend) begin txs = nxt; pend = 0; end else txs = {txs[6:0], 1'b1};
    end

    // ---- UART decoder (115200 8N1 = 234 clocks/bit) ----
    reg [7:0] log [0:1023]; integer ln = 0; reg rxbusy = 0; reg [7:0] rb; integer bi;
    always @(negedge uart_tx) if (!rxbusy) begin
        rxbusy = 1; repeat (117) @(posedge clk);
        for (bi = 0; bi < 8; bi = bi + 1) begin repeat (234) @(posedge clk); rb[bi] = uart_tx; end
        repeat (234) @(posedge clk);
        log[ln] = rb; ln = ln + 1; rxbusy = 0;
    end
    function has(input [8*24-1:0] s, input integer len);      // s right-aligned, len chars
        integer p, q2, ok;
        begin
            has = 0;
            for (p = 0; p + len <= ln; p = p + 1) begin
                ok = 1;
                for (q2 = 0; q2 < len; q2 = q2 + 1) if (log[p + q2] !== s[8*(len-1-q2) +: 8]) ok = 0;
                if (ok) has = 1;
            end
        end
    endfunction

    reg [87:0] HWT = "Hello World";
    integer t;
    initial begin
        format;
        #200 reset = 0;
        t = 0;
        while (!pass && !failed && t < 120000000) begin @(posedge clk); t = t + 1; end
        if (failed) begin $display("FAIL: fat_test failed: step %0d st=%0d blk err %0d/%0d", dut.step, dut.st, dut.berr, dut.bstage); $finish; end
        if (!pass) begin $display("FAIL: timeout st=%0d step=%0d", dut.st, dut.step); $finish; end
        repeat (20000) @(posedge clk);
        // the file as it was written
        for (k = 0; k < 11; k = k + 1) if (snap_data[k] !== HWT[8*(10-k) +: 8]) errs = errs + 1;
        if (snap_dir[0] !== "T" || snap_dir[10] !== "T" || snap_dir[11] !== 8'h20 || snap_dir[26] !== CL || snap_dir[28] !== 11)
            begin $display("FAIL: directory entry %h %h %h %h %h", snap_dir[0], snap_dir[10], snap_dir[11], snap_dir[26], snap_dir[28]); errs = errs + 1; end
        if (snap_fat4 !== 32'h0FFFFFFF) begin $display("FAIL: FAT entry CL was %h", snap_fat4); errs = errs + 1; end
        // after the delete
        if (card[DATA*512 + SLOT*32] !== 8'hE5) begin $display("FAIL: entry not deleted"); errs = errs + 1; end
        if ({card[FAT1*512+CL*4+3], card[FAT1*512+CL*4+2], card[FAT1*512+CL*4+1], card[FAT1*512+CL*4]} !== 0 ||
            {card[FAT2*512+CL*4+3], card[FAT2*512+CL*4+2], card[FAT2*512+CL*4+1], card[FAT2*512+CL*4]} !== 0)
            begin $display("FAIL: FAT entry CL not freed"); errs = errs + 1; end
        if (!FMTP) begin   // untouched: slot 0 and cluster 3's chain mark
            if (card[DATA*512] !== "V" || card[FAT1*512+12] !== 8'hFF || card[FAT2*512+12] !== 8'hFF)
                begin $display("FAIL: neighbours damaged"); errs = errs + 1; end
        end else begin     // what the format left behind
            if (card[450] !== 8'h0C || card[PART*512+82] !== "F" || card[PART*512+510] !== 8'h55 || card[(PART+6)*512+510] !== 8'h55 ||
                card[(PART+1)*512+3] !== 8'h41 || card[(FAT1+1)*512] !== 0 || card[(FAT2+1024)*512+100] !== 0 ||
                card[FAT1*512] !== 8'hF8 || card[FAT1*512+8] !== 8'hFF || card[DATA*512+5*512+7] !== 0 || card[FAT1*512+12] !== 0)
                begin $display("FAIL: format incomplete"); errs = errs + 1; end
        end
        if (!has("PASS", 4) || !has("CREATE test.txt OK", 18) || !has("READ OK: Hello World", 20))
            begin $display("FAIL: uart log incomplete (%0d chars)", ln); errs = errs + 1; end
        if (errs == 0) $display("PASS"); else $display("FAIL: %0d errors", errs);
        $finish;
    end
    initial begin #20_000_000_000; $display("FAIL: sim timeout"); $finish; end
endmodule
