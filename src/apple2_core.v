// Apple //e Core Logic for Tang Nano 20K
// Integrates 65C02 CPU, 64KB RAM, 16KB System ROM, 4KB Character ROM, and Softswitches

module apple2_core (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,         // Active-high reset
    input  wire        ce_1m,         // 1.023 MHz clock enable
    input  wire        flash_clk,     // ~1.6 Hz flashing text clock

    // Inputs from Input Controller
    input  wire [7:0]  input_dout,
    input  wire        input_hit,
    output wire [7:0]  io_addr,
    output wire        io_read,
    output wire        io_write,

    // Speaker toggle pulse to Sound Generator
    output reg         spkr_pulse,

    // Softswitches to Video Generator
    output reg         text_mode,
    output reg         mixed_mode,
    output reg         page2,
    output reg         hires_mode,
    input  wire        vbl,

    // Video Generator RAM and Char ROM access
    input  wire [15:0] vram_addr,
    output reg  [7:0]  vram_data,
    input  wire [11:0] char_rom_addr,
    output wire [7:0]  char_rom_data,

    // Diagnostic status & Debugger Interface
    input  wire        cpu_rdy,
    input  wire [15:0] dbg_mem_addr,
    output wire [7:0]  dbg_mem_din,
    output wire [15:0] debug_cpu_pc,
    output wire [7:0]  debug_cpu_dout,
    output wire        debug_cpu_we,
    output wire        debug_cpu_sync,
    output wire [7:0]  debug_cpu_a,
    output wire [7:0]  debug_cpu_x,
    output wire [7:0]  debug_cpu_y,
    output wire [7:0]  debug_cpu_s,
    output wire [7:0]  debug_cpu_p,
    output wire [7:0]  debug_cpu_ir
);

    // CPU Signals
    wire [15:0] cpu_addr;
    wire [7:0]  cpu_dout;
    reg  [7:0]  cpu_din;
    wire        cpu_we;
    wire        cpu_sync;

    assign io_addr  = cpu_addr[7:0];
    assign io_read  = ce_1m && !cpu_we && (cpu_addr[15:8] == 8'hC0);
    assign io_write = ce_1m &&  cpu_we && (cpu_addr[15:8] == 8'hC0);

    assign debug_cpu_pc   = cpu_addr;
    assign debug_cpu_dout = cpu_dout;
    assign debug_cpu_we   = cpu_we;
    assign debug_cpu_sync = cpu_sync;

    // 65C02 CPU Core
    cpu_65c02 u_cpu (
        .clk(clk),
        .reset(reset),
        .AB(cpu_addr),
        .DI(cpu_din),
        .DO(cpu_dout),
        .WE(cpu_we),
        .IRQ(1'b0),
        .NMI(1'b0),
        .RDY(ce_1m & cpu_rdy),
        .SYNC(cpu_sync),
        .debug_a(debug_cpu_a),
        .debug_x(debug_cpu_x),
        .debug_y(debug_cpu_y),
        .debug_s(debug_cpu_s),
        .debug_p(debug_cpu_p),
        .debug_pc(),
        .debug_ir(debug_cpu_ir)
    );

    // Softswitches state registers
    reg lc_bank2;       // 1: Bank 2 ($D000 4KB alt), 0: Bank 1
    reg lc_read_ram;    // 1: Read LC RAM, 0: Read System ROM
    reg lc_write_ram;   // 1: Write LC RAM enabled
    reg lc_pre_write;   // Two successive reads required to enable write
    reg altchar;        // 1: Alternate character set
    reg col80;          // 1: 80 column mode
    reg store80;        // 1: 80STORE active

    // Softswitches decoding on posedge clk when ce_1m is active
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            text_mode    <= 1'b1; // Default: Text mode
            mixed_mode   <= 1'b0; // Default: Full screen
            page2        <= 1'b0; // Default: Page 1
            hires_mode   <= 1'b0; // Default: Lo-Res
            lc_bank2     <= 1'b0;
            lc_read_ram  <= 1'b0; // Default: Read ROM ($D000-$FFFF)
            lc_write_ram <= 1'b0;
            lc_pre_write <= 1'b0;
            altchar      <= 1'b0;
            col80        <= 1'b0;
            store80      <= 1'b0;
            spkr_pulse   <= 1'b0;
        end else if (ce_1m) begin
            spkr_pulse <= 1'b0;

            if (cpu_addr[15:8] == 8'hC0) begin
                // Speaker toggle at $C030
                if (cpu_addr[7:4] == 4'h3) begin
                    spkr_pulse <= 1'b1;
                end

                // Video softswitches ($C050 - $C057)
                if (cpu_addr[7:4] == 4'h5) begin
                    case (cpu_addr[3:1])
                        3'd0: text_mode  <= cpu_addr[0]; // $C050/$C051: TEXT / GRAPHICS
                        3'd1: mixed_mode <= cpu_addr[0]; // $C052/$C053: FULL / MIXED
                        3'd2: page2      <= cpu_addr[0]; // $C054/$C055: PAGE1 / PAGE2
                        3'd3: hires_mode <= cpu_addr[0]; // $C056/$C057: LORES / HIRES
                        default: ;
                    endcase
                end

                // Apple //e aux softswitches ($C000-$C00F writes)
                if (cpu_we && (cpu_addr[7:4] == 4'h0)) begin
                    case (cpu_addr[3:1])
                        3'd0: store80 <= cpu_addr[0]; // $C000/$C001: 80STORE
                        3'd6: col80   <= cpu_addr[0]; // $C00C/$C00D: 80COL
                        3'd7: altchar <= cpu_addr[0]; // $C00E/$C00F: ALTCHAR
                        default: ;
                    endcase
                end

                // Language Card Bank Switching ($C080 - $C08F)
                if (cpu_addr[7:4] == 4'h8) begin
                    lc_bank2    <= ~cpu_addr[3]; // A3=0 -> Bank 2, A3=1 -> Bank 1
                    lc_read_ram <= ~(cpu_addr[1] ^ cpu_addr[0]); // A0=A1 -> RAM read, A0!=A1 -> ROM read

                    if (!cpu_we && cpu_addr[0]) begin
                        // Two successive reads with A0=1 enable write
                        if (lc_pre_write)
                            lc_write_ram <= 1'b1;
                        lc_pre_write <= 1'b1;
                    end else if (!cpu_addr[0]) begin
                        lc_write_ram <= 1'b0;
                        lc_pre_write <= 1'b0;
                    end
                end
            end
        end
    end

    // Effective address: CPU address during normal operation, dbg_mem_addr when paused
    wire [15:0] effective_cpu_addr = (!cpu_rdy) ? dbg_mem_addr : cpu_addr;

    // Address Decode logic:
    // Memory map:
    // $0000 - $BFFF: Main RAM (48KB)
    // $C000 - $C0FF: I/O Softswitches
    // $C100 - $CFFF: Internal Peripheral / Slot ROM
    // $D000 - $FFFF: Language Card (RAM or System ROM)
    wire is_ram_base = (effective_cpu_addr < 16'hC000);
    wire is_io       = (effective_cpu_addr[15:8] == 8'hC0);
    wire is_slot_rom = (effective_cpu_addr >= 16'hC100 && effective_cpu_addr < 16'hD000);
    wire is_lc_area  = (effective_cpu_addr >= 16'hD000);

    // RAM Write Enable:
    // Writes go to RAM if in $0000-$BFFF, or if in $D000-$FFFF with lc_write_ram enabled
    wire ram_we_cpu = cpu_we && (is_ram_base || (is_lc_area && lc_write_ram));

    // Time-multiplexed RAM address and write enable:
    // Cycle with ce_1m == 1: CPU access
    // Cycle with ce_1m == 0: Video Controller access
    wire [15:0] ram_addr = ce_1m ? effective_cpu_addr : vram_addr;
    wire [7:0]  ram_din  = cpu_dout;
    wire        ram_we   = (ce_1m && cpu_rdy) ? ram_we_cpu : 1'b0;
    wire [7:0]  ram_dout;

    // 64KB RAM instance (synthesizes to 32 SP blocks in Gowin)
    apple2_ram_64k u_ram (
        .clk(clk),
        .addr(ram_addr),
        .din(ram_din),
        .we(ram_we),
        .dout(ram_dout)
    );

    // Latch Video RAM output when ce_1m == 0
    always @(posedge clk) begin
        if (!ce_1m) begin
            vram_data <= ram_dout;
        end
    end

    // System ROM: 16KB ($C000 - $FFFF)
    wire [13:0] rom_addr = effective_cpu_addr[13:0]; // 0x0000 = $C000, 0x3FFF = $FFFF
    wire [7:0]  rom_dout;

    apple2_system_rom u_rom (
        .clk(clk),
        .addr(rom_addr),
        .dout(rom_dout)
    );

    // Character ROM: 4KB/8KB
    apple2_char_rom u_char_rom (
        .clk(clk),
        .addr(char_rom_addr),
        .dout(char_rom_data)
    );

    // Softswitch Read Multiplexer for $C010-$C01F:
    reg [7:0] softswitch_read_data;
    always @(*) begin
        case (cpu_addr[3:0])
            4'h1: softswitch_read_data = {lc_bank2, 7'h00};       // $C011 RDLCBNK2
            4'h2: softswitch_read_data = {lc_read_ram, 7'h00};    // $C012 RDLCRAM
            4'h3: softswitch_read_data = 8'h00;                   // $C013 RDRAMRD
            4'h4: softswitch_read_data = 8'h00;                   // $C014 RDRAMWRT
            4'h8: softswitch_read_data = {store80, 7'h00};        // $C018 RD80STORE
            4'h9: softswitch_read_data = {~vbl, 7'h00};           // $C019 RDVBLBAR
            4'hA: softswitch_read_data = {text_mode, 7'h00};      // $C01A RDTEXT
            4'hB: softswitch_read_data = {mixed_mode, 7'h00};     // $C01B RDMIXED
            4'hC: softswitch_read_data = {page2, 7'h00};          // $C01C RDPAGE2
            4'hD: softswitch_read_data = {hires_mode, 7'h00};     // $C01D RDHIRES
            4'hE: softswitch_read_data = {altchar, 7'h00};        // $C01E RDALTCHAR
            4'hF: softswitch_read_data = {col80, 7'h00};          // $C01F RD80COL
            default: softswitch_read_data = 8'h00;
        endcase
    end

    // CPU Data In (Read Bus) Multiplexer:
    always @(*) begin
        if (is_ram_base) begin
            cpu_din = ram_dout;
        end else if (is_io) begin
            if (input_hit) begin
                cpu_din = input_dout;
            end else if (cpu_addr[7:4] == 4'h1 && cpu_addr[3:0] != 4'h0) begin
                cpu_din = softswitch_read_data;
            end else begin
                cpu_din = 8'h00;
            end
        end else if (is_slot_rom) begin
            cpu_din = rom_dout; // System ROM provides internal firmware for $C100-$CFFF
        end else if (is_lc_area) begin
            if (lc_read_ram)
                cpu_din = ram_dout; // Read from Language Card RAM
            else
                cpu_din = rom_dout; // Read from System ROM (Applesoft BASIC + Monitor)
        end else begin
            cpu_din = 8'hFF;
        end
    end

    assign dbg_mem_din = cpu_din;

endmodule
