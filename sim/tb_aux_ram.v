`timescale 1ns / 1ps
`default_nettype none

// aux_ram + the vendored SDRAM controller against a behavioural SDRAM:
// CPU byte writes/reads (with neighbours in one word), the video line fill
// racing CPU traffic, and refresh keeping up.  sdram_model prints FAIL for
// any illegal SDRAM command sequence.
module tb_aux_ram;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;

    reg reset = 1'b1;
    reg fill_start = 1'b0;
    reg [15:0] fill_addr = 16'd0;
    reg [5:0] col = 6'd0;
    wire [7:0] line_data;
    reg rd_want = 1'b0;
    reg [15:0] rd_addr = 16'd0;
    wire [7:0] rd_data;
    wire rd_hit;
    reg wr_go = 1'b0;
    reg [15:0] wr_addr = 16'd0;
    reg [7:0] wr_data = 8'd0;
    wire wr_busy;

    wire sd_clk, sd_cke, sd_cs_n, sd_cas_n, sd_ras_n, sd_wen_n;
    wire [31:0] sd_dq;
    wire [10:0] sd_addr;
    wire [1:0] sd_ba;
    wire [3:0] sd_dqm;

    aux_ram dut (
        .clk(clk), .reset(reset),
        .fill_start(fill_start), .fill_addr(fill_addr), .col(col), .line_data(line_data),
        .rd_want(rd_want), .rd_addr(rd_addr), .rd_data(rd_data), .rd_hit(rd_hit),
        .wr_go(wr_go), .wr_addr(wr_addr), .wr_data(wr_data), .wr_busy(wr_busy),
        .O_sdram_clk(sd_clk), .O_sdram_cke(sd_cke), .O_sdram_cs_n(sd_cs_n),
        .O_sdram_cas_n(sd_cas_n), .O_sdram_ras_n(sd_ras_n), .O_sdram_wen_n(sd_wen_n),
        .IO_sdram_dq(sd_dq), .O_sdram_addr(sd_addr), .O_sdram_ba(sd_ba), .O_sdram_dqm(sd_dqm)
    );

    sdram_model mdl (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_wen_n), .a(sd_addr), .ba(sd_ba), .dqm(sd_dqm), .dq(sd_dq)
    );

    reg [7:0] shadow [0:65535];
    integer errors = 0, i, n, stalls;
    reg [15:0] a;
    reg [7:0] d;
    time t0;

    task cpu_write(input [15:0] addr, input [7:0] data);
        begin
            @(posedge clk); #1;
            while (wr_busy) begin @(posedge clk); #1; end
            wr_go <= 1'b1; wr_addr <= addr; wr_data <= data;
            @(posedge clk); #1; wr_go <= 1'b0;
            shadow[addr] = data;
        end
    endtask

    task cpu_read(input [15:0] addr, output [7:0] data);
        begin
            @(posedge clk); rd_want <= 1'b1; rd_addr <= addr;
            @(posedge clk);
            while (!rd_hit) @(posedge clk);
            data = rd_data;
            rd_want <= 1'b0;
        end
    endtask

    task check_read(input [15:0] addr);
        reg [7:0] got;
        begin
            cpu_read(addr, got);
            if (got !== shadow[addr]) begin
                if (errors < 10) $display("FAIL: aux[%04h] = %02h, expected %02h", addr, got, shadow[addr]);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        for (i = 0; i < 65536; i = i + 1) shadow[i] = 8'h00;
        #200; @(posedge clk); reset <= 1'b0;
        wait (dut.sd_ready);
        t0 = $time;

        // Neighbouring bytes of one word, both orders, and the ends of the map.
        cpu_write(16'h0400, 8'h11); cpu_write(16'h0401, 8'h22);
        cpu_write(16'h0403, 8'h44); cpu_write(16'h0402, 8'h33);
        cpu_write(16'h0000, 8'h5A); cpu_write(16'hFFFF, 8'hA5); cpu_write(16'hFFFE, 8'h3C);
        check_read(16'h0400); check_read(16'h0401); check_read(16'h0402); check_read(16'h0403);
        check_read(16'h0000); check_read(16'hFFFF); check_read(16'hFFFE);
        // overwrite one byte of a cached word: the other byte must survive
        cpu_write(16'h0400, 8'h99);
        check_read(16'h0400); check_read(16'h0401);

        // Pseudo-random scatter
        a = 16'h1234;
        for (n = 0; n < 300; n = n + 1) begin
            a = {a[14:0], a[15] ^ a[13] ^ a[12] ^ a[10]};
            cpu_write(a, a[7:0] ^ n[7:0]);
        end
        a = 16'h1234;
        for (n = 0; n < 300; n = n + 1) begin
            a = {a[14:0], a[15] ^ a[13] ^ a[12] ^ a[10]};
            check_read(a);
        end

        // Line fill: 40 bytes at an even address, read back through the
        // video port, while the CPU keeps writing and reading elsewhere.
        for (i = 0; i < 40; i = i + 1) cpu_write(16'h0450 + i, 8'hC0 + i[7:0]);
        fill_addr <= 16'h0450;
        @(posedge clk); fill_start <= 1'b1; @(posedge clk); fill_start <= 1'b0;
        for (n = 0; n < 12; n = n + 1) begin
            cpu_write(16'h8000 + n, n[7:0]);
            check_read(16'h8000 + n);
        end
        wait (!dut.fill_active);
        repeat (20) @(posedge clk);
        for (i = 0; i < 40; i = i + 1) begin
            col <= i; @(posedge clk); #1;
            if (line_data !== 8'hC0 + i[7:0]) begin
                if (errors < 10) $display("FAIL: line buffer col %0d = %02h, expected %02h", i, line_data, 8'hC0 + i[7:0]);
                errors = errors + 1;
            end
        end

        // Refresh has kept up: one per 7.8 us or better over the whole run.
        repeat (5000) @(posedge clk);
        if (mdl.refreshes * 7800 < ($time - t0)) begin
            $display("FAIL: %0d refreshes in %0t", mdl.refreshes, $time - t0);
            errors = errors + 1;
        end
        errors = errors + mdl.errors;

        if (errors == 0) $display("tb_aux_ram: PASS (%0d refreshes)", mdl.refreshes);
        else             $display("FAIL: tb_aux_ram %0d errors", errors);
        $finish;
    end

    initial begin #60000000; $display("FAIL: tb_aux_ram timeout"); $finish; end
endmodule
