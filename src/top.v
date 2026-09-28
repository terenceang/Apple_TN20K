// Apple //e Computer on Tang Nano 20K FPGA
// Top-Level Module integrating CPU, Memory, Video/HDMI, I2S Audio, and UART/HID/Gamepad Inputs

module top (
    input  wire       clk,        // 27.0 MHz onboard crystal (Pin 4)
    input  wire       btn_s1,     // Pushbutton S1 (Pin 88, active high)
    input  wire       btn_s2,     // Pushbutton S2 (Pin 87, active high)

    // Onboard LEDs (Pins 15-20, active-low on Tang Nano 20K)
    output wire [5:0] led,

    // UART Console (BL616 USB-Serial or Bluetooth-to-UART module)
    input  wire       uart_rx,    // Pin 70
    output wire       uart_tx,    // Pin 69

    // HDMI / DVI TMDS Output (Pins 33-40)
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

    // Power-on and Button Reset Generator
    reg [19:0] rst_cnt = 20'd0;
    wire power_on_reset = (rst_cnt != 20'hFFFFF);

    always @(posedge clk) begin
        if (rst_cnt != 20'hFFFFF)
            rst_cnt <= rst_cnt + 1'b1;
    end

    wire sys_reset = power_on_reset;

    // Clock Generator
    wire clk_tmds;
    wire clk_pixel;
    wire pll_locked;
    wire ce_1m;
    wire ce_14m;
    wire flash_clk;

    clk_gen u_clk_gen (
        .clk_in(clk),
        .rst_in(1'b0),
        .clk_tmds(clk_tmds),
        .clk_pixel(clk_pixel),
        .pll_locked(pll_locked),
        .ce_1m(ce_1m),
        .ce_14m(ce_14m),
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
        .dbg_mem_addr(dbg_mem_addr),
        .dbg_mem_din(dbg_mem_din),
        .cpu_pc(debug_cpu_pc),
        .cpu_a(debug_cpu_a),
        .cpu_x(debug_cpu_x),
        .cpu_y(debug_cpu_y),
        .cpu_s(debug_cpu_s),
        .cpu_p(debug_cpu_p),
        .cpu_ir(debug_cpu_ir),
        .cpu_addr(debug_cpu_pc),
        .cpu_dout(debug_cpu_dout),
        .cpu_we(debug_cpu_we),
        .cpu_sync(debug_cpu_sync),
        .text_mode(text_mode),
        .mixed_mode(mixed_mode),
        .page2(page2),
        .hires_mode(hires_mode),
        .spkr_pulse(spkr_pulse),
        .pll_locked(pll_locked)
    );

    // Input Controller (UART RX, Keyboard & Gamepad)
    wire [7:0] io_addr;
    wire       io_read;
    wire       io_write;
    wire [7:0] input_dout;
    wire       input_hit;
    wire       key_strobe;

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
        .key_strobe(key_strobe)
    );

    // Apple //e Core (CPU, Memory, Softswitches)
    wire [15:0] vram_addr;
    wire [7:0]  vram_data;
    wire [11:0] char_rom_addr;
    wire [7:0]  char_rom_data;

    apple2_core u_core (
        .clk(clk_pixel),
        .reset(sys_reset),
        .ce_1m(ce_1m),
        .flash_clk(flash_clk),
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
        .vram_addr(vram_addr),
        .vram_data(vram_data),
        .char_rom_addr(char_rom_addr),
        .char_rom_data(char_rom_data),
        .cpu_rdy(cpu_rdy),
        .dbg_mem_addr(dbg_mem_addr),
        .dbg_mem_din(dbg_mem_din),
        .debug_cpu_pc(debug_cpu_pc),
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

    // Video Generator (Apple II Raster to 720x480 CEA-861)
    wire [7:0] vid_red;
    wire [7:0] vid_green;
    wire [7:0] vid_blue;
    wire       vid_hsync;
    wire       vid_vsync;
    wire       vid_de;

    video_generator u_video (
        .clk_pixel(clk_pixel),
        .reset(sys_reset),
        .flash_clk(flash_clk),
        .text_mode(text_mode),
        .mixed_mode(mixed_mode),
        .page2(page2),
        .hires_mode(hires_mode),
        .vram_addr(vram_addr),
        .vram_data(vram_data),
        .char_rom_addr(char_rom_addr),
        .char_rom_data(char_rom_data),
        .red(vid_red),
        .green(vid_green),
        .blue(vid_blue),
        .hsync(vid_hsync),
        .vsync(vid_vsync),
        .de(vid_de),
        .vbl(vbl)
    );

    // HDMI / DVI Transmitter
    hdmi_tx u_hdmi (
        .clk_pixel(clk_pixel),
        .clk_tmds(clk_tmds),
        .reset(sys_reset),
        .red(vid_red),
        .green(vid_green),
        .blue(vid_blue),
        .hsync(vid_hsync),
        .vsync(vid_vsync),
        .de(vid_de),
        .tmds_clk_p(tmds_clk_p),
        .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p),
        .tmds_d_n(tmds_d_n)
    );

    // Sound Generator (MAX98357A I2S Class-D Amplifier)
    wire spkr_direct;
    sound_generator u_sound (
        .clk(clk_pixel),
        .reset(sys_reset),
        .spkr_pulse(spkr_pulse),
        .i2s_bclk(i2s_bclk),
        .i2s_lrck(i2s_lrck),
        .i2s_din(i2s_din),
        .pa_en(pa_en),
        .spkr_out(spkr_direct)
    );

    // Diagnostic LEDs (active-low)
    // LED 0: Heartbeat blinker (~1.6 Hz)
    // LED 1: PLL Locked (ON when locked)
    // LED 2: Reset status (ON when running)
    // LED 3: CPU Memory Write Activity
    // LED 4: Video mode (ON = Text, OFF = Graphics)
    // LED 5: Keyboard strobe active
    reg [23:0] heartbeat = 24'd0;
    always @(posedge clk_pixel) heartbeat <= heartbeat + 1'b1;

    assign led[0] = ~heartbeat[23];
    assign led[1] = ~pll_locked;
    assign led[2] = sys_reset;
    assign led[3] = ~debug_cpu_we;
    assign led[4] = ~text_mode;
    assign led[5] = ~key_strobe;

endmodule
