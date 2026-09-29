// Apple //e Core Logic for Tang Nano 20K
// Integrates 65C02 CPU, 64KB RAM, 16KB System ROM, 4KB Character ROM, and Softswitches

module apple2_core (
    input  wire        clk,           // 27.0 MHz
    input  wire        reset,         // Active-high reset
    input  wire        ce_1m,         // 1.023 MHz clock enable

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
    output reg         col80,
    output reg         altchar,
    output reg         dhires,        // AN3 cleared ($C05E): double hi-res
    output reg         store80,
    input  wire        vbl,

    // Video Generator RAM and Char ROM access
    input  wire        vram_req,
    input  wire [15:0] vram_addr,
    output reg  [7:0]  vram_data,
    input  wire [11:0] char_rom_addr,
    output wire [7:0]  char_rom_data,

    // Aux RAM port (aux_ram.v): the CPU's reads and writes that the aux
    // switches send to the second 64 KB
    output wire        aux_rd_want,
    output wire [15:0] aux_rd_addr,
    input  wire        aux_rd_hit,
    input  wire [7:0]  aux_rd_data,
    output wire        aux_wr_go,
    output wire [15:0] aux_wr_addr,
    output wire [7:0]  aux_wr_data,
    input  wire        aux_wr_busy,

    // Diagnostic status & Debugger Interface
    input  wire        cpu_rdy,
    input  wire [15:0] dbg_mem_addr,
    output wire [7:0]  dbg_mem_din,
    input  wire        dbg_aux,        // debugger reads aux RAM
    output wire        dbg_mem_ready,  // dbg_mem_din is valid
    output wire [15:0] debug_cpu_pc,
    output wire [15:0] debug_cpu_addr,
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

    // Video-CPU memory conflict prevention:
    // If a 1 MHz CPU cycle enable (ce_1m) coincides with a video prefetch
    // access (vram_req or its read latch cycle vram_req_d), hold the cycle
    // enable until video RAM read has finished. This completely eliminates
    // contention/corruption between video prefetch and CPU RAM reads/writes,
    // avoiding display flickering/scrolling artifacts.
    reg ce_1m_pending;
    // The same hold applies while an aux RAM access is not ready (aux_stall).
    wire video_busy = vram_req || vram_req_d || aux_stall;
    wire cpu_ce = (ce_1m || ce_1m_pending) && !video_busy;

    always @(posedge clk or posedge reset) begin
        if (reset)
            ce_1m_pending <= 1'b0;
        else if ((ce_1m || ce_1m_pending) && video_busy)
            ce_1m_pending <= 1'b1;
        else
            ce_1m_pending <= 1'b0;
    end

    // A CPU cycle that really happens: while the debugger holds RDY low the
    // enable keeps ticking, and side effects must not replay on each tick.
    wire cpu_go = cpu_ce && cpu_rdy;

    assign io_addr  = cpu_addr[7:0];
    assign io_read  = cpu_go && !cpu_we && (cpu_addr[15:8] == 8'hC0);
    assign io_write = cpu_go &&  cpu_we && (cpu_addr[15:8] == 8'hC0);

    assign debug_cpu_addr = cpu_addr;
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
        .RDY(cpu_ce & cpu_rdy),
        .SYNC(cpu_sync),
        .debug_a(debug_cpu_a),
        .debug_x(debug_cpu_x),
        .debug_y(debug_cpu_y),
        .debug_s(debug_cpu_s),
        .debug_p(debug_cpu_p),
        .debug_pc(debug_cpu_pc),
        .debug_ir(debug_cpu_ir)
    );

    // Softswitches state registers
    reg lc_bank2;       // 1: Bank 2 ($D000 4KB alt), 0: Bank 1
    reg lc_read_ram;    // 1: Read LC RAM, 0: Read System ROM
    reg lc_write_ram;   // 1: Write LC RAM enabled
    reg lc_pre_write;   // Two successive reads required to enable write
    reg intcxrom;       // 1: Internal CX ROM ($C100-$CFFF) active
    reg slotc3rom;      // 1: slot 3 ROM at $C300 (0: internal 80-col firmware)
    reg intc8rom;       // 1: internal ROM at $C800-$CFFF (set by a $C3xx access)
    reg ramrd;          // 1: reads of $0200-$BFFF come from aux RAM
    reg ramwrt;         // 1: writes to $0200-$BFFF go to aux RAM
    reg altzp;          // 1: zero page, stack and language card use aux RAM

    // Softswitches decoding on posedge clk when ce_1m is active
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            text_mode    <= 1'b1; // Default: Text mode
            mixed_mode   <= 1'b0; // Default: Full screen
            page2        <= 1'b0; // Default: Page 1
            hires_mode   <= 1'b0; // Default: Lo-Res
            dhires       <= 1'b0;
            lc_bank2     <= 1'b0;
            lc_read_ram  <= 1'b0; // Default: Read ROM ($D000-$FFFF)
            lc_write_ram <= 1'b0;
            lc_pre_write <= 1'b0;
            altchar      <= 1'b0;
            col80        <= 1'b0;
            store80      <= 1'b0;
            intcxrom     <= 1'b1; // Default: Internal CX ROM active
            slotc3rom    <= 1'b0;
            intc8rom     <= 1'b0;
            ramrd        <= 1'b0;
            ramwrt       <= 1'b0;
            altzp        <= 1'b0;
            spkr_pulse   <= 1'b0;
        end else if (cpu_go) begin
            spkr_pulse <= 1'b0;

            // INTC8ROM: set by any $C3xx access with SLOTC3ROM off, cleared by $CFFF
            if (cpu_addr[15:8] == 8'hC3 && !slotc3rom)
                intc8rom <= 1'b1;
            else if (cpu_addr == 16'hCFFF)
                intc8rom <= 1'b0;

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
                        3'd7: dhires     <= ~cpu_addr[0]; // $C05E/$C05F: DHIRES on / off (AN3)
                        default: ;
                    endcase
                end

                // Apple //e aux softswitches ($C000-$C00F writes)
                if (cpu_we && (cpu_addr[7:4] == 4'h0)) begin
                    case (cpu_addr[3:1])
                        3'd0: store80  <= cpu_addr[0]; // $C000/$C001: 80STORE
                        3'd1: ramrd    <= cpu_addr[0]; // $C002/$C003: RAMRD
                        3'd2: ramwrt   <= cpu_addr[0]; // $C004/$C005: RAMWRT
                        3'd3: intcxrom <= cpu_addr[0]; // $C006/$C007: INTCXROM
                        3'd4: altzp    <= cpu_addr[0]; // $C008/$C009: ALTZP
                        3'd5: slotc3rom <= cpu_addr[0]; // $C00A/$C00B: SLOTC3ROM
                        3'd6: col80    <= cpu_addr[0]; // $C00C/$C00D: 80COL
                        3'd7: altchar  <= cpu_addr[0]; // $C00E/$C00F: ALTCHAR
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

    // Aux RAM selection, from the CPU's own address (the debugger, which runs
    // with cpu_rdy low, sees main RAM only):
    //   $0000-$01FF zero page and stack   ALTZP
    //   $0200-$BFFF                       RAMRD / RAMWRT, except that with
    //                                     80STORE the text page ($0400-$07FF)
    //                                     and, with HIRES, $2000-$3FFF follow PAGE2
    //   $D000-$FFFF language card RAM     ALTZP
    wire st_page = store80 && (cpu_addr[15:10] == 6'b000001 ||
                               (hires_mode && cpu_addr[15:13] == 3'b001));
    wire aux_sel_cpu_rd = cpu_rdy && (cpu_addr < 16'h0200 ? altzp :
                                  cpu_addr < 16'hC000 ? (st_page ? page2 : ramrd) :
                                  cpu_addr >= 16'hD000 ? (lc_read_ram && altzp) : 1'b0);
    wire aux_sel_wr = cpu_rdy && (cpu_addr < 16'h0200 ? altzp :
                                  cpu_addr < 16'hC000 ? (st_page ? page2 : ramwrt) :
                                  cpu_addr >= 16'hD000 ? (lc_write_ram && altzp) : 1'b0);
    // The debugger, while it holds the CPU, can read aux RAM instead of main
    wire dbg_aux_sel = !cpu_rdy && dbg_aux &&
                       (dbg_mem_addr < 16'hC000 || (dbg_mem_addr >= 16'hD000 && lc_read_ram));
    wire aux_sel_rd    = aux_sel_cpu_rd || dbg_aux_sel;
    assign aux_rd_want = (aux_sel_cpu_rd && !cpu_we) || dbg_aux_sel;
    assign dbg_mem_ready = !dbg_aux_sel || aux_rd_hit;
    wire   aux_stall   = (aux_sel_cpu_rd && !cpu_we && !aux_rd_hit) || (aux_sel_wr && cpu_we && aux_wr_busy);
    assign aux_wr_go   = cpu_go && cpu_we && aux_sel_wr;
    assign aux_wr_data = cpu_dout;

    // RAM Write Enable:
    // Writes go to RAM if in $0000-$BFFF, or if in $D000-$FFFF with lc_write_ram enabled
    // (and not to the aux RAM instead)
    wire ram_we_cpu = cpu_we && !aux_sel_wr && (is_ram_base || (is_lc_area && lc_write_ram));
    wire ram_we     = (cpu_ce && cpu_rdy) ? ram_we_cpu : 1'b0;

    // Dual-latch RAM arbitration between CPU and Video Generator
    reg vram_req_d;
    always @(posedge clk or posedge reset) begin
        if (reset)
            vram_req_d <= 1'b0;
        else
            vram_req_d <= vram_req;
    end

    wire is_lc_bank2_d = lc_bank2 && (effective_cpu_addr >= 16'hD000 && effective_cpu_addr < 16'hE000);
    wire [15:0] cpu_ram_addr = is_lc_bank2_d ? {4'hC, effective_cpu_addr[11:0]} : effective_cpu_addr;
    assign aux_rd_addr = cpu_ram_addr;
    assign aux_wr_addr = cpu_ram_addr;
    wire ram_addr_is_video = vram_req;
    wire [15:0] ram_addr   = ram_addr_is_video ? vram_addr : cpu_ram_addr;
    wire [7:0]  ram_din    = cpu_dout;
    wire [7:0]  ram_dout;

    // 64KB RAM instance (synthesizes to 32 SP blocks in Gowin)
    apple2_ram_64k u_ram (
        .clk(clk),
        .addr(ram_addr),
        .din(ram_din),
        .we(ram_we),
        .dout(ram_dout)
    );

    // Latch Video RAM output when vram_req_d is active
    always @(posedge clk or posedge reset) begin
        if (reset)
            vram_data <= 8'hA0;
        else if (vram_req_d)
            vram_data <= ram_dout;
    end

    // Latch CPU RAM output when not serving video
    reg [7:0] cpu_ram_dout;
    always @(posedge clk or posedge reset) begin
        if (reset)
            cpu_ram_dout <= 8'h00;
        else if (!vram_req_d)
            cpu_ram_dout <= ram_dout;
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

    // Softswitch Read Multiplexer for $C010-$C01F (status returned in bit 7)
    reg sw_bit;
    always @(*) begin
        case (effective_cpu_addr[3:0])
            4'h1:    sw_bit = lc_bank2;       // $C011 RDLCBNK2
            4'h2:    sw_bit = lc_read_ram;    // $C012 RDLCRAM
            4'h3:    sw_bit = ramrd;          // $C013 RDRAMRD
            4'h4:    sw_bit = ramwrt;         // $C014 RDRAMWRT
            4'h5:    sw_bit = intcxrom;       // $C015 RDCXROM
            4'h6:    sw_bit = altzp;          // $C016 RDALTZP
            4'h7:    sw_bit = slotc3rom;      // $C017 RDC3ROM
            4'h8:    sw_bit = store80;        // $C018 RD80STORE
            4'h9:    sw_bit = ~vbl;           // $C019 RDVBLBAR
            4'hA:    sw_bit = text_mode;      // $C01A RDTEXT
            4'hB:    sw_bit = mixed_mode;     // $C01B RDMIXED
            4'hC:    sw_bit = page2;          // $C01C RDPAGE2
            4'hD:    sw_bit = hires_mode;     // $C01D RDHIRES
            4'hE:    sw_bit = altchar;        // $C01E RDALTCHAR
            4'hF:    sw_bit = col80;          // $C01F RD80COL
            default: sw_bit = 1'b0;
        endcase
    end
    // Bit 7 is the switch; bits 6:0 are the last key read, as on the //e
    wire [7:0] softswitch_read_data = {sw_bit, input_dout[6:0]};

    // CPU Data In (Read Bus) Multiplexer:
    reg [7:0] cpu_din_comb;
    always @(*) begin
        if (is_ram_base) begin
            cpu_din_comb = aux_sel_rd ? aux_rd_data : cpu_ram_dout;
        end else if (is_io) begin
            if (input_hit) begin
                cpu_din_comb = input_dout;
            end else if (effective_cpu_addr[7:4] == 4'h1 && effective_cpu_addr[3:0] != 4'h0) begin
                cpu_din_comb = softswitch_read_data;
            end else begin
                cpu_din_comb = 8'h00;
            end
        end else if (is_slot_rom) begin
            // No slot cards: the internal ROM answers when selected, else the bus floats
            if (intcxrom || (effective_cpu_addr[15:8] == 8'hC3 && !slotc3rom)
                         || (effective_cpu_addr >= 16'hC800 && intc8rom))
                cpu_din_comb = rom_dout;
            else
                cpu_din_comb = 8'h00;
        end else if (is_lc_area) begin
            if (lc_read_ram)
                cpu_din_comb = aux_sel_rd ? aux_rd_data : cpu_ram_dout; // Language Card RAM
            else
                cpu_din_comb = rom_dout; // Read from System ROM (Applesoft BASIC + Monitor)
        end else begin
            cpu_din_comb = 8'hFF;
        end
    end

    // Latch data in to CPU on 1 MHz clock enable to prevent combinational loops
    // with CPU's internal address generator (which derives AB from DI in ABS/JMP/ZP states).
    always @(posedge clk or posedge reset) begin
        if (reset)
            cpu_din <= 8'h00;
        else if (cpu_ce && cpu_rdy)
            cpu_din <= cpu_din_comb;
    end

    assign dbg_mem_din = (!cpu_rdy) ? cpu_din_comb : cpu_din;

endmodule
