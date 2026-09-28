// Apple //e on Tang Nano 20K - Clock Generator
// Generates 135 MHz TMDS clock, 27 MHz pixel clock, and 1.023 MHz CPU clock enable

module clk_gen (
    input  wire clk_in,       // 27.0 MHz onboard crystal (Pin 4)
    input  wire rst_in,       // Active-high reset
    output wire clk_tmds,     // 135.0 MHz (5x bit clock for HDMI)
    output wire clk_pixel,    // 27.0 MHz pixel clock
    output wire pll_locked,   // PLL locked indicator
    output reg  ce_1m,        // 1.023 MHz clock enable for 6502 CPU
    output reg  ce_14m,       // 14.318 MHz clock enable
    output reg  flash_clk     // ~2 Hz flashing text clock
);

    assign clk_pixel = clk_in; // 27 MHz pixel clock

    // Gowin rPLL instance: 27 MHz in -> 135 MHz out
    rPLL #(
        .FCLKIN("27.0"),
        .IDIV_SEL(0),   // PFD = 27.0 MHz
        .FBDIV_SEL(4),  // CLKOUT = 135.0 MHz
        .ODIV_SEL(4)    // VCO = 540.0 MHz
    ) pll_inst (
        .CLKIN(clk_in),
        .CLKOUT(clk_tmds),
        .LOCK(pll_locked),
        .CLKOUTP(),
        .CLKOUTD(),
        .CLKOUTD3(),
        .RESET(rst_in),
        .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .ODSEL(6'b0),
        .PSDA(4'b0),
        .DUTYDA(4'b0),
        .FDLY(4'b0)
    );

    // 14.31818 MHz clock enable accumulator:
    // step = round(14318182 * 2^32 / 27000000) = 2277916301
    localparam [31:0] STEP_14M = 32'd2277916301;
    reg [32:0] acc_14m = 33'd0;

    always @(posedge clk_pixel or posedge rst_in) begin
        if (rst_in) begin
            acc_14m <= 33'd0;
            ce_14m  <= 1'b0;
        end else begin
            acc_14m <= {1'b0, acc_14m[31:0]} + {1'b0, STEP_14M};
            ce_14m  <= acc_14m[32];
        end
    end

    // 1.022727 MHz CPU clock enable accumulator:
    // step = round(1022727.27 * 2^32 / 27000000) = 162708307
    localparam [31:0] STEP_1M = 32'd162708307;
    reg [32:0] acc_1m = 33'd0;

    always @(posedge clk_pixel or posedge rst_in) begin
        if (rst_in) begin
            acc_1m <= 33'd0;
            ce_1m  <= 1'b0;
        end else begin
            acc_1m <= {1'b0, acc_1m[31:0]} + {1'b0, STEP_1M};
            ce_1m  <= acc_1m[32];
        end
    end

    // Flash clock: ~2 Hz for Apple II flashing characters
    // 27,000,000 / 2^24 = ~1.61 Hz
    reg [23:0] flash_cnt = 24'd0;
    always @(posedge clk_pixel or posedge rst_in) begin
        if (rst_in) begin
            flash_cnt <= 24'd0;
            flash_clk <= 1'b0;
        end else begin
            flash_cnt <= flash_cnt + 1'b1;
            flash_clk <= flash_cnt[23];
        end
    end

endmodule
