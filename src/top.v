// Apple //e Computer on Tang Nano 20K FPGA
// Top-Level Module integrating CPU, Memory, Video/HDMI, I2S Audio, and UART/HID/Gamepad Inputs

`include "src/hdmi/hdmi_defs.vh"

module top (
    input  wire       clk,        // 27.0 MHz onboard crystal (Pin 4)
    input  wire       btn_s1,     // Pushbutton S1 (Pin 88, active high: pressed = 1)
    input  wire       btn_s2,     // Pushbutton S2 (Pin 87, active high: pressed = 1)

    // Onboard LEDs (Pins 15-20, active-low on Tang Nano 20K)
    output wire [5:0] led,

    // UART Console (BL616 USB-Serial or Bluetooth-to-UART module)
    input  wire       uart_rx,    // Pin 70
    output wire       uart_tx,    // Pin 69

    // HDMI TMDS Output (Pins 33-40)
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n,

    // Onboard MAX98357A I2S Class-D Audio Amplifier
    output wire       i2s_bclk,   // Pin 56
    output wire       i2s_lrck,   // Pin 55
    output wire       i2s_din,    // Pin 54
    output wire       pa_en       // Pin 51
);

    // Power-on and Button Reset Generator (S2 pushbutton triggers reset when pressed = 1)
    reg [19:0] rst_cnt = 20'd0;

    always @(posedge clk) begin
        if (btn_s2)
            rst_cnt <= 20'd0;
        else if (rst_cnt != 20'hFFFFF)
            rst_cnt <= rst_cnt + 1'b1;
    end

    wire sys_reset = (rst_cnt != 20'hFFFFF);

    // Clock Generator
    wire clk_tmds;
    wire clk_pixel;
    wire pll_locked;
    wire ce_1m;
    wire flash_clk;

    clk_gen u_clk_gen (
        .clk_in(clk),
        .rst_in(1'b0),
        .clk_tmds(clk_tmds),
        .clk_pixel(clk_pixel),
        .pll_locked(pll_locked),
        .ce_1m(ce_1m),
        .flash_clk(flash_clk)
    );

    // Serial Debugger & Apple //e Console Mirror
    wire [7:0]  rx_byte;
    wire        rx_valid;
    wire        dbg_mode;
    wire        cpu_rdy;
    wire [15:0] dbg_mem_addr;
    wire [7:0]  dbg_mem_din;

    wire [15:0] debug_cpu_pc;
    wire [15:0] debug_cpu_addr;
    wire [7:0]  debug_cpu_dout;
    wire        debug_cpu_we;
    wire        debug_cpu_sync;
    wire [7:0]  debug_cpu_a;
    wire [7:0]  debug_cpu_x;
    wire [7:0]  debug_cpu_y;
    wire [7:0]  debug_cpu_s;
    wire [7:0]  debug_cpu_p;
    wire [7:0]  debug_cpu_ir;

    // Softswitch state wires
    wire        spkr_pulse;
    wire        text_mode;
    wire        mixed_mode;
    wire        page2;
    wire        hires_mode;
    wire        vbl;

    serial_debugger u_debugger (
        .clk(clk_pixel),
        .reset(sys_reset),
        .ce_1m(ce_1m),
        .uart_tx(uart_tx),
        .rx_byte(rx_byte),
        .rx_valid(rx_valid),
        .dbg_mode(dbg_mode),
        .cpu_rdy(cpu_rdy),
        .cpu_reset_req(cpu_reset_req),
        .dbg_mem_addr(dbg_mem_addr),
        .dbg_mem_din(dbg_mem_din),
        .cpu_pc(debug_cpu_pc),
        .cpu_a(debug_cpu_a),
        .cpu_x(debug_cpu_x),
        .cpu_y(debug_cpu_y),
        .cpu_s(debug_cpu_s),
        .cpu_p(debug_cpu_p),
        .cpu_ir(debug_cpu_ir),
        .cpu_addr(debug_cpu_addr),
        .cpu_dout(debug_cpu_dout),
        .cpu_we(debug_cpu_we),
        .cpu_sync(debug_cpu_sync),
        .text_mode(text_mode),
        .mixed_mode(mixed_mode),
        .page2(page2),
        .hires_mode(hires_mode),
        .pll_locked(pll_locked)
    );

    // Input Controller (UART RX, Keyboard & Gamepad)
    wire [7:0] io_addr;
    wire       io_read;
    wire       io_write;
    wire [7:0] input_dout;
    wire       input_hit;
    wire       key_strobe;
    wire       kbd_reset;

    input_controller u_input (
        .clk(clk_pixel),
        .reset(sys_reset),
        .ce_1m(ce_1m),
        .uart_rx(uart_rx),
        .dbg_mode(dbg_mode),
        .rx_byte(rx_byte),
        .rx_valid(rx_valid),
        .io_addr(io_addr),
        .io_read(io_read),
        .io_write(io_write),
        .io_dout(input_dout),
        .io_hit(input_hit),
        .key_strobe(key_strobe),
        .kbd_reset(kbd_reset)
    );

    // Apple //e Core (CPU, Memory, Softswitches)
    wire        cpu_reset_req;
    wire        vram_req;
    wire [15:0] vram_addr;
    wire [7:0]  vram_data;
    wire [11:0] char_rom_addr;
    wire [7:0]  char_rom_data;

    apple2_core u_core (
        .clk(clk_pixel),
        .reset(sys_reset | cpu_reset_req | kbd_reset),
        .ce_1m(ce_1m),
        .input_dout(input_dout),
        .input_hit(input_hit),
        .io_addr(io_addr),
        .io_read(io_read),
        .io_write(io_write),
        .spkr_pulse(spkr_pulse),
        .text_mode(text_mode),
        .mixed_mode(mixed_mode),
        .page2(page2),
        .hires_mode(hires_mode),
        .vbl(vbl),
        .vram_req(vram_req),
        .vram_addr(vram_addr),
        .vram_data(vram_data),
        .char_rom_addr(char_rom_addr),
        .char_rom_data(char_rom_data),
        .cpu_rdy(cpu_rdy),
        .dbg_mem_addr(dbg_mem_addr),
        .dbg_mem_din(dbg_mem_din),
        .debug_cpu_pc(debug_cpu_pc),
        .debug_cpu_addr(debug_cpu_addr),
        .debug_cpu_dout(debug_cpu_dout),
        .debug_cpu_we(debug_cpu_we),
        .debug_cpu_sync(debug_cpu_sync),
        .debug_cpu_a(debug_cpu_a),
        .debug_cpu_x(debug_cpu_x),
        .debug_cpu_y(debug_cpu_y),
        .debug_cpu_s(debug_cpu_s),
        .debug_cpu_p(debug_cpu_p),
        .debug_cpu_ir(debug_cpu_ir)
    );

    // HDMI link reset: held only until the PLL has locked and the pixel clock
    // has run a while, and deliberately independent of sys_reset, so the S2
    // button resets the Apple without making the display drop and re-sync.
    reg [7:0] hdmi_rst_cnt = 8'd0;
    wire      hdmi_rst_n   = hdmi_rst_cnt[7];
    always @(posedge clk_pixel or negedge pll_locked) begin
        if (!pll_locked)       hdmi_rst_cnt <= 8'd0;
        else if (!hdmi_rst_n)  hdmi_rst_cnt <= hdmi_rst_cnt + 1'b1;
    end

    // hdmi_tx owns the 720x480p raster and asks for the colour of
    // (pixel_x, pixel_y) combinationally, on the same cycle.
    wire [9:0]  pixel_x;
    wire [9:0]  pixel_y;

    // Video Generator (Apple II Raster to 720x480 CEA-861). Its colour output
    // is registered, so it is given the next pixel's position; see the
    // header of src/video_generator.v.
    wire [7:0] vid_red;
    wire [7:0] vid_green;
    wire [7:0] vid_blue;

    video_generator u_video (
        .clk_pixel(clk_pixel),
        .reset(sys_reset),
        .flash_clk(flash_clk),
        .h_cnt(pixel_x + 10'd1),
        .v_cnt(pixel_y),
        .text_mode(text_mode),
        .mixed_mode(mixed_mode),
        .page2(page2),
        .hires_mode(hires_mode),
        .vram_req(vram_req),
        .vram_addr(vram_addr),
        .vram_data(vram_data),
        .char_rom_addr(char_rom_addr),
        .char_rom_data(char_rom_data),
        .red(vid_red),
        .green(vid_green),
        .blue(vid_blue),
        .vbl(vbl)
    );

    // HDMI bring-up test pattern (color bars + 1kHz tone). Hold S1 (pressed = 1)
    // to force the output to this pattern instead of the Apple //e
    // framebuffer, to verify the clocking/TMDS/serializer/audio path
    // independent of the CPU, RAM and video_generator. See
    // src/colorbar_gen.v.
    wire test_pattern_enable = btn_s1;

    wire [23:0] bar_rgb;

    colorbar_gen u_colorbar (
        .clk_pixel(clk_pixel),
        .reset(~hdmi_rst_n),
        .x(pixel_x),
        .y(pixel_y),
        .rgb(bar_rgb)
    );

    wire [23:0] hdmi_rgb = test_pattern_enable ? bar_rgb
                                               : {vid_red, vid_green, vid_blue};

    // HDMI audio: the same speaker-model PCM that goes to the I2S amplifier
    // (sound_generator.audio_sample, updated at 46.875 kHz), sampled at
    // VM_AUDIO_HZ = 48 kHz. 27 MHz / 48 kHz = 562.5 clocks, so a fractional
    // accumulator alternates 562 and 563.
    //
    // The two rates are coupled: sound_generator holds audio_sample for one
    // I2S frame of exactly 576 clocks, so it must stay at 46.875 kHz or this
    // resampler plays it at the wrong speed. sim/tb_sound.v checks that.
    wire signed [15:0] spkr_sample;
    reg  [24:0]        hdmi_audio_acc   = 25'd0;
    reg                hdmi_audio_valid = 1'b0;
    reg  [15:0]        hdmi_audio_pcm   = 16'd0;

    always @(posedge clk_pixel) begin
        if (!hdmi_rst_n) begin
            hdmi_audio_acc   <= 25'd0;
            hdmi_audio_valid <= 1'b0;
        end else begin
            hdmi_audio_valid <= 1'b0;
            if (hdmi_audio_acc + `VM_AUDIO_HZ >= `VM_PIXEL_HZ) begin
                hdmi_audio_acc   <= hdmi_audio_acc + `VM_AUDIO_HZ - `VM_PIXEL_HZ;
                hdmi_audio_valid <= 1'b1;
                hdmi_audio_pcm   <= spkr_sample;
            end else begin
                hdmi_audio_acc <= hdmi_audio_acc + `VM_AUDIO_HZ;
            end
        end
    end

    // HDMI transmitter: 720x480p59.94 (VIC 2) with data islands carrying
    // 48 kHz L-PCM audio, ACR, and the AVI / Audio InfoFrames. Mode and audio
    // rate come from src/hdmi/hdmi_defs.vh. The Apple palette is full-range
    // RGB, so the AVI InfoFrame says so (a sink would otherwise assume
    // limited range for this CE mode and crush blacks / clip whites).
    wire [39:0] tmds;

    hdmi_tx #(
        .RGB_QUANT(2'b10)
    ) u_hdmi (
        .clk_pixel(clk_pixel),
        .rst_n(hdmi_rst_n),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .video_rgb(hdmi_rgb),
        .audio_valid(hdmi_audio_valid),
        .audio_l(hdmi_audio_pcm),
        .audio_r(hdmi_audio_pcm),
        .tmds(tmds[29:0])
    );

    // Lane 3 is the TMDS clock: the constant 0000011111, one pixel period.
    assign tmds[39:30] = 10'b0000011111;

    // Serializers: OSER10 shifts D0 first (TMDS bit 0 first), DDR on
    // clk_tmds (5x), 270 Mbit/s per lane. Pins 33-40 are true-LVDS pairs on
    // this package, so TLVDS_OBUF (apicula rejects ELVDS_OBUF there with
    // "it is a true lvds pin"; the Tang Nano 9K's GW1NR-9 is different).
    wire [3:0] tmds_pad_p, tmds_pad_n;
    assign {tmds_clk_p, tmds_d_p} = tmds_pad_p;
    assign {tmds_clk_n, tmds_d_n} = tmds_pad_n;

    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : g_tmds_lane
            wire [9:0] sym = tmds[10*lane +: 10];
            wire       q;
            OSER10 #(.GSREN("false"), .LSREN("true")) u_ser (
                .D0(sym[0]), .D1(sym[1]), .D2(sym[2]), .D3(sym[3]), .D4(sym[4]),
                .D5(sym[5]), .D6(sym[6]), .D7(sym[7]), .D8(sym[8]), .D9(sym[9]),
                .PCLK(clk_pixel), .FCLK(clk_tmds), .RESET(~hdmi_rst_n), .Q(q)
            );
            TLVDS_OBUF u_obuf (.I(q), .O(tmds_pad_p[lane]), .OB(tmds_pad_n[lane]));
        end
    endgenerate

    // Sound Generator (MAX98357A I2S Class-D Amplifier)
    sound_generator u_sound (
        .clk(clk_pixel),
        .reset(sys_reset),
        .spkr_pulse(spkr_pulse),
        .test_tone_enable(test_pattern_enable),
        .i2s_bclk(i2s_bclk),
        .i2s_lrck(i2s_lrck),
        .i2s_din(i2s_din),
        .pa_en(pa_en),
        .spkr_out(),
        .audio_sample(spkr_sample)
    );

    // Diagnostic LEDs (active-low)
    // LED 0: Heartbeat blinker (~1.6 Hz, driven by clk_gen flash_clk as SSOT)
    // LED 1: PLL Locked (ON when locked)
    // LED 2: Reset status (ON when running)
    // LED 3: CPU Memory Write Activity
    // LED 4: Video mode (ON = Text, OFF = Graphics)
    // LED 5: Keyboard strobe active
    assign led[0] = ~flash_clk;
    assign led[1] = ~pll_locked;
    assign led[2] = sys_reset;
    assign led[3] = ~debug_cpu_we;
    assign led[4] = ~text_mode;
    assign led[5] = ~key_strobe;

endmodule
