// ============================================================================
//  tb_video_hdmi.v -- Apple video and colour bars through hdmi_tx, pixel exact
//
//  Wires video_generator and colorbar_gen to hdmi_tx exactly as src/top.v
//  does (video_generator gets pixel_x + 1 because its output is registered,
//  colorbar_gen is combinational on pixel_x), with behavioural models of the
//  RAM and character ROM that reproduce apple2_core's read timing: RAM data
//  one clock after the address, latched into vram_data on the following clock
//  when vram_req was high, character ROM data one clock after its address.
//
//  The TMDS lanes are decoded like a sink: a video data period starts after
//  the two-character video guard band, each of its 720 symbols is a pixel,
//  lines are counted from the first video period after a vsync pulse.  Every
//  decoded pixel of a whole frame is checked against an independent model
//  of what the screen should show:
//    * frame A: Apple 40x24 text page 1 filled with a known pattern, drawn
//      with a synthetic character ROM, centred at x 80..639, y 48..431, with
//      a black border,
//    * frame B: the colour bar pattern (S1 held in top.v).
//  It also checks the AVI InfoFrame declares full-range RGB, as the Apple
//  palette needs.
//  An off-by-one in the video_generator look-ahead shows up as every glyph
//  edge moving by one pixel, so this is mainly an alignment check.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_video_hdmi;
    `include "sim/include/hdmi_ref.vh"

    reg clk = 1'b0;
    always #18.519 clk = ~clk;              // 27 MHz

    reg rst_n = 1'b0;
    reg bars  = 1'b0;                       // 0: Apple video, 1: colour bars

    // -----------------------------------------------------------------------
    // DUT wiring, as in src/top.v
    // -----------------------------------------------------------------------
    wire [9:0]  pixel_x, pixel_y;
    wire [7:0]  vid_r, vid_g, vid_b;
    wire [23:0] bar_rgb;
    wire        vram_req, vbl;
    wire [15:0] vram_addr;
    reg  [7:0]  vram_data;
    wire [11:0] char_rom_addr;
    reg  [7:0]  char_rom_data;

    video_generator u_video (
        .clk_pixel(clk), .reset(!rst_n), .flash_clk(1'b0),
        .h_cnt(pixel_x + 10'd1), .v_cnt(pixel_y),
        .text_mode(1'b1), .mixed_mode(1'b0), .page2(1'b0), .hires_mode(1'b0),
        .vram_req(vram_req), .vram_addr(vram_addr), .vram_data(vram_data),
        .char_rom_addr(char_rom_addr), .char_rom_data(char_rom_data),
        .red(vid_r), .green(vid_g), .blue(vid_b), .vbl(vbl)
    );

    colorbar_gen u_bars (
        .clk_pixel(clk), .reset(!rst_n), .x(pixel_x), .y(pixel_y), .rgb(bar_rgb)
    );

    wire [29:0] tmds;
    hdmi_tx #(.RGB_QUANT(2'b10)) u_tx (
        .clk_pixel(clk), .rst_n(rst_n),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .video_rgb(bars ? bar_rgb : {vid_r, vid_g, vid_b}),
        .audio_valid(1'b0), .audio_l(16'd0), .audio_r(16'd0),
        .tmds(tmds)
    );

    // -----------------------------------------------------------------------
    // Memory models (apple2_core timing)
    // -----------------------------------------------------------------------
    reg [7:0] ram [0:65535];
    reg [7:0] crom [0:4095];
    reg [7:0] ram_dout;
    reg       vram_req_d;

    always @(posedge clk) begin
        ram_dout      <= ram[vram_addr];
        vram_req_d    <= vram_req;
        if (vram_req_d) vram_data <= ram_dout;
        char_rom_data <= crom[char_rom_addr];
    end

    // Text row base offsets, from the Apple II memory map.
    function [15:0] row_base;
        input [4:0] r;
        begin
            row_base = {6'd0, r[2:0], 7'd0} + (r[4:3] * 16'd40);
        end
    endfunction

    // Expected colour of screen pixel (x, y), independent of the RTL.
    function [23:0] expect_apple;
        input integer x, y;
        integer col, dot, ay, row, gr;
        reg [7:0] c, g;
        reg [11:0] a;
        begin
            if (x < 80 || x >= 640 || y < 48 || y >= 432) begin
                expect_apple = 24'h000000;
            end else begin
                col = (x - 80) / 14;
                dot = ((x - 80) % 14) / 2;
                ay  = (y - 48) / 2;
                row = ay / 8;
                gr  = ay % 8;
                c   = ram[16'h0400 + row_base(row) + col];
                // Character ROM address as the //e video ROM wiring (flash off)
                a   = {1'b0, c[7], c[6] & c[7], c[5:0], gr[2:0]};
                g   = crom[a];
                // A set bit in the character ROM is a lit dot. The 2732 stores
                // glyph 1 -- what $41 reads, since char_rom_addr only carries
                // six bits of the code -- as 08 14 22 22 3e 22 22 00, which is
                // an A read this way, and glyph $20 (space) as all zeroes.
                // web/test/charset.test.js pins the same convention against the
                // real 342-0265-A dump.
                expect_apple = g[dot] ? 24'h20E820 : 24'h020602;
            end
        end
    endfunction

    function [23:0] expect_bars;
        input integer x, y;
        begin
            if (x < 40 && y < 40)                            expect_bars = 24'hxxxxxx;
            else if (x == 0 || x == 719 || y == 0 || y == 479) expect_bars = 24'hFFFFFF;
            else case (x / 90)
                0: expect_bars = 24'hFFFFFF;
                1: expect_bars = 24'hFFFF00;
                2: expect_bars = 24'h00FFFF;
                3: expect_bars = 24'h00FF00;
                4: expect_bars = 24'hFF00FF;
                5: expect_bars = 24'hFF0000;
                6: expect_bars = 24'h0000FF;
                default: expect_bars = 24'h000000;
            endcase
        end
    endfunction

    // -----------------------------------------------------------------------
    // Sink: decode the three lanes
    // -----------------------------------------------------------------------
    wire [9:0] s0 = tmds[9:0], s1 = tmds[19:10], s2 = tmds[29:20];
    wire [2:0] c0 = ctrl_dec(s0);
    wire       vgb = (s0 == REF_VGB_02) && (s1 == REF_GB_1) && (s2 == REF_VGB_02);

    integer x = -1, y = -1, gb_run = 0, frame = -1;
    integer errors = 0, checked = 0;
    reg     in_vs = 1'b0, saw_vs = 1'b0;
    reg [23:0] got, want;

    always @(posedge clk) if (rst_n) begin
        // vsync on the wire is negative: ch0 control D1 = 0 during the pulse.
        in_vs = c0[2] && !c0[1];
        if (in_vs) saw_vs = 1'b1;

        if (x >= 0) begin
            got  = {tmds_dec(s2), tmds_dec(s1), tmds_dec(s0)};
            want = bars ? expect_bars(x, y) : expect_apple(x, y);
            if (frame >= 1 && want !== 24'hxxxxxx) begin
                checked = checked + 1;
                if (got !== want) begin
                    if (errors < 10)
                        $display("FAIL: %s frame %0d pixel (%0d,%0d) = %06h, expected %06h",
                                 bars ? "bars" : "apple", frame, x, y, got, want);
                    errors = errors + 1;
                end
            end
            x = (x == 719) ? -1 : x + 1;
        end

        gb_run = vgb ? gb_run + 1 : 0;
        if (gb_run == 2) begin
            if (saw_vs) begin
                y      = 0;
                frame  = frame + 1;
                saw_vs = 1'b0;
            end else if (y >= 0) begin
                y = y + 1;
            end
            if (y >= 0) x = 0;
        end
    end

    // AVI InfoFrame as pushed to the scheduler: full-range RGB (PB3 Q = 10)
    // and a checksum making header + PB0..PB13 sum to zero.
    integer n_avi = 0, k;
    reg [7:0] avi_sum;
    always @(posedge clk) if (rst_n && u_tx.src_valid && u_tx.src_ready &&
                              u_tx.src_header[7:0] == 8'h82) begin
        n_avi   = n_avi + 1;
        avi_sum = u_tx.src_header[7:0] + u_tx.src_header[15:8] + u_tx.src_header[23:16];
        for (k = 0; k <= 13; k = k + 1) avi_sum = avi_sum + u_tx.src_body[8*k +: 8];
        if (u_tx.src_body[8*3 +: 8] !== 8'h08 || avi_sum !== 8'h00) begin
            $display("FAIL: AVI PB3 = %02h (want 08), checksum residue %02h",
                     u_tx.src_body[8*3 +: 8], avi_sum);
            errors = errors + 1;
        end
    end

    // -----------------------------------------------------------------------
    // The real character ROM, when it has been supplied
    //
    // The synthetic ROM above proves the *addressing* -- a wrong row, code or
    // bank shows up as the wrong dots. It cannot prove the *polarity*, because
    // a synthetic ROM has no letters in it. So also read the real 2732 and
    // check the two things that settle how it is read: glyph $20, which is what
    // $20 (space) resolves to, must be all zeroes, and glyph 1, which is what
    // $41 ('A') resolves to because char_rom_addr carries only six bits of the
    // code, must be a capital A read with a set bit meaning a lit dot.
    //
    // 342-0265-A, 4 KB. Run the video generator's expression by hand rather than
    // through the generator, so this stays fast and independent.
    // -----------------------------------------------------------------------
    reg [7:0] realrom [0:4095];
    reg       realrom_ok = 1'b0;
    reg [7:0] real_file [0:65535];
    integer   probe_fd;
    initial begin
        // $readmemh cannot report failure, so look for the file first.
        probe_fd = $fopen("roms/apple2e_char.hex", "r");
        if (probe_fd == 0) begin
            $display("tb_video_hdmi: no roms/apple2e_char.hex, skipping the real-ROM check");
        end else begin
            $fclose(probe_fd);
            $readmemh("roms/apple2e_char.hex", real_file);
            for (i = 0; i < 4096; i = i + 1) realrom[i] = real_file[i];
            realrom_ok = 1'b1;
            $display("tb_video_hdmi: read the real 2732 from roms/apple2e_char.hex");
        end
    end

    // $20 -> char_rom_addr bits [8:3] = 6'b100000 -> 0x100, so bytes 0x100..0x107
    // $41 -> bits [8:3] = 6'b000001 -> 0x008, so bytes 0x008..0x00F
    function [7:0] real_glyph_row;
        input [15:0] code;
        input [2:0]  row;
        reg [11:0] a;
        begin
            // {1'b0, code[7], code[6]&code[7], code[5:0], row}, flash off
            a = {1'b0, code[7], code[6] & code[7], code[5:0], row};
            real_glyph_row = realrom[a];
        end
    endfunction

    task check_real_rom;
        integer r;
        reg [7:0] arow [0:7];
        begin
            // space: blank
            for (r = 0; r < 8; r = r + 1) arow[r] = real_glyph_row(16'h0020, r[2:0]);
            for (r = 0; r < 8; r = r + 1) begin
                if (arow[r] !== 8'h00) begin
                    $display("FAIL: real ROM space row %0d is %02h, not 00", r, arow[r]);
                    errors = errors + 1;
                end
            end
            // 'A' at glyph 1, as a 7x8 picture with a set bit meaning lit
            for (r = 0; r < 8; r = r + 1) arow[r] = real_glyph_row(16'h0041, r[2:0]);
            if (arow[0] !== 8'h08 || arow[1] !== 8'h14 || arow[4] !== 8'h3E ||
                arow[7] !== 8'h00) begin
                $display("FAIL: real ROM 'A' rows are %02h %02h %02h ... %02h, expected 08 14 .. 3E .. 00",
                         arow[0], arow[1], arow[2], arow[7]);
                errors = errors + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    integer i, frame_a_checked;
    initial begin
        if (realrom_ok) check_real_rom();
        // Synthetic char ROM: every glyph row distinct, so a wrong address
        // (row, code or bank) shows up as a different dot pattern.
        for (i = 0; i < 4096; i = i + 1)
            crom[i] = (i * 8'd37) ^ (i >> 5) ^ 8'h5A;
        for (i = 0; i < 65536; i = i + 1)
            ram[i] = 8'h00;
        // Text page 1: distinct code per screen position.
        for (i = 0; i < 24 * 40; i = i + 1)
            ram[16'h0400 + row_base(i / 40) + (i % 40)] = (i * 7 + 3) & 8'hFF;

        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        // Frame 0 settles the sink; frame 1 is checked as Apple video.
        wait (frame == 2);
        frame_a_checked = checked;
        bars = 1'b1;
        wait (frame == 3);
        if (frame_a_checked != 720 * 480) begin
            $display("FAIL: checked %0d Apple pixels, expected %0d", frame_a_checked, 720 * 480);
            errors = errors + 1;
        end
        // The first bars frame ran from frame 2's start; check that it
        // produced a full frame of pixels (liveness box excluded).
        if (checked - frame_a_checked != 720 * 480 - 40 * 40) begin
            $display("FAIL: checked %0d bar pixels, expected %0d",
                     checked - frame_a_checked, 720 * 480 - 40 * 40);
            errors = errors + 1;
        end
        if (n_avi < 2) begin
            $display("FAIL: %0d AVI InfoFrames sent", n_avi);
            errors = errors + 1;
        end
        $display("%0d pixels checked (%0d Apple text, %0d colour bars)",
                 checked, frame_a_checked, checked - frame_a_checked);
        if (errors == 0) $display("tb_video_hdmi: PASS");
        else             $display("tb_video_hdmi: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule

`default_nettype wire
