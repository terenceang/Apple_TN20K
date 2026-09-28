// Apple //e Input Controller for Tang Nano 20K
// Handles UART RX (115200 baud) for Bluetooth-to-UART / USB-C keyboard & gamepad

module input_controller (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,
    input  wire        ce_1m,         // 1.023 MHz clock enable
    input  wire        uart_rx,       // Serial RX (Pin 70)

    // Debugger Interface
    input  wire        dbg_mode,      // 1: Ignore Apple II keys when in debugger
    output wire [7:0]  rx_byte,       // Received byte
    output wire        rx_valid,      // Received byte strobe

    // CPU Bus Interface
    input  wire [7:0]  io_addr,       // $C0xx offset (A[7:0])
    input  wire        io_read,       // Read strobe
    input  wire        io_write,      // Write strobe
    output reg  [7:0]  io_dout,
    output wire        io_hit,        // Address recognized

    // Diagnostic indicator
    output wire        key_strobe
);

    // 115200 baud receiver at 27 MHz:
    // 27,000,000 / 115,200 = 234.375 cycles per bit
    localparam [8:0] CLKS_PER_BIT = 9'd234;
    localparam [8:0] HALF_BIT     = 9'd117;

    // UART RX synchronizer
    reg [2:0] rx_sync;
    always @(posedge clk) rx_sync <= {rx_sync[1:0], uart_rx};
    wire rx_bit = rx_sync[2];

    // UART Receiver State Machine
    localparam URX_IDLE  = 3'd0;
    localparam URX_START = 3'd1;
    localparam URX_DATA  = 3'd2;
    localparam URX_STOP  = 3'd3;

    reg [2:0] urx_state = URX_IDLE;
    reg [8:0] urx_cnt   = 9'd0;
    reg [2:0] urx_idx   = 3'd0;
    reg [7:0] urx_byte  = 8'd0;
    reg       urx_valid = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            urx_state <= URX_IDLE;
            urx_cnt   <= 9'd0;
            urx_idx   <= 3'd0;
            urx_byte  <= 8'd0;
            urx_valid <= 1'b0;
        end else begin
            urx_valid <= 1'b0;
            case (urx_state)
                URX_IDLE: begin
                    if (!rx_bit) begin // Start bit detected
                        urx_cnt   <= 9'd0;
                        urx_state <= URX_START;
                    end
                end

                URX_START: begin
                    if (urx_cnt == HALF_BIT) begin
                        if (!rx_bit) begin // Confirm start bit
                            urx_cnt   <= 9'd0;
                            urx_idx   <= 3'd0;
                            urx_state <= URX_DATA;
                        end else begin
                            urx_state <= URX_IDLE;
                        end
                    end else begin
                        urx_cnt <= urx_cnt + 1'b1;
                    end
                end

                URX_DATA: begin
                    if (urx_cnt == CLKS_PER_BIT - 1) begin
                        urx_cnt <= 9'd0;
                        urx_byte[urx_idx] <= rx_bit;
                        if (urx_idx == 3'd7) begin
                            urx_state <= URX_STOP;
                        end else begin
                            urx_idx <= urx_idx + 1'b1;
                        end
                    end else begin
                        urx_cnt <= urx_cnt + 1'b1;
                    end
                end

                URX_STOP: begin
                    if (urx_cnt == CLKS_PER_BIT - 1) begin
                        urx_valid <= 1'b1;
                        urx_state <= URX_IDLE;
                    end else begin
                        urx_cnt <= urx_cnt + 1'b1;
                    end
                end
                default: urx_state <= URX_IDLE;
            endcase
        end
    end

    // Keyboard & Gamepad Registers
    reg [7:0] kbd_data = 8'h00; // Bit 7: strobe, Bits 6:0: ASCII key
    reg       pb0 = 1'b0;       // Pushbutton 0 ($C061 - Open Apple)
    reg       pb1 = 1'b0;       // Pushbutton 1 ($C062 - Solid Apple)
    reg       pb2 = 1'b0;       // Pushbutton 2 ($C063)
    reg [7:0] joy_pdl0 = 8'd128; // Analog paddle 0 (default center)
    reg [7:0] joy_pdl1 = 8'd128; // Analog paddle 1 (default center)

    // Paddle countdown timers (triggered on $C070 read)
    reg [11:0] pdl0_cnt = 12'd0;
    reg [11:0] pdl1_cnt = 12'd0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pdl0_cnt <= 12'd0;
            pdl1_cnt <= 12'd0;
        end else begin
            // Trigger countdown on $C070-$C07F read
            if (io_read && (io_addr[7:4] == 4'h7)) begin
                pdl0_cnt <= {joy_pdl0, 4'b0000};
                pdl1_cnt <= {joy_pdl1, 4'b0000};
            end else if (ce_1m) begin
                if (pdl0_cnt > 12'd0) pdl0_cnt <= pdl0_cnt - 1'b1;
                if (pdl1_cnt > 12'd0) pdl1_cnt <= pdl1_cnt - 1'b1;
            end
        end
    end

    // Protocol parser for Keyboard and Gamepad packets:
    // Packet types:
    // 1. Standard ASCII: 0x01..0x7E, 0x0D (Return), 0x08/0x7F (Backspace)
    // 2. ANSI Escape Sequences: ESC [ A/B/C/D (Up/Down/Right/Left)
    // 3. Gamepad Packet: 0xFF 0x01 <buttons> <joy_x> <joy_y>
    localparam PKT_NORMAL = 3'd0;
    localparam PKT_ESC    = 3'd1;
    localparam PKT_BRACKET= 3'd2;
    localparam PKT_GP_HDR = 3'd3;
    localparam PKT_GP_BTN = 3'd4;
    localparam PKT_GP_X   = 3'd5;
    localparam PKT_GP_Y   = 3'd6;

    reg [2:0] pkt_state = PKT_NORMAL;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            kbd_data  <= 8'h00;
            pkt_state <= PKT_NORMAL;
            pb0       <= 1'b0;
            pb1       <= 1'b0;
            pb2       <= 1'b0;
            joy_pdl0  <= 8'd128;
            joy_pdl1  <= 8'd128;
        end else begin
            // Clear keyboard strobe on $C010 access
            if ((io_read || io_write) && (io_addr == 8'h10)) begin
                kbd_data[7] <= 1'b0;
            end

            if (urx_valid && !dbg_mode && (urx_byte != 8'h02)) begin
                case (pkt_state)
                    PKT_NORMAL: begin
                        if (urx_byte == 8'hFF) begin
                            pkt_state <= PKT_GP_HDR;
                        end else if (urx_byte == 8'h1B) begin // ESC
                            pkt_state <= PKT_ESC;
                        end else begin
                            // Standard keystroke:
                            // Normalize CR/LF to Apple II Return (0x0D)
                            // Normalize 0x7F (DEL) to Backspace (0x08)
                            if (urx_byte == 8'h0A || urx_byte == 8'h0D)
                                kbd_data <= {1'b1, 7'h0D}; // Return with strobe
                            else if (urx_byte == 8'h7F || urx_byte == 8'h08)
                                kbd_data <= {1'b1, 7'h08}; // Left arrow / backspace
                            else
                                kbd_data <= {1'b1, urx_byte[6:0]}; // ASCII with strobe
                        end
                    end

                    PKT_ESC: begin
                        if (urx_byte == 8'h5B) // '['
                            pkt_state <= PKT_BRACKET;
                        else begin
                            kbd_data  <= {1'b1, 7'h1B}; // Raw ESC key
                            pkt_state <= PKT_NORMAL;
                        end
                    end

                    PKT_BRACKET: begin
                        case (urx_byte)
                            8'h41: kbd_data <= {1'b1, 7'h0B}; // Up Arrow (Ctrl-K / 0x0B)
                            8'h42: kbd_data <= {1'b1, 7'h0A}; // Down Arrow (Ctrl-J / 0x0A)
                            8'h43: kbd_data <= {1'b1, 7'h15}; // Right Arrow (Ctrl-U / 0x15)
                            8'h44: kbd_data <= {1'b1, 7'h08}; // Left Arrow (Ctrl-H / 0x08)
                            default: ;
                        endcase
                        pkt_state <= PKT_NORMAL;
                    end

                    PKT_GP_HDR: begin
                        if (urx_byte == 8'h01)
                            pkt_state <= PKT_GP_BTN;
                        else
                            pkt_state <= PKT_NORMAL;
                    end

                    PKT_GP_BTN: begin
                        pb0 <= urx_byte[0];
                        pb1 <= urx_byte[1];
                        pb2 <= urx_byte[2];
                        pkt_state <= PKT_GP_X;
                    end

                    PKT_GP_X: begin
                        joy_pdl0  <= urx_byte;
                        pkt_state <= PKT_GP_Y;
                    end

                    PKT_GP_Y: begin
                        joy_pdl1  <= urx_byte;
                        pkt_state <= PKT_NORMAL;
                    end

                    default: pkt_state <= PKT_NORMAL;
                endcase
            end
        end
    end

    assign key_strobe = kbd_data[7];
    assign rx_byte    = urx_byte;
    assign rx_valid   = urx_valid;

    // Address Decoding for Input registers ($C000-$C07F):
    // $C000: Keyboard data (bit 7: strobe, bits 6:0: ASCII)
    // $C010: Clear strobe, returns AKD (any-key-down) or strobe in bit 7
    // $C061: PB0 (Open-Apple / Game Pushbutton 0), bit 7
    // $C062: PB1 (Solid-Apple / Game Pushbutton 1), bit 7
    // $C063: PB2 (Game Pushbutton 2), bit 7
    // $C064: PDL0 analog countdown, bit 7
    // $C065: PDL1 analog countdown, bit 7
    assign io_hit = (io_addr[7:4] == 4'h0) || (io_addr == 8'h10) ||
                    (io_addr[7:4] == 4'h6) || (io_addr[7:4] == 4'h7);

    reg in_bit;
    always @(*) begin
        case (io_addr[3:0])
            4'h1:    in_bit = pb0;                         // $C061 PB0
            4'h2:    in_bit = pb1;                         // $C062 PB1
            4'h3:    in_bit = pb2;                         // $C063 PB2
            4'h4:    in_bit = (pdl0_cnt != 12'd0);          // $C064 PDL0
            4'h5:    in_bit = (pdl1_cnt != 12'd0);          // $C065 PDL1
            default: in_bit = 1'b0;
        endcase
    end

    always @(*) begin
        case (io_addr[7:4])
            4'h0, 4'h1: io_dout = kbd_data;                 // $C000-$C01F
            4'h6:       io_dout = {in_bit, 7'h00};          // $C060-$C06F
            default:    io_dout = 8'h00;                    // $C070-$C07F & others
        endcase
    end

endmodule
