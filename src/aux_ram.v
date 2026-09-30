// Auxiliary 64 KB RAM in the Tang Nano 20K's on-board SDRAM.
//
// Wraps sdram/sdram.v (16-bit words, one access every 8 clocks here) with
// three clients, so nothing else in the design needs to know SDRAM timing:
//
//  * Video: a 40-byte line buffer. fill_start (once per scanline, in the
//    blanking before the next one) loads the 40 bytes at fill_addr; the
//    video reads them combinationally through col/line_data, so the SDRAM
//    is never on the video path. 20 words at 8 clocks is 160 clocks, less
//    than the ~218 between the end of one active line and the next line's
//    pre-roll.
//  * CPU reads: a one-word cache. While rd_want is up and the word is not
//    cached, a read is issued; rd_hit says rd_data is valid. The CPU's
//    address is stable ~25 clocks before its cycle, so a stall is rare.
//  * CPU writes: a one-entry buffer. wr_go latches it at the CPU cycle;
//    wr_busy is high until the SDRAM has taken it and blocks a second one.
//
// A fourth client, the Disk ][ image store (src/disk2/disk2_store.v), was
// added later and sits below all three: it moves whole sectors, and a floppy
// sector has milliseconds of slack, so it must never delay the video line
// fill or the CPU.
//
// Priority at each 8-clock slot: refresh, line fill, CPU write, CPU read,
// disk store.  A refresh is due every REFRESH_CLKS (7.4 us at 27 MHz, under
// the 7.8 us of 8192 rows per 64 ms).
//
// Byte a lives in word a[15:1]; a[0]=0 is the upper byte of the 16-bit word.
// The SDRAM is not re-initialised on warm resets, so aux RAM survives them, and
// so do the disk images: the store's images are in bank 1, which nothing else
// addresses.

module aux_ram (
    input  wire        clk,          // 27 MHz
    input  wire        reset,

    // Video line buffer
    input  wire        fill_start,
    input  wire [15:0] fill_addr,    // byte address of column 0 (even)
    input  wire [5:0]  col,          // 0..39
    output wire [7:0]  line_data,

    // CPU port
    input  wire        rd_want,
    input  wire [15:0] rd_addr,
    output wire [7:0]  rd_data,
    output wire        rd_hit,
    input  wire        wr_go,
    input  wire [15:0] wr_addr,
    input  wire [7:0]  wr_data,
    output wire        wr_busy,

    // Disk ][ image store (src/disk2/disk2_store.v), the lowest-priority
    // client.  A request is latched when dsk_go is pulsed, so a client that
    // asks while the arbiter is busy does not lose it, and dsk_ack pulses when
    // the slot has finished (with dsk_rdata valid, on a read).
    input  wire        dsk_go,
    input  wire [21:0] dsk_addr,
    input  wire        dsk_we,
    input  wire [15:0] dsk_wdata,
    output wire [15:0] dsk_rdata,
    output wire        dsk_ack,
    output wire        dsk_idle,

    // SDRAM pins (Gowin embedded SDRAM names)
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    inout  wire [31:0] IO_sdram_dq,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm
);

    parameter REFRESH_CLKS = 200;

    // Hold the controller in reset for ~300 us after configuration (not on
    // warm resets): the SDRAM wants 100-200 us of stable clock before init.
    reg [13:0] pwr = 14'd0;
    always @(posedge clk) if (!pwr[13]) pwr <= pwr + 1'b1;

    reg         sd_cs = 1'b0, sd_we = 1'b0, sd_refresh = 1'b0;
    reg  [1:0]  sd_ds = 2'b00;
    reg  [15:0] sd_din = 16'd0;
    reg  [21:0] sd_addr = 22'd0;
    wire [15:0] sd_dout;
    wire        sd_ready;
    wire [12:0] sd_a13; // [12:11] unused: the part has an 11-bit address bus

    sdram u_sdram (
        .sd_clk(O_sdram_clk), .sd_cke(O_sdram_cke), .sd_data(IO_sdram_dq),
        .sd_addr(sd_a13), .sd_dqm(O_sdram_dqm), .sd_ba(O_sdram_ba),
        .sd_cs(O_sdram_cs_n), .sd_we(O_sdram_wen_n), .sd_ras(O_sdram_ras_n),
        .sd_cas(O_sdram_cas_n),
        .clk(clk), .reset_n(pwr[13]), .ready(sd_ready), .refresh(sd_refresh),
        .din(sd_din), .dout(sd_dout), .addr(sd_addr), .ds(sd_ds),
        .cs(sd_cs), .we(sd_we)
    );
    assign O_sdram_addr = sd_a13[10:0];

    localparam [2:0] K_REF = 3'd0, K_FILL = 3'd1, K_WR = 3'd2, K_RD = 3'd3, K_DSK = 3'd4;

    // Operation engine
    reg        op_busy = 1'b0;
    reg [2:0]  t = 3'd0;
    reg [2:0]  kind = K_REF;
    reg [14:0] rd_word_q = 15'd0;

    // Refresh timer
    reg [7:0]  refresh_cnt = 8'd0;
    reg        refresh_pend = 1'b0;

    // Line fill
    reg        fill_active = 1'b0;
    reg [4:0]  fill_i = 5'd0;
    reg [14:0] fill_base = 15'd0;
    // One 40-byte Apple text row (20 SDRAM words of two bytes); the size must
    // match the 40-column row video_generator.v fills it for.
    localparam LINE_BYTES = 40;
    reg [7:0]  linebuf [0:LINE_BYTES-1];
    assign line_data = linebuf[col];

    // CPU write buffer
    reg        wr_pend = 1'b0;
    reg [15:0] wr_a = 16'd0;
    reg [7:0]  wr_d = 8'd0;
    assign wr_busy = wr_pend;

    // CPU read cache
    reg        cache_valid = 1'b0;
    reg [14:0] cache_word = 15'd0;
    reg [15:0] cache_data = 16'd0;
    reg        rd_stale = 1'b0;      // a write landed while a read was in flight
    assign rd_hit  = cache_valid && (cache_word == rd_addr[15:1]);
    assign rd_data = rd_addr[0] ? cache_data[7:0] : cache_data[15:8];

    // Disk store port.  A request is latched when dsk_go arrives, so the store
    // can pulse one whenever it is ready and the request survives the arbiter
    // being busy with a line fill or a CPU access; dsk_idle is then simply
    // "nothing pending", which is the store's cue to raise the next one.
    reg        dsk_pend = 1'b0;
    reg [21:0] dsk_a_q  = 22'd0;
    reg        dsk_we_q = 1'b0;
    reg [15:0] dsk_d_q  = 16'd0;
    reg [15:0] dsk_r_q  = 16'd0;
    reg        dsk_ack_q= 1'b0;
    assign dsk_idle = !dsk_pend;
    assign dsk_ack  = dsk_ack_q;
    assign dsk_rdata= dsk_r_q;

    // The controller can still be mid-cycle when it first reports ready, and
    // ignores a command then; give it 8 clocks.
    reg [3:0] settle = 4'd0;
    always @(posedge clk) begin
        if (!sd_ready) settle <= 4'd0;
        else if (!settle[3]) settle <= settle + 1'b1;
    end

    always @(posedge clk) begin
        // Refresh timer
        if (refresh_cnt == REFRESH_CLKS - 1) begin
            refresh_cnt  <= 8'd0;
            refresh_pend <= 1'b1;
        end else begin
            refresh_cnt <= refresh_cnt + 1'b1;
        end

        if (reset) begin
            cache_valid <= 1'b0;
            fill_active <= 1'b0;
            wr_pend     <= 1'b0;
            dsk_pend    <= 1'b0;
            dsk_ack_q   <= 1'b0;
        end

        // A disk-store request is taken whatever the arbiter is doing, and held
        // until a slot can be given to it.
        dsk_ack_q <= 1'b0;
        if (dsk_go) begin
            dsk_pend <= 1'b1;
            dsk_a_q  <= dsk_addr;
            dsk_we_q <= dsk_we;
            dsk_d_q  <= dsk_wdata;
        end

        if (fill_start) begin
            fill_active <= 1'b1;
            fill_i      <= 5'd0;
            fill_base   <= fill_addr[15:1];
        end

        if (wr_go) begin
            wr_pend     <= 1'b1;
            wr_a        <= wr_addr;
            wr_d        <= wr_data;
            cache_valid <= 1'b0;
            if (op_busy && kind == K_RD) rd_stale <= 1'b1;
        end

        if (op_busy) begin
            t <= t + 1'b1;
            if (t == 3'd3) sd_cs <= 1'b0;   // cs high for cycles 0..3: the write data is driven while it is
            if (t == 3'd7) begin
                op_busy <= 1'b0;
                case (kind)
                    K_FILL: begin
                        linebuf[{fill_i, 1'b0}] <= sd_dout[15:8];
                        linebuf[{fill_i, 1'b1}] <= sd_dout[7:0];
                        fill_i <= fill_i + 1'b1;
                        if (fill_i == LINE_BYTES/2 - 1) fill_active <= 1'b0;
                    end
                    K_WR: wr_pend <= 1'b0;
                    K_RD: begin
                        cache_data  <= sd_dout;
                        cache_word  <= rd_word_q;
                        cache_valid <= !rd_stale && !wr_pend && !wr_go;
                    end
                    K_DSK: begin
                        dsk_r_q   <= sd_dout;
                        dsk_pend  <= 1'b0;
                        dsk_ack_q <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end else if (sd_ready && settle[3]) begin
            if (refresh_pend) begin
                refresh_pend <= 1'b0;
                kind <= K_REF; sd_refresh <= 1'b1; sd_we <= 1'b0;
                op_busy <= 1'b1; t <= 3'd0; sd_cs <= 1'b1;
            end else if (fill_active) begin
                kind <= K_FILL; sd_refresh <= 1'b0; sd_we <= 1'b0; sd_ds <= 2'b00;
                sd_addr <= {7'd0, fill_base + fill_i};
                op_busy <= 1'b1; t <= 3'd0; sd_cs <= 1'b1;
            end else if (wr_pend) begin
                kind <= K_WR; sd_refresh <= 1'b0; sd_we <= 1'b1;
                sd_ds <= wr_a[0] ? 2'b10 : 2'b01;   // ds bit set masks that byte
                sd_din <= {wr_d, wr_d};
                sd_addr <= {7'd0, wr_a[15:1]};
                op_busy <= 1'b1; t <= 3'd0; sd_cs <= 1'b1;
            end else if (rd_want && !rd_hit) begin
                kind <= K_RD; sd_refresh <= 1'b0; sd_we <= 1'b0; sd_ds <= 2'b00;
                sd_addr <= {7'd0, rd_addr[15:1]};
                rd_word_q <= rd_addr[15:1];
                rd_stale <= 1'b0;
                op_busy <= 1'b1; t <= 3'd0; sd_cs <= 1'b1;
            end else if (dsk_pend) begin
                // Lowest priority: a sector move, which has milliseconds of
                // slack and must never delay the line fill or the CPU.
                kind <= K_DSK; sd_refresh <= 1'b0; sd_we <= dsk_we_q;
                sd_ds <= 2'b00;
                sd_din <= dsk_d_q;
                sd_addr <= dsk_a_q;
                op_busy <= 1'b1; t <= 3'd0; sd_cs <= 1'b1;
            end
        end
    end
endmodule
