// Apple //e Sound Generator for Tang Nano 20K
// Decodes $C030 speaker toggle and drives onboard MAX98357A I2S Class-D amplifier

module sound_generator (
    input  wire        clk,        // 27.0 MHz
    input  wire        reset,
    input  wire        spkr_pulse, // Pulsed high whenever $C030 is accessed

    // I2S interface for MAX98357A
    output reg         i2s_bclk,   // Pin 56
    output reg         i2s_lrck,   // Pin 55
    output reg         i2s_din,    // Pin 54
    output wire        pa_en,      // Pin 51 (Active high amplifier enable)

    // Direct 1-bit speaker output
    output reg         spkr_out
);

    assign pa_en = 1'b1; // Keep power amplifier enabled

    // Speaker flip-flop toggle on $C030 access
    reg prev_pulse;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            spkr_out   <= 1'b0;
            prev_pulse <= 1'b0;
        end else begin
            prev_pulse <= spkr_pulse;
            if (spkr_pulse && !prev_pulse) begin
                spkr_out <= ~spkr_out;
            end
        end
    end

    // Acoustic impulse model:
    // Physical Apple II speaker produces a damped acoustic pop on each toggle.
    reg signed [15:0] audio_sample = 16'sd0;
    reg prev_spkr_out;

    // BCLK generation: 27 MHz / 9 = 3.0 MHz
    // 64 BCLKs per sample frame -> 3.0 MHz / 64 = 46.875 kHz sample rate
    reg [3:0] bclk_div = 4'd0;
    reg [5:0] bit_cnt  = 6'd0; // 0..63
    reg [31:0] shift_reg = 32'd0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            audio_sample  <= 16'sd0;
            prev_spkr_out <= 1'b0;
            bclk_div      <= 4'd0;
            bit_cnt       <= 6'd0;
            i2s_bclk      <= 1'b0;
            i2s_lrck      <= 1'b0;
            i2s_din       <= 1'b0;
            shift_reg     <= 32'd0;
        end else begin
            prev_spkr_out <= spkr_out;

            // BCLK clock division
            if (bclk_div == 4'd4) begin
                bclk_div <= 4'd0;
                i2s_bclk <= ~i2s_bclk;

                // Shift data out on falling edge of BCLK
                if (i2s_bclk) begin
                    i2s_din   <= shift_reg[31];
                    shift_reg <= {shift_reg[30:0], 1'b0};

                    if (bit_cnt == 6'd63) begin
                        bit_cnt  <= 6'd0;
                        i2s_lrck <= 1'b0; // Left channel start

                        // Update acoustic pop with exponential decay
                        if (spkr_out != prev_spkr_out) begin
                            audio_sample <= spkr_out ? 16'sd16000 : -16'sd16000;
                        end else begin
                            audio_sample <= audio_sample - (audio_sample >>> 6); // Damped decay
                        end

                        // Load 16-bit audio sample into Left and Right channels (padded to 32 bits each)
                        shift_reg <= {audio_sample, 16'd0};
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                        if (bit_cnt == 6'd31) begin
                            i2s_lrck  <= 1'b1; // Right channel start
                            shift_reg <= {audio_sample, 16'd0};
                        end
                    end
                end
            end else begin
                bclk_div <= bclk_div + 1'b1;
            end
        end
    end

endmodule
