// Apple //e Video Display Generator for Tang Nano 20K
// Formats 560x384 Apple II raster into standard CEA-861 720x480 @ 60Hz HDMI frame
//
// Raster timing, sync and blanking belong to hdmi_tx, which asks for each
// pixel's colour combinationally on the cycle it presents (pixel_x, pixel_y).
// This generator's colour output is registered, so top.v feeds it the
// position of the *next* pixel (h_cnt = pixel_x + 1): the colour computed
// for h_cnt this cycle is on red/green/blue the next cycle, exactly when
// hdmi_tx is at that pixel. h_cnt must step by one every clock (it runs
// through the blanking region too, wrapping via 1023 -> 0), since the
// column counter and prefetch sequence below count clocks, not positions.

module video_generator (
    input  wire        clk_pixel,    // 27.0 MHz
    input  wire        reset,
    input  wire        flash_clk,    // ~1.6 Hz flashing text clock

    // Raster position of the next pixel, from hdmi_tx (see above)
    input  wire [9:0]  h_cnt,        // 0..719 active, >= 720 blanking
    input  wire [9:0]  v_cnt,        // 0..479 active, 480..524 blanking

    // Softswitches
    input  wire        text_mode,    // 1: Text, 0: Graphics
    input  wire        mixed_mode,   // 1: Bottom 4 lines are text
    input  wire        page2,        // 1: Page 2, 0: Page 1
    input  wire        hires_mode,   // 1: Hi-Res, 0: Lo-Res

    // Video RAM interface (reads from main 64KB RAM)
    output wire        vram_req,
    output wire [15:0] vram_addr,
    input  wire [7:0]  vram_data,

    // Character ROM interface
    output wire [11:0] char_rom_addr,
    input  wire [7:0]  char_rom_data,

    // Pixel colour to hdmi_tx, for the pixel one clock after h_cnt/v_cnt
    output reg  [7:0]  red,
    output reg  [7:0]  green,
    output reg  [7:0]  blue,

    // Vertical blanking status for Apple II $C019 softswitch
    output wire        vbl
);

    localparam H_VISIBLE     = 720;
    localparam V_VISIBLE     = 480;

    // VBL status for Apple II ($C019: bit 7 = 1 during vertical blanking)
    assign vbl = (v_cnt >= 432);

    // Apple II active area: 560x384 centered in 720x480
    // X: 80 .. 639 (560 pixels = 40 cols * 14 px)
    // Y: 48 .. 431 (384 lines = 192 lines * 2)
    wire in_apple_x = (h_cnt >= 80 && h_cnt < 640);
    wire in_apple_y = (v_cnt >= 48 && v_cnt < 432);
    wire in_apple_screen = in_apple_x && in_apple_y;

    wire [8:0] a2_y = in_apple_y ? ((v_cnt - 10'd48) >> 1) : 9'd0; // 0..191

    // Text row (0..23) and column (0..39)
    wire [4:0] text_row = a2_y[7:3];       // a2_y / 8
    wire [2:0] glyph_row = a2_y[2:0];      // a2_y % 8
    
    // Column counter (0..39)
    reg [5:0] col_cnt;
    reg [3:0] sub_col; // 0..13 (14 cycles per character)

    always @(posedge clk_pixel or posedge reset) begin
        if (reset) begin
            col_cnt <= 6'd0;
            sub_col <= 4'd0;
        end else if (in_apple_x) begin
            if (sub_col == 4'd13) begin
                sub_col <= 4'd0;
                col_cnt <= (col_cnt == 6'd39) ? 6'd0 : col_cnt + 1'b1;
            end else begin
                sub_col <= sub_col + 1'b1;
            end
        end else begin
            col_cnt <= 6'd0;
            sub_col <= 4'd0;
        end
    end

    // Next column to prefetch from RAM
    wire [5:0] fetch_col = (sub_col >= 4'd9) ? ((col_cnt == 6'd39) ? 6'd0 : col_cnt + 1'b1) : col_cnt;

    // Apple II text/lores interleaved memory base address calculation:
    // Screen is split into 3 groups of 8 rows (each 128 bytes apart), offset by 40 bytes per group.
    wire [6:0]  row_group_offset = (text_row[4:3] == 2'd1) ? 7'd40 :
                                   (text_row[4:3] == 2'd2) ? 7'd80 : 7'd0;
    wire [9:0]  row_offset       = {text_row[2:0], 7'd0} + {3'd0, row_group_offset};
    wire [15:0] base_page        = page2 ? 16'h0800 : 16'h0400;
    assign vram_addr             = base_page + {6'd0, row_offset} + {10'd0, fetch_col};

    // Request RAM access during prefetch cycles only (1 cycle per character column + 1 cycle before col 0)
    assign vram_req = in_apple_y && ((in_apple_x && (sub_col == 4'd9)) || (h_cnt == 10'd75));

    // Pipelined data latches
    reg [7:0] char_code;
    reg [7:0] char_code_display;
    reg [7:0] glyph_byte;

    // Character ROM address lookup
    assign char_rom_addr = {
        1'b0,
        (char_code[7] | (char_code[6] & flash_clk)),
        (char_code[6] & char_code[7]),
        char_code[5:0],
        glyph_row[2:0]
    };

    // Prefetch sequence during each 14-cycle character slot:
    // Cycle  9: vram_req asserted, vram_addr presented
    // Cycle 10: RAM serves vram_addr, core latches vram_data
    // Cycle 11: Latch vram_data into char_code
    // Cycle 12: char_rom_addr presented to Char ROM
    // Cycle 13: Latch char_rom_data into glyph_byte and char_code_display for display on next slot
    always @(posedge clk_pixel or posedge reset) begin
        if (reset) begin
            char_code         <= 8'hA0; // space
            char_code_display <= 8'hA0;
            glyph_byte        <= 8'h00;
        end else begin
            if (sub_col == 4'd11 || h_cnt == 10'd77) begin
                char_code <= vram_data;
            end
            if (sub_col == 4'd13 || h_cnt == 10'd79) begin
                glyph_byte        <= char_rom_data;
                char_code_display <= char_code;
            end
        end
    end

    // Pixel dot extraction:
    // Each of the 7 character dots spans 2 pixel clocks:
    // sub_col: 0..1 (dot 0), 2..3 (dot 1), ..., 12..13 (dot 6)
    wire [2:0] dot_index = sub_col[3:1]; // 0..6
    wire pixel_on = ~glyph_byte[dot_index]; // Invert: 0 in ROM = bright dot

    // Lo-Res graphics support:
    wire is_text_line = text_mode || (mixed_mode && (text_row >= 5'd20));
    wire [3:0] lores_color_idx = glyph_row[2] ? char_code_display[7:4] : char_code_display[3:0];

    // Lo-Res 16-color RGB palette
    reg [7:0] lores_r, lores_g, lores_b;
    always @(*) begin
        case (lores_color_idx)
            4'h0: begin lores_r = 8'h00; lores_g = 8'h00; lores_b = 8'h00; end // Black
            4'h1: begin lores_r = 8'h90; lores_g = 8'h17; lores_b = 8'h40; end // Magenta
            4'h2: begin lores_r = 8'h40; lores_g = 8'h2C; lores_b = 8'hA5; end // Dark Blue
            4'h3: begin lores_r = 8'hD0; lores_g = 8'h43; lores_b = 8'hE5; end // Purple
            4'h4: begin lores_r = 8'h00; lores_g = 8'h69; lores_b = 8'h40; end // Dark Green
            4'h5: begin lores_r = 8'h80; lores_g = 8'h80; lores_b = 8'h80; end // Gray 1
            4'h6: begin lores_r = 8'h2F; lores_g = 8'h95; lores_b = 8'hE5; end // Medium Blue
            4'h7: begin lores_r = 8'hBF; lores_g = 8'hAB; lores_b = 8'hFF; end // Light Blue
            4'h8: begin lores_r = 8'h40; lores_g = 8'h54; lores_b = 8'h00; end // Brown
            4'h9: begin lores_r = 8'hE0; lores_g = 8'h6A; lores_b = 8'h1A; end // Orange
            4'hA: begin lores_r = 8'h80; lores_g = 8'h80; lores_b = 8'h80; end // Gray 2
            4'hB: begin lores_r = 8'hFF; lores_g = 8'h96; lores_b = 8'hBF; end // Pink
            4'hC: begin lores_r = 8'h30; lores_g = 8'hC0; lores_b = 8'h1A; end // Light Green
            4'hD: begin lores_r = 8'hBF; lores_g = 8'hD3; lores_b = 8'h5A; end // Yellow
            4'hE: begin lores_r = 8'h6F; lores_g = 8'hE8; lores_b = 8'hBF; end // Aquamarine
            4'hF: begin lores_r = 8'hFF; lores_g = 8'hFF; lores_b = 8'hFF; end // White
        endcase
    end

    // Output color assignment
    always @(posedge clk_pixel or posedge reset) begin
        if (reset) begin
            red   <= 8'h00;
            green <= 8'h00;
            blue  <= 8'h00;
        end else begin
            if (in_apple_screen) begin
                if (is_text_line) begin
                    // Authentic Apple II Green Phosphor (or crisp monochrome)
                    red   <= pixel_on ? 8'h20 : 8'h02;
                    green <= pixel_on ? 8'hE8 : 8'h06;
                    blue  <= pixel_on ? 8'h20 : 8'h02;
                end else begin
                    // Lo-Res graphics color
                    red   <= lores_r;
                    green <= lores_g;
                    blue  <= lores_b;
                end
            end else begin
                // Border & blanking: black
                red   <= 8'h00;
                green <= 8'h00;
                blue  <= 8'h00;
            end
        end
    end

endmodule
