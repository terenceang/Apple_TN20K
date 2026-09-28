// HDMI / DVI Transmitter for Tang Nano 20K
// Uses Gowin OSER10 and TLVDS_OBUF primitives

module hdmi_tx (
    input  wire       clk_pixel,   // 27.0 MHz pixel clock
    input  wire       clk_tmds,    // 135.0 MHz (5x bit clock)
    input  wire       reset,       // Active-high reset
    input  wire [7:0] red,
    input  wire [7:0] green,
    input  wire [7:0] blue,
    input  wire       hsync,
    input  wire       vsync,
    input  wire       de,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);

    wire [9:0] tmds_10b_blue;
    wire [9:0] tmds_10b_green;
    wire [9:0] tmds_10b_red;

    // Channel 0: Blue + Hsync/Vsync
    tmds_encoder enc_b (
        .clk(clk_pixel),
        .din(blue),
        .c({vsync, hsync}),
        .de(de),
        .dout(tmds_10b_blue)
    );

    // Channel 1: Green + 2'b00
    tmds_encoder enc_g (
        .clk(clk_pixel),
        .din(green),
        .c(2'b00),
        .de(de),
        .dout(tmds_10b_green)
    );

    // Channel 2: Red + 2'b00
    tmds_encoder enc_r (
        .clk(clk_pixel),
        .din(red),
        .c(2'b00),
        .de(de),
        .dout(tmds_10b_red)
    );

    // Gowin OSER10 Serializers
    wire [2:0] tmds_ser;
    wire       tmds_clk_ser;

    // Channel 0 (Blue) Serializer
    OSER10 ser_d0 (
        .Q(tmds_ser[0]),
        .D0(tmds_10b_blue[0]), .D1(tmds_10b_blue[1]),
        .D2(tmds_10b_blue[2]), .D3(tmds_10b_blue[3]),
        .D4(tmds_10b_blue[4]), .D5(tmds_10b_blue[5]),
        .D6(tmds_10b_blue[6]), .D7(tmds_10b_blue[7]),
        .D8(tmds_10b_blue[8]), .D9(tmds_10b_blue[9]),
        .PCLK(clk_pixel),
        .FCLK(clk_tmds),
        .RESET(reset)
    );

    // Channel 1 (Green) Serializer
    OSER10 ser_d1 (
        .Q(tmds_ser[1]),
        .D0(tmds_10b_green[0]), .D1(tmds_10b_green[1]),
        .D2(tmds_10b_green[2]), .D3(tmds_10b_green[3]),
        .D4(tmds_10b_green[4]), .D5(tmds_10b_green[5]),
        .D6(tmds_10b_green[6]), .D7(tmds_10b_green[7]),
        .D8(tmds_10b_green[8]), .D9(tmds_10b_green[9]),
        .PCLK(clk_pixel),
        .FCLK(clk_tmds),
        .RESET(reset)
    );

    // Channel 2 (Red) Serializer
    OSER10 ser_d2 (
        .Q(tmds_ser[2]),
        .D0(tmds_10b_red[0]), .D1(tmds_10b_red[1]),
        .D2(tmds_10b_red[2]), .D3(tmds_10b_red[3]),
        .D4(tmds_10b_red[4]), .D5(tmds_10b_red[5]),
        .D6(tmds_10b_red[6]), .D7(tmds_10b_red[7]),
        .D8(tmds_10b_red[8]), .D9(tmds_10b_red[9]),
        .PCLK(clk_pixel),
        .FCLK(clk_tmds),
        .RESET(reset)
    );

    // Clock Channel Serializer: transmits 5 ones and 5 zeros (10'b1111100000)
    OSER10 ser_clk (
        .Q(tmds_clk_ser),
        .D0(1'b0), .D1(1'b0), .D2(1'b0), .D3(1'b0), .D4(1'b0),
        .D5(1'b1), .D6(1'b1), .D7(1'b1), .D8(1'b1), .D9(1'b1),
        .PCLK(clk_pixel),
        .FCLK(clk_tmds),
        .RESET(reset)
    );

    // Gowin True LVDS Output Buffers for Tang Nano 20K (Bank 5)
    TLVDS_OBUF tlvds_d0  (.I(tmds_ser[0]),    .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    TLVDS_OBUF tlvds_d1  (.I(tmds_ser[1]),    .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    TLVDS_OBUF tlvds_d2  (.I(tmds_ser[2]),    .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    TLVDS_OBUF tlvds_clk (.I(tmds_clk_ser),   .O(tmds_clk_p),  .OB(tmds_clk_n));

endmodule
