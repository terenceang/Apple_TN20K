// Apple //e Dual-Mode Serial Console & Hardware Debugger for Tang Nano 20K
// Operates over 115200 baud UART (Pin 69 TX, Pin 70 RX)
//
// Modes:
// 1. Console Mode (Default):
//    - Mirrors all Apple //e screen/Monitor text output (COUT / $FDED) to UART TX.
//    - Direct Apple II software UART output via writes to $C088 (Slot 1) or $C098 (Slot 2).
//    - Pass-through keyboard input to Apple //e.
//
// Debugger commands (Ctrl+B enters, Ctrl+B or 'c' leaves):
//   r  registers, s  step one instruction, c/g  continue, m  16 bytes of memory
//   t  video and PLL status, w  dump the visible text page and, in mixed
//      mode, the graphics page behind the bottom four lines
//   h/?  help, x  CPU reset, CR  repeat the prompt
//   0 1 4 8 f v  set the memory dump address ($0000 $0100 $0400 $0800
//      $FA60 $FFF0) before m
// 2. Hardware Debugger Mode (Toggle with Ctrl+B / ASCII 0x02):
//    - Freezes 65C02 CPU execution (RDY = 0).
//    - Commands:
//        r - Display CPU registers (PC, A, X, Y, SP, Flags, Opcode)
//        s - Single-step 1 instruction
//        c - Continue / Resume Apple //e execution
//        m - Dump 16 bytes of memory (RAM/ROM) in hex & ASCII
//        t - Display hardware status (Softswitches, Video, Audio, Clocks)
//        h - Help menu

module serial_debugger (
    input  wire        clk,            // 27.0 MHz
    input  wire        reset,          // Active-high reset
    input  wire        ce_1m,          // 1.023 MHz clock enable

    // Physical UART TX Pin (Pin 69)
    output wire        uart_tx,

    // UART RX from input_controller
    input  wire [7:0]  rx_byte,
    input  wire        rx_valid,

    // Debug Mode Status (1: Debugger active, 0: Apple //e Console active)
    output reg         dbg_mode,

    // CPU Ready / Pause Control
    output reg         cpu_rdy,
    output reg         cpu_reset_req,

    // Memory Inspection Bus
    output reg  [15:0] dbg_mem_addr,
    input  wire [7:0]  dbg_mem_din,

    // 65C02 CPU Registers & Bus Snooping
    input  wire [15:0] cpu_pc,
    input  wire [7:0]  cpu_a,
    input  wire [7:0]  cpu_x,
    input  wire [7:0]  cpu_y,
    input  wire [7:0]  cpu_s,
    input  wire [7:0]  cpu_p,
    input  wire [7:0]  cpu_ir,
    input  wire [15:0] cpu_addr,
    input  wire [7:0]  cpu_dout,
    input  wire        cpu_we,
    input  wire        cpu_sync,

    // Hardware Status Inputs
    // Softswitch state, for the W (screen dump) command
    input  wire        text_mode,
    input  wire        mixed_mode,
    input  wire        page2,
    input  wire        hires_mode,
    input  wire        pll_locked
);

    // =========================================================================
    // 1. UART TX Engine with 256-Byte Circular FIFO
    // =========================================================================
    localparam [8:0] CLKS_PER_BIT = 9'd234; // 27 MHz / 115200 baud

    reg [7:0] tx_fifo [0:63];
    reg [5:0] tx_wr_ptr = 6'd0;
    reg [5:0] tx_rd_ptr = 6'd0;
    wire [5:0] fifo_used     = tx_wr_ptr - tx_rd_ptr;
    wire       tx_fifo_empty = (fifo_used == 6'd0);
    wire       tx_fifo_full  = (fifo_used >= 6'd60);

    reg [8:0] tx_clk_cnt = 9'd0;
    reg [3:0] tx_bit_idx = 4'd0;
    reg [9:0] tx_shift   = 10'h3FF;
    reg       tx_busy    = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            tx_clk_cnt <= 9'd0;
            tx_bit_idx <= 4'd0;
            tx_shift   <= 10'h3FF;
            tx_busy    <= 1'b0;
            tx_rd_ptr  <= 6'd0;
        end else begin
            if (tx_busy) begin
                if (tx_clk_cnt == CLKS_PER_BIT - 1) begin
                    tx_clk_cnt <= 9'd0;
                    tx_shift   <= {1'b1, tx_shift[9:1]};
                    if (tx_bit_idx == 4'd9) begin
                        tx_busy <= 1'b0;
                    end else begin
                        tx_bit_idx <= tx_bit_idx + 1'b1;
                    end
                end else begin
                    tx_clk_cnt <= tx_clk_cnt + 1'b1;
                end
            end else if (!tx_fifo_empty) begin
                tx_shift   <= {1'b1, tx_fifo[tx_rd_ptr], 1'b0};
                tx_rd_ptr  <= tx_rd_ptr + 1'b1;
                tx_clk_cnt <= 9'd0;
                tx_bit_idx <= 4'd0;
                tx_busy    <= 1'b1;
            end
        end
    end

    assign uart_tx = tx_shift[0];

    // Helper function: 4-bit nibble to ASCII hex character
    function [7:0] to_hex(input [3:0] n);
        to_hex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n - 4'd10});
    endfunction

    // Single write port to tx_fifo to prevent multiplexer explosion
    reg [7:0] fifo_push_byte = 8'd0;
    reg       fifo_push_en   = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            tx_wr_ptr <= 6'd0;
        end else if (fifo_push_en) begin
            tx_fifo[tx_wr_ptr] <= fifo_push_byte;
            tx_wr_ptr <= tx_wr_ptr + 1'b1;
        end
    end

    task fifo_push(input [7:0] data);
        begin
            fifo_push_en   <= 1'b1;
            fifo_push_byte <= data;
        end
    endtask

    // =========================================================================
    // 3. Apple //e COUT ($FDED) and Slot Serial ($C088/$C098) Interceptor
    // =========================================================================
    reg cout_prev_sync = 1'b0;
    wire cout_hit = ce_1m && cpu_sync && !cout_prev_sync && (cpu_addr == 16'hFDED);

    always @(posedge clk or posedge reset) begin
        if (reset)
            cout_prev_sync <= 1'b0;
        else if (ce_1m)
            cout_prev_sync <= cpu_sync;
    end

    reg [7:0] cout_char_buf = 8'd0;
    reg       cout_pending  = 1'b0;
    reg       cout_need_lf  = 1'b0;

    // Slot 1/2 Serial data write ($C088 or $C098)
    wire slot_tx_hit = ce_1m && cpu_we && (cpu_addr == 16'hC088 || cpu_addr == 16'hC098);
    reg [7:0] slot_tx_buf  = 8'd0;
    reg       slot_tx_pend = 1'b0;

    // =========================================================================
    // 4. Static String Table ROM (178 Bytes)
    // =========================================================================
    localparam STR_BANNER_START = 8'd0;
    localparam STR_BANNER_LEN   = 8'd45;
    localparam STR_RESUME_START = 8'd45;
    localparam STR_RESUME_LEN   = 8'd17;
    localparam STR_HELP_START = 8'd62;
    localparam STR_HELP_LEN   = 8'd58;
    localparam STR_PROMPT_START = 8'd119;
    localparam STR_PROMPT_LEN   = 8'd4;
    localparam STR_PC_LBL_START = 8'd124;
    localparam STR_PC_LBL_LEN   = 8'd6;
    localparam STR_A_LBL_START  = 8'd130;
    localparam STR_A_LBL_LEN    = 8'd4;
    localparam STR_X_LBL_START  = 8'd134;
    localparam STR_X_LBL_LEN    = 8'd4;
    localparam STR_Y_LBL_START  = 8'd138;
    localparam STR_Y_LBL_LEN    = 8'd4;
    localparam STR_S_LBL_START  = 8'd142;
    localparam STR_S_LBL_LEN    = 8'd5;
    localparam STR_P_LBL_START  = 8'd147;
    localparam STR_P_LBL_LEN    = 8'd4;
    localparam STR_OP_LBL_START = 8'd151;
    localparam STR_OP_LBL_LEN   = 8'd6;
    localparam STR_BAR_SP_START = 8'd157;
    localparam STR_BAR_SP_LEN   = 8'd2;
    localparam STR_CRLF_START   = 8'd159;
    localparam STR_CRLF_LEN     = 8'd2;
    localparam STR_SCR_START    = 8'd161;
    localparam STR_SCR_LEN      = 8'd5;
    localparam STR_GFX_START    = 8'd166;
    localparam STR_GFX_LEN      = 8'd5;
    localparam STR_END_START    = 8'd171;
    localparam STR_END_LEN      = 8'd7;

    reg [7:0] str_rom [0:177];
    initial begin
        str_rom[0] = 8'h0D; str_rom[1] = 8'h0A; str_rom[2] = 8'h5B; str_rom[3] = 8'h20;
        str_rom[4] = 8'h41; str_rom[5] = 8'h70; str_rom[6] = 8'h70; str_rom[7] = 8'h6C;
        str_rom[8] = 8'h65; str_rom[9] = 8'h20; str_rom[10] = 8'h2F; str_rom[11] = 8'h2F;
        str_rom[12] = 8'h65; str_rom[13] = 8'h20; str_rom[14] = 8'h44; str_rom[15] = 8'h65;
        str_rom[16] = 8'h62; str_rom[17] = 8'h75; str_rom[18] = 8'h67; str_rom[19] = 8'h67;
        str_rom[20] = 8'h65; str_rom[21] = 8'h72; str_rom[22] = 8'h20; str_rom[23] = 8'h5D;
        str_rom[24] = 8'h20; str_rom[25] = 8'h28; str_rom[26] = 8'h68; str_rom[27] = 8'h3D;
        str_rom[28] = 8'h48; str_rom[29] = 8'h65; str_rom[30] = 8'h6C; str_rom[31] = 8'h70;
        str_rom[32] = 8'h2C; str_rom[33] = 8'h20; str_rom[34] = 8'h63; str_rom[35] = 8'h3D;
        str_rom[36] = 8'h43; str_rom[37] = 8'h6F; str_rom[38] = 8'h6E; str_rom[39] = 8'h74;
        str_rom[40] = 8'h29; str_rom[41] = 8'h0D; str_rom[42] = 8'h0A; str_rom[43] = 8'h3E;
        str_rom[44] = 8'h20; str_rom[45] = 8'h0D; str_rom[46] = 8'h0A; str_rom[47] = 8'h5B;
        str_rom[48] = 8'h52; str_rom[49] = 8'h65; str_rom[50] = 8'h73; str_rom[51] = 8'h75;
        str_rom[52] = 8'h6D; str_rom[53] = 8'h69; str_rom[54] = 8'h6E; str_rom[55] = 8'h67;
        str_rom[56] = 8'h2E; str_rom[57] = 8'h2E; str_rom[58] = 8'h2E; str_rom[59] = 8'h5D;
        str_rom[60] = 8'h0D; str_rom[61] = 8'h0A;
        // Help: "\r\nCmds: r=Regs s=Step c=Cont m=Mem t=Stat w=Scr h=Help\r\n> "
        str_rom[62] = 8'h0D; str_rom[63] = 8'h0A; str_rom[64] = 8'h43; str_rom[65] = 8'h6D;
        str_rom[66] = 8'h64; str_rom[67] = 8'h73; str_rom[68] = 8'h3A; str_rom[69] = 8'h20;
        str_rom[70] = 8'h72; str_rom[71] = 8'h3D; str_rom[72] = 8'h52; str_rom[73] = 8'h65;
        str_rom[74] = 8'h67; str_rom[75] = 8'h73; str_rom[76] = 8'h20; str_rom[77] = 8'h73;
        str_rom[78] = 8'h3D; str_rom[79] = 8'h53; str_rom[80] = 8'h74; str_rom[81] = 8'h65;
        str_rom[82] = 8'h70; str_rom[83] = 8'h20; str_rom[84] = 8'h63; str_rom[85] = 8'h3D;
        str_rom[86] = 8'h43; str_rom[87] = 8'h6F; str_rom[88] = 8'h6E; str_rom[89] = 8'h74;
        str_rom[90] = 8'h20; str_rom[91] = 8'h6D; str_rom[92] = 8'h3D; str_rom[93] = 8'h4D;
        str_rom[94] = 8'h65; str_rom[95] = 8'h6D; str_rom[96] = 8'h20; str_rom[97] = 8'h74;
        str_rom[98] = 8'h3D; str_rom[99] = 8'h53; str_rom[100] = 8'h74; str_rom[101] = 8'h61;
        str_rom[102] = 8'h74; str_rom[103] = 8'h20; str_rom[104] = 8'h77; str_rom[105] = 8'h3D;
        str_rom[106] = 8'h53; str_rom[107] = 8'h63; str_rom[108] = 8'h72; str_rom[109] = 8'h20;
        str_rom[110] = 8'h68; str_rom[111] = 8'h3D; str_rom[112] = 8'h48; str_rom[113] = 8'h65;
        str_rom[114] = 8'h6C; str_rom[115] = 8'h70; str_rom[116] = 8'h0D; str_rom[117] = 8'h0A;
        str_rom[118] = 8'h3E; str_rom[119] = 8'h20;
        // Prompt "\r\n> "
        str_rom[120] = 8'h0D; str_rom[121] = 8'h0A; str_rom[122] = 8'h3E; str_rom[123] = 8'h20;
        // Register line labels
        str_rom[124] = 8'h0D; str_rom[125] = 8'h0A; str_rom[126] = 8'h50; str_rom[127] = 8'h43;
        str_rom[128] = 8'h3A; str_rom[129] = 8'h24; str_rom[130] = 8'h20; str_rom[131] = 8'h41;
        str_rom[132] = 8'h3A; str_rom[133] = 8'h24; str_rom[134] = 8'h20; str_rom[135] = 8'h58;
        str_rom[136] = 8'h3A; str_rom[137] = 8'h24; str_rom[138] = 8'h20; str_rom[139] = 8'h59;
        str_rom[140] = 8'h3A; str_rom[141] = 8'h24; str_rom[142] = 8'h20; str_rom[143] = 8'h53;
        str_rom[144] = 8'h50; str_rom[145] = 8'h3A; str_rom[146] = 8'h24; str_rom[147] = 8'h20;
        str_rom[148] = 8'h50; str_rom[149] = 8'h3A; str_rom[150] = 8'h5B; str_rom[151] = 8'h5D;
        str_rom[152] = 8'h20; str_rom[153] = 8'h4F; str_rom[154] = 8'h50; str_rom[155] = 8'h3A;
        str_rom[156] = 8'h24; str_rom[157] = 8'h20; str_rom[158] = 8'h7C; str_rom[159] = 8'h0D;
        str_rom[160] = 8'h0A;
        // Screen dump framing: "\r\n$SS", "\r\n$GF", "\r\n$SEND"
        str_rom[161] = 8'h0D; str_rom[162] = 8'h0A; str_rom[163] = 8'h24; str_rom[164] = 8'h53;
        str_rom[165] = 8'h53; str_rom[166] = 8'h0D; str_rom[167] = 8'h0A; str_rom[168] = 8'h24;
        str_rom[169] = 8'h47; str_rom[170] = 8'h46; str_rom[171] = 8'h0D; str_rom[172] = 8'h0A;
        str_rom[173] = 8'h24; str_rom[174] = 8'h53; str_rom[175] = 8'h45; str_rom[176] = 8'h4E;
        str_rom[177] = 8'h44;
    end

    // String printer sub-engine
    reg [7:0] str_pos = 8'd0;
    reg [7:0] str_cnt = 8'd0;
    wire str_busy = (str_cnt != 8'd0);

    // Hex digit printer sub-engine (prints up to 4 hex digits)
    reg [15:0] hex_val = 16'd0;
    reg [2:0]  hex_digits = 3'd0;
    wire hex_busy = (hex_digits != 3'd0);

    // Which received bytes the console echo passes through. Anything else is
    // protocol: the 0xFE key packet and the 0xFF gamepad packet must not be
    // reflected into the terminal as text.
    wire echoable = (rx_byte >= 8'h20 && rx_byte <= 8'h7E) ||
                    (rx_byte == 8'h0D) || (rx_byte == 8'h0A) ||
                    (rx_byte == 8'h08) || (rx_byte == 8'h07);

    // =========================================================================
    // 5. Hardware Debugger State Machine & Micro-Sequencer
    // =========================================================================
    localparam M_IDLE    = 4'd0;
    localparam M_STR     = 4'd1;
    localparam M_HEX     = 4'd2;
    localparam M_REGS    = 4'd3;
    localparam M_MEM     = 4'd4;
    localparam M_STATUS  = 4'd5;
    localparam M_SCREEN  = 4'd6;

    // Screen dump state. The W command streams the text page the video
    // generator is showing, plus the graphics page the bottom four lines use
    // in mixed mode, so a host can redraw the screen exactly. Only reachable
    // while the CPU is paused, which is what makes the read race-free: nothing
    // can rewrite $0400 while dbg_mode is set.
    reg [15:0] scr_addr  = 16'h0400;
    reg [10:0] scr_left  = 11'd0;   // bytes still to print
    reg [5:0]  scr_col   = 6'd0;    // 0..39 text columns, 0..31 graphics
    reg [2:0]  scr_wait  = 3'd0;    // settle cycles between RAM reads
    reg [7:0]  scr_flags = 8'h00;

    reg [3:0] main_state = M_IDLE;
    reg [3:0] return_job = M_IDLE;
    reg [4:0] seq_step   = 5'd0;

    reg [15:0] latched_pc;
    reg [7:0]  latched_a;
    reg [7:0]  latched_x;
    reg [7:0]  latched_y;
    reg [7:0]  latched_s;
    reg [7:0]  latched_p;
    reg [7:0]  latched_ir;

    reg [15:0] dump_addr = 16'hFA60;
    reg [7:0]  mem_row [0:15];
    reg [3:0]  mem_col = 4'd0;
    reg [2:0]  mem_wait = 3'd0;
    reg [7:0]  reset_timer = 8'd0;

    // Single Step State Machine
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_WAIT0 = 2'd2;
    localparam S_WAIT1 = 2'd3;

    reg [1:0] step_fsm = S_IDLE;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            step_fsm       <= S_IDLE;
            cpu_rdy        <= 1'b1;
            cpu_reset_req  <= 1'b0;
            reset_timer    <= 8'd0;
            dbg_mode       <= 1'b0;
            latched_pc     <= 16'hFA62;
            latched_a      <= 8'h00;
            latched_x      <= 8'h00;
            latched_y      <= 8'h00;
            latched_s      <= 8'hFF;
            latched_p      <= 8'h20;
            latched_ir     <= 8'h00;
            dump_addr      <= 16'hFA60;
            dbg_mem_addr   <= 16'hFA60;
            main_state     <= M_IDLE;
            return_job     <= M_IDLE;
            seq_step       <= 5'd0;
            str_pos        <= 8'd0;
            str_cnt        <= 8'd0;
            cout_char_buf  <= 8'd0;
            cout_pending   <= 1'b0;
            cout_need_lf   <= 1'b0;
            slot_tx_buf    <= 8'd0;
            slot_tx_pend   <= 1'b0;
            mem_col        <= 4'd0;
            mem_wait       <= 3'd0;
            scr_addr       <= 16'h0400;
            scr_left       <= 11'd0;
            scr_col        <= 6'd0;
            scr_wait       <= 3'd0;
            scr_flags      <= 8'h00;
        end else begin
            fifo_push_en <= 1'b0;

            // Debugger CPU Reset Sequencer
            if (reset_timer != 8'd0) begin
                reset_timer   <= reset_timer - 1'b1;
                cpu_reset_req <= 1'b1;
                cpu_rdy       <= 1'b0;
                step_fsm      <= S_IDLE;
                if (reset_timer == 8'd1) begin
                    latched_pc <= 16'hFA62;
                    dump_addr  <= 16'hFA60;
                    main_state <= M_REGS;
                    seq_step   <= 5'd0;
                end
            end else begin
                cpu_reset_req <= 1'b0;
            end

            // Latch Apple II COUT and Slot TX events
            if (cout_hit && !dbg_mode) begin
                cout_char_buf <= cpu_a;
                cout_pending  <= 1'b1;
            end
            if (slot_tx_hit && !dbg_mode) begin
                slot_tx_buf  <= cpu_dout;
                slot_tx_pend <= 1'b1;
            end

            // Single Step FSM
            case (step_fsm)
                S_IDLE: begin
                    if (!dbg_mode)
                        cpu_rdy <= 1'b1;
                    else
                        cpu_rdy <= 1'b0;
                end

                S_START: begin
                    cpu_rdy <= 1'b1;
                    if (ce_1m)
                        step_fsm <= S_WAIT0;
                end

                S_WAIT0: begin
                    if (ce_1m && !cpu_sync)
                        step_fsm <= S_WAIT1;
                end

                S_WAIT1: begin
                    if (ce_1m && cpu_sync) begin
                        cpu_rdy    <= 1'b0;
                        step_fsm   <= S_IDLE;
                        latched_pc <= cpu_pc;
                        latched_a  <= cpu_a;
                        latched_x  <= cpu_x;
                        latched_y  <= cpu_y;
                        latched_s  <= cpu_s;
                        latched_p  <= cpu_p;
                        latched_ir <= cpu_ir;
                        // Trigger Register print
                        main_state <= M_REGS;
                        seq_step   <= 5'd0;
                    end
                end
            endcase

            // Mode switching via Ctrl+B (ASCII 0x02)
            if (rx_valid && (rx_byte == 8'h02)) begin
                if (!dbg_mode) begin
                    dbg_mode   <= 1'b1;
                    cpu_rdy    <= 1'b0;
                    latched_pc <= cpu_pc;
                    latched_a  <= cpu_a;
                    latched_x  <= cpu_x;
                    latched_y  <= cpu_y;
                    latched_s  <= cpu_s;
                    latched_p  <= cpu_p;
                    latched_ir <= cpu_ir;
                    dump_addr  <= cpu_pc;
                    // Print Banner
                    str_pos    <= STR_BANNER_START;
                    str_cnt    <= STR_BANNER_LEN;
                    return_job <= M_REGS;
                    seq_step   <= 5'd0;
                    main_state <= M_STR;
                end else begin
                    dbg_mode   <= 1'b0;
                    cpu_rdy    <= 1'b1;
                    // Print Resume
                    str_pos    <= STR_RESUME_START;
                    str_cnt    <= STR_RESUME_LEN;
                    return_job <= M_IDLE;
                    main_state <= M_STR;
                end
            end else if (!dbg_mode && (main_state == M_IDLE) && rx_valid) begin
                // Echo console keystrokes back so the host sees what it typed.
                // Only characters a terminal can show: the 0xFE key packet and
                // the 0xFF gamepad packet are protocol, not text, and used to
                // land in the console as five or three junk bytes each.
                if (!tx_fifo_full && echoable) begin
                    fifo_push(rx_byte);
                end
            end else if (dbg_mode && (main_state == M_IDLE) && rx_valid) begin
                case (rx_byte)
                    "r", "R": begin
                        latched_pc <= cpu_pc;
                        latched_a  <= cpu_a;
                        latched_x  <= cpu_x;
                        latched_y  <= cpu_y;
                        latched_s  <= cpu_s;
                        latched_p  <= cpu_p;
                        latched_ir <= cpu_ir;
                        main_state <= M_REGS;
                        seq_step   <= 5'd0;
                    end

                    "s", "S": begin
                        step_fsm <= S_START;
                    end

                    "c", "C", "g", "G": begin
                        dbg_mode   <= 1'b0;
                        cpu_rdy    <= 1'b1;
                        str_pos    <= STR_RESUME_START;
                        str_cnt    <= STR_RESUME_LEN;
                        return_job <= M_IDLE;
                        main_state <= M_STR;
                    end

                    "m", "M": begin
                        main_state <= M_MEM;
                        seq_step   <= 5'd0;
                        mem_col    <= 4'd0;
                        mem_wait   <= 3'd0;
                    end

                    "x", "X": begin
                        reset_timer <= 8'd255;
                        dbg_mode    <= 1'b1;
                        cpu_rdy     <= 1'b0;
                    end

                    "0": begin dump_addr <= 16'h0000; main_state <= M_MEM; seq_step <= 5'd0; mem_col <= 4'd0; mem_wait <= 3'd0; end
                    "1": begin dump_addr <= 16'h0100; main_state <= M_MEM; seq_step <= 5'd0; mem_col <= 4'd0; mem_wait <= 3'd0; end
                    "4": begin dump_addr <= 16'h0400; main_state <= M_MEM; seq_step <= 5'd0; mem_col <= 4'd0; mem_wait <= 3'd0; end
                    "8": begin dump_addr <= 16'h0800; main_state <= M_MEM; seq_step <= 5'd0; mem_col <= 4'd0; mem_wait <= 3'd0; end
                    "f", "F": begin dump_addr <= 16'hFA60; main_state <= M_MEM; seq_step <= 5'd0; mem_col <= 4'd0; mem_wait <= 3'd0; end
                    "v", "V": begin dump_addr <= 16'hFFF0; main_state <= M_MEM; seq_step <= 5'd0; mem_col <= 4'd0; mem_wait <= 3'd0; end

                    "t", "T": begin
                        main_state <= M_STATUS;
                        seq_step   <= 5'd0;
                    end

                    "w", "W": begin
                        main_state <= M_SCREEN;
                        seq_step   <= 5'd0;
                    end

                    "h", "H", "?": begin
                        str_pos    <= STR_HELP_START;
                        str_cnt    <= STR_HELP_LEN;
                        return_job <= M_IDLE;
                        main_state <= M_STR;
                    end

                    8'h0D, 8'h0A: begin
                        str_pos    <= STR_PROMPT_START;
                        str_cnt    <= STR_PROMPT_LEN;
                        return_job <= M_IDLE;
                        main_state <= M_STR;
                    end

                    default: ;
                endcase
            end

            // Main State Machine
            case (main_state)
                M_IDLE: begin
                    // Idle: wait for commands or console activity
                end

                // -------------------------------------------------------------
                // String Sub-engine: Streams bytes from str_rom into FIFO
                // -------------------------------------------------------------
                M_STR: begin
                    if (!tx_fifo_full) begin
                        fifo_push(str_rom[str_pos]);
                        str_pos <= str_pos + 1'b1;
                        if (str_cnt == 8'd1) begin
                            str_cnt    <= 8'd0;
                            main_state <= return_job;
                        end else begin
                            str_cnt <= str_cnt - 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Hex Sub-engine: Streams hex digits into FIFO
                // -------------------------------------------------------------
                M_HEX: begin
                    if (!tx_fifo_full) begin
                        fifo_push(to_hex(hex_val[15:12]));
                        hex_val <= {hex_val[11:0], 4'h0};
                        if (hex_digits == 3'd1) begin
                            hex_digits <= 3'd0;
                            main_state <= return_job;
                        end else begin
                            hex_digits <= hex_digits - 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Register Display Sequencer
                // -------------------------------------------------------------
                M_REGS: begin
                    case (seq_step)
                        5'd0: begin // "PC:$"
                            str_pos    <= STR_PC_LBL_START;
                            str_cnt    <= STR_PC_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd1;
                            main_state <= M_STR;
                        end
                        5'd1: begin // 4-digit PC
                            hex_val    <= latched_pc;
                            hex_digits <= 3'd4;
                            return_job <= M_REGS;
                            seq_step   <= 5'd2;
                            main_state <= M_HEX;
                        end
                        5'd2: begin // " A:$"
                            str_pos    <= STR_A_LBL_START;
                            str_cnt    <= STR_A_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd3;
                            main_state <= M_STR;
                        end
                        5'd3: begin // 2-digit A
                            hex_val    <= {latched_a, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_REGS;
                            seq_step   <= 5'd4;
                            main_state <= M_HEX;
                        end
                        5'd4: begin // " X:$"
                            str_pos    <= STR_X_LBL_START;
                            str_cnt    <= STR_X_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd5;
                            main_state <= M_STR;
                        end
                        5'd5: begin // 2-digit X
                            hex_val    <= {latched_x, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_REGS;
                            seq_step   <= 5'd6;
                            main_state <= M_HEX;
                        end
                        5'd6: begin // " Y:$"
                            str_pos    <= STR_Y_LBL_START;
                            str_cnt    <= STR_Y_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd7;
                            main_state <= M_STR;
                        end
                        5'd7: begin // 2-digit Y
                            hex_val    <= {latched_y, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_REGS;
                            seq_step   <= 5'd8;
                            main_state <= M_HEX;
                        end
                        5'd8: begin // " SP:$"
                            str_pos    <= STR_S_LBL_START;
                            str_cnt    <= STR_S_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd9;
                            main_state <= M_STR;
                        end
                        5'd9: begin // 2-digit S
                            hex_val    <= {latched_s, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_REGS;
                            seq_step   <= 5'd10;
                            main_state <= M_HEX;
                        end
                        5'd10: begin // " P:["
                            str_pos    <= STR_P_LBL_START;
                            str_cnt    <= STR_P_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd11;
                            main_state <= M_STR;
                        end
                        5'd11: begin // Flags: N V - B D I Z C
                            if (!tx_fifo_full) begin
                                fifo_push(latched_p[7] ? "N" : "-");
                                seq_step <= 5'd12;
                            end
                        end
                        5'd12: if (!tx_fifo_full) begin fifo_push(latched_p[6] ? "V" : "-"); seq_step <= 5'd13; end
                        5'd13: if (!tx_fifo_full) begin fifo_push("-");                     seq_step <= 5'd14; end
                        5'd14: if (!tx_fifo_full) begin fifo_push(latched_p[4] ? "B" : "-"); seq_step <= 5'd15; end
                        5'd15: if (!tx_fifo_full) begin fifo_push(latched_p[3] ? "D" : "-"); seq_step <= 5'd16; end
                        5'd16: if (!tx_fifo_full) begin fifo_push(latched_p[2] ? "I" : "-"); seq_step <= 5'd17; end
                        5'd17: if (!tx_fifo_full) begin fifo_push(latched_p[1] ? "Z" : "-"); seq_step <= 5'd18; end
                        5'd18: if (!tx_fifo_full) begin fifo_push(latched_p[0] ? "C" : "-"); seq_step <= 5'd19; end
                        5'd19: begin // "] OP:$"
                            str_pos    <= STR_OP_LBL_START;
                            str_cnt    <= STR_OP_LBL_LEN;
                            return_job <= M_REGS;
                            seq_step   <= 5'd20;
                            main_state <= M_STR;
                        end
                        5'd20: begin // 2-digit Opcode
                            hex_val    <= {latched_ir, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_REGS;
                            seq_step   <= 5'd21;
                            main_state <= M_HEX;
                        end
                        5'd21: begin // Prompt "\r\n> "
                            str_pos    <= STR_PROMPT_START;
                            str_cnt    <= STR_PROMPT_LEN;
                            return_job <= M_IDLE;
                            main_state <= M_STR;
                        end
                        default: main_state <= M_IDLE;
                    endcase
                end

                // -------------------------------------------------------------
                // Memory Dump Sequencer (16 Bytes)
                // -------------------------------------------------------------
                M_MEM: begin
                    case (seq_step)
                        5'd0: begin // CRLF
                            str_pos    <= STR_CRLF_START;
                            str_cnt    <= STR_CRLF_LEN;
                            return_job <= M_MEM;
                            seq_step   <= 5'd1;
                            main_state <= M_STR;
                        end
                        5'd1: if (!tx_fifo_full) begin fifo_push("$"); seq_step <= 5'd2; end
                        5'd2: begin // Dump address (4 hex digits)
                            hex_val    <= dump_addr;
                            hex_digits <= 3'd4;
                            return_job <= M_MEM;
                            seq_step   <= 5'd3;
                            main_state <= M_HEX;
                        end
                        5'd3: if (!tx_fifo_full) begin fifo_push(":"); seq_step <= 5'd4; end
                        5'd4: if (!tx_fifo_full) begin
                            fifo_push(" ");
                            mem_col  <= 4'd0;
                            mem_wait <= 3'd0;
                            seq_step <= 5'd5;
                        end
                        5'd5: begin // Read 16 bytes into mem_row
                            dbg_mem_addr <= dump_addr + {12'd0, mem_col};
                            if (mem_wait < 3'd4) begin
                                mem_wait <= mem_wait + 1'b1;
                            end else begin
                                mem_row[mem_col] <= dbg_mem_din;
                                mem_wait <= 3'd0;
                                if (mem_col == 4'd15) begin
                                    mem_col  <= 4'd0;
                                    seq_step <= 5'd6;
                                end else begin
                                    mem_col <= mem_col + 1'b1;
                                end
                            end
                        end
                        5'd6: begin // Print Hex Byte MSB
                            if (!tx_fifo_full) begin
                                fifo_push(to_hex(mem_row[mem_col][7:4]));
                                seq_step <= 5'd7;
                            end
                        end
                        5'd7: begin // Print Hex Byte LSB
                            if (!tx_fifo_full) begin
                                fifo_push(to_hex(mem_row[mem_col][3:0]));
                                seq_step <= 5'd8;
                            end
                        end
                        5'd8: begin // Print space (extra space between bytes 7 and 8)
                            if (!tx_fifo_full) begin
                                fifo_push(" ");
                                if (mem_col == 4'd7)
                                    seq_step <= 5'd9;
                                else if (mem_col == 4'd15) begin
                                    mem_col  <= 4'd0;
                                    seq_step <= 5'd10;
                                end else begin
                                    mem_col  <= mem_col + 1'b1;
                                    seq_step <= 5'd6;
                                end
                            end
                        end
                        5'd9: if (!tx_fifo_full) begin // Extra space
                            fifo_push(" ");
                            mem_col  <= mem_col + 1'b1;
                            seq_step <= 5'd6;
                        end
                        5'd10: begin // " |"
                            str_pos    <= STR_BAR_SP_START;
                            str_cnt    <= STR_BAR_SP_LEN;
                            return_job <= M_MEM;
                            seq_step   <= 5'd11;
                            main_state <= M_STR;
                        end
                        5'd11: begin // Print 16 ASCII characters
                            if (!tx_fifo_full) begin
                                fifo_push((mem_row[mem_col] >= 8'h20 && mem_row[mem_col] <= 8'h7E) ? mem_row[mem_col] : 8'h2E);
                                if (mem_col == 4'd15)
                                    seq_step <= 5'd12;
                                else
                                    mem_col  <= mem_col + 1'b1;
                            end
                        end
                        5'd12: if (!tx_fifo_full) begin fifo_push("|"); seq_step <= 5'd13; end
                        5'd13: begin // Prompt "\r\n> "
                            dump_addr  <= dump_addr + 16'd16;
                            str_pos    <= STR_PROMPT_START;
                            str_cnt    <= STR_PROMPT_LEN;
                            return_job <= M_IDLE;
                            main_state <= M_STR;
                        end
                        default: main_state <= M_IDLE;
                    endcase
                end

                // -------------------------------------------------------------
                // Status Display Sequencer
                // -------------------------------------------------------------
                M_STATUS: begin
                    case (seq_step)
                        5'd0: begin
                            str_pos    <= STR_CRLF_START;
                            str_cnt    <= STR_CRLF_LEN;
                            return_job <= M_STATUS;
                            seq_step   <= 5'd1;
                            main_state <= M_STR;
                        end
                        5'd1:  if (!tx_fifo_full) begin fifo_push("V"); seq_step <= 5'd2;  end
                        5'd2:  if (!tx_fifo_full) begin fifo_push("I"); seq_step <= 5'd3;  end
                        5'd3:  if (!tx_fifo_full) begin fifo_push("D"); seq_step <= 5'd4;  end
                        5'd4:  if (!tx_fifo_full) begin fifo_push(":"); seq_step <= 5'd5;  end
                        5'd5:  if (!tx_fifo_full) begin fifo_push(text_mode ? "T" : "G"); seq_step <= 5'd6; end
                        5'd6:  if (!tx_fifo_full) begin fifo_push(" "); seq_step <= 5'd7;  end
                        5'd7:  if (!tx_fifo_full) begin fifo_push("P"); seq_step <= 5'd8;  end
                        5'd8:  if (!tx_fifo_full) begin fifo_push("L"); seq_step <= 5'd9;  end
                        5'd9:  if (!tx_fifo_full) begin fifo_push("L"); seq_step <= 5'd10; end
                        5'd10: if (!tx_fifo_full) begin fifo_push(":"); seq_step <= 5'd11; end
                        5'd11: if (!tx_fifo_full) begin fifo_push(pll_locked ? "1" : "0"); seq_step <= 5'd12; end
                        5'd12: begin
                            str_pos    <= STR_PROMPT_START;
                            str_cnt    <= STR_PROMPT_LEN;
                            return_job <= M_IDLE;
                            main_state <= M_STR;
                        end
                        default: main_state <= M_IDLE;
                    endcase
                end

                // -------------------------------------------------------------
                // Screen Dump Sequencer
                //
                // Wire format, all hex text so a plain terminal can read it too:
                //
                //   $SS <flags>          one flag byte, then
                //                         <40 bytes>  x24   text page, one row each
                //   $GF <32 bytes>  x4   graphics page rows 20-23, mixed mode only
                //   $SEND
                //
                // Text rows are 40 bytes of $0400/$0800 in the same interleaved
                // order video_generator.v reads them, so the host can index
                // them directly. Bit 7 of each byte is inverse video, not part
                // of the character.
                // -------------------------------------------------------------
                M_SCREEN: begin
                    case (seq_step)
                        5'd0: begin // "\r\n$SS"
                            scr_flags <= {2'b00, pll_locked, hires_mode, mixed_mode,
                                          page2, text_mode};
                            str_pos    <= STR_SCR_START;
                            str_cnt    <= STR_SCR_LEN;
                            return_job <= M_SCREEN;
                            seq_step   <= 5'd1;
                            main_state <= M_STR;
                        end
                        5'd1: if (!tx_fifo_full) begin // flags byte
                            fifo_push(" ");
                            hex_val    <= {scr_flags, 8'h00};
                            hex_digits <= 3'd2;
                            return_job <= M_SCREEN;
                            seq_step   <= 5'd2;
                            main_state <= M_HEX;
                        end
                        5'd2: if (!tx_fifo_full) begin // start of text page
                            fifo_push(" ");
                            scr_addr <= page2 ? 16'h0800 : 16'h0400;
                            scr_left <= 11'd1024;
                            scr_col  <= 6'd0;
                            scr_wait <= 3'd0;
                            seq_step <= 5'd3;
                        end
                        5'd3: begin
                            if (scr_left == 11'd0) begin
                                seq_step <= 5'd6;
                            end else begin
                                // Same read-settle pattern as the memory dump:
                                // the RAM answer lands a few cycles after the
                                // address is presented, and dbg_mem_din is
                                // combinational off the current dbg_mem_addr.
                                dbg_mem_addr <= scr_addr;
                                if (scr_wait < 3'd4) begin
                                    scr_wait <= scr_wait + 1'b1;
                                end else begin
                                    scr_wait   <= 3'd0;
                                    scr_addr   <= scr_addr + 16'd1;
                                    scr_left   <= scr_left - 11'd1;
                                    scr_col    <= scr_col + 1'b1;
                                    hex_val    <= {dbg_mem_din, 8'h00};
                                    hex_digits <= 3'd2;
                                    return_job <= M_SCREEN;
                                    main_state <= M_HEX;
                                    seq_step   <= 5'd4;
                                end
                            end
                        end
                        5'd4: if (scr_col == 6'd40) begin // end of a text row
                            scr_col    <= 6'd0;
                            str_pos    <= STR_CRLF_START;
                            str_cnt    <= STR_CRLF_LEN;
                            return_job <= M_SCREEN;
                            main_state <= M_STR;
                        end else begin
                            seq_step <= 5'd3;
                        end
                        5'd6: if (!tx_fifo_full) begin // "\r\n$GF"
                            // In mixed mode the bottom four lines are graphics
                            // taken from the page the text is not on.
                            str_pos    <= STR_GFX_START;
                            str_cnt    <= STR_GFX_LEN;
                            return_job <= M_SCREEN;
                            main_state <= M_STR;
                            scr_addr   <= (page2 ? 16'h0400 : 16'h0800) + 16'h0500;
                            scr_left   <= 11'd128;
                            scr_col    <= 6'd0;
                            scr_wait   <= 3'd0;
                            seq_step   <= 5'd7;
                        end
                        5'd7: begin
                            if (scr_left == 11'd0) begin
                                seq_step <= 5'd9;
                            end else begin
                                dbg_mem_addr <= scr_addr;
                                if (scr_wait < 3'd4) begin
                                    scr_wait <= scr_wait + 1'b1;
                                end else begin
                                    scr_wait   <= 3'd0;
                                    scr_addr   <= scr_addr + 16'd1;
                                    scr_left   <= scr_left - 11'd1;
                                    scr_col    <= scr_col + 1'b1;
                                    hex_val    <= {dbg_mem_din, 8'h00};
                                    hex_digits <= 3'd2;
                                    return_job <= M_SCREEN;
                                    main_state <= M_HEX;
                                    seq_step   <= 5'd8;
                                end
                            end
                        end
                        5'd8: if (scr_col == 6'd32) begin
                            scr_col    <= 6'd0;
                            str_pos    <= STR_CRLF_START;
                            str_cnt    <= STR_CRLF_LEN;
                            return_job <= M_SCREEN;
                            main_state <= M_STR;
                        end else begin
                            seq_step <= 5'd7;
                        end
                        5'd9: if (!tx_fifo_full) begin // "\r\n$SEND" then prompt
                            str_pos    <= STR_END_START;
                            str_cnt    <= STR_END_LEN;
                            return_job <= M_SCREEN;
                            main_state <= M_STR;
                            seq_step   <= 5'd10;
                        end
                        5'd10: begin
                            str_pos    <= STR_PROMPT_START;
                            str_cnt    <= STR_PROMPT_LEN;
                            return_job <= M_IDLE;
                            main_state <= M_STR;
                        end
                        default: main_state <= M_IDLE;
                    endcase
                end

                default: main_state <= M_IDLE;
            endcase

            // In Console Mode: stream Apple II COUT characters directly to UART TX
            if (!dbg_mode && (main_state == M_IDLE) && !tx_fifo_full && !rx_valid) begin
                if (cout_need_lf) begin
                    fifo_push(8'h0A); // '\n'
                    cout_need_lf <= 1'b0;
                end else if (cout_pending) begin
                    cout_pending <= 1'b0;
                    if (cout_char_buf[6:0] == 7'h0D) begin
                        fifo_push(8'h0D); // '\r'
                        cout_need_lf <= 1'b1;  // Schedule '\n'
                    end else if (cout_char_buf[6:0] == 7'h08) begin
                        fifo_push(8'h08); // '\b'
                    end else if (cout_char_buf[6:0] >= 7'h20 && cout_char_buf[6:0] <= 7'h7E) begin
                        fifo_push({1'b0, cout_char_buf[6:0]});
                    end else if (cout_char_buf[6:0] == 7'h07) begin
                        fifo_push(8'h07); // Bell
                    end
                end else if (slot_tx_pend) begin
                    slot_tx_pend <= 1'b0;
                    fifo_push(slot_tx_buf);
                end
            end
        end
    end

endmodule
