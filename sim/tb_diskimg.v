// tb_diskimg -- the debugger's Disk ][ image transfer, both directions.
//
// This is the path a host actually uses to get a disk onto the board: the
// debugger's d1/d2 and e1/e2 commands, one byte at a time over the debugger's
// own port, into and out of the image store's SDRAM.  The card is not involved
// and neither is the CPU: what is checked is that the bytes the host sends
// arrive in the image in the right place, and that the bytes that come back are
// the ones that went in.
//
// It is a separate bench from tb_disk2 because it is a different system: that one
// drives the card with real bit timings and checks that sectors decode, and it
// ties the store's debugger port off.  What is shared is the SDRAM stand-in,
// which is the same 8-clocks-per-word model aux_ram.v paces the real controller
// with, so the byte map under test is the byte map the card sees.
//
// The host here is a real one: it reads the wire at 115200 8N1, it waits for the
// banner before it sends anything, and it paces the upload on the board's
// acknowledgements.  Those are not politeness.  A host that blasts the file gets
// its bytes dropped in the middle, because the board has room for exactly one
// byte in hand, and it ends up with an image the board believes in.

`timescale 1ns/1ps

module tb_diskimg;

    localparam integer IMG_BYTES = 143360;   // 35 tracks x 16 sectors x 256
    localparam integer DL_BYTES  = 4096;     // how much of a download is checked
    localparam integer SHADOWB   = 300000;   // two drives plus room for overruns

    reg clk = 1'b0;
    always #18.5 clk = ~clk;                 // 27 MHz

    reg reset = 1'b1;

    // The debugger's own inputs.  A command byte is offered on one clock edge,
    // the way input_controller does it, and a pause after it, the way a host
    // that waits for silence does: the debugger reads a command only while it is
    // idle and it prints for tens of cycles after taking one, so "d1" sent in
    // consecutive bytes loses the "1".
    reg  [7:0] rx_byte  = 8'h00;
    reg        rx_valid = 1'b0;

    wire       uart_tx;
    wire       dbg_mode, cpu_rdy, cpu_reset_req, dbg_aux, dbg_mem_ready;
    wire [7:0] dbg_mem_din;
    wire [15:0] dbg_mem_addr;
    wire       img_up_go, img_up_drive, img_up_last, img_up_busy, img_up_done;
    wire [17:0] img_up_addr;
    wire [7:0]  img_up_data;
    wire       img_dn_go, img_dn_drive, img_dn_last, img_dn_valid, img_dn_done;
    wire [17:0] img_dn_addr;
    wire [7:0]  img_dn_data;

    // A CPU that never runs, which is what a paused machine looks like to the
    // debugger.  The registers are only read back by the r command.
    wire [15:0] cpu_pc = 16'hFA62, cpu_addr = 16'h0000;
    wire [7:0]  cpu_a = 8'h00, cpu_x = 8'h00, cpu_y = 8'h00, cpu_s = 8'hFF;
    wire [7:0]  cpu_p = 8'h20, cpu_ir = 8'h00, cpu_dout = 8'h00;
    wire        cpu_we = 1'b0, cpu_sync = 1'b0;

    serial_debugger u_dbg (
        .clk(clk), .reset(reset), .ce_1m(1'b1), .uart_tx(uart_tx),
        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .dbg_mode(dbg_mode), .cpu_rdy(cpu_rdy), .cpu_reset_req(cpu_reset_req),
        .dbg_mem_addr(dbg_mem_addr), .dbg_mem_din(dbg_mem_din),
        .dbg_mem_ready(dbg_mem_ready), .dbg_aux(dbg_aux),
        .img_up_go(img_up_go), .img_up_drive(img_up_drive), .img_up_addr(img_up_addr),
        .img_up_data(img_up_data), .img_up_last(img_up_last),
        .img_up_busy(img_up_busy), .img_up_done(img_up_done),
        .img_dn_go(img_dn_go), .img_dn_drive(img_dn_drive), .img_dn_addr(img_dn_addr),
        .img_dn_last(img_dn_last), .img_dn_data(img_dn_data),
        .img_dn_valid(img_dn_valid), .img_dn_done(img_dn_done),
        .cpu_pc(cpu_pc), .cpu_a(cpu_a), .cpu_x(cpu_x), .cpu_y(cpu_y), .cpu_s(cpu_s),
        .cpu_p(cpu_p), .cpu_ir(cpu_ir), .cpu_addr(cpu_addr), .cpu_dout(cpu_dout),
        .cpu_we(cpu_we), .cpu_sync(cpu_sync),
        .text_mode(1'b1), .mixed_mode(1'b0), .page2(1'b0), .hires_mode(1'b0),
        .pll_locked(1'b1)
    );

    // The store, with the same SDRAM stand-in as tb_disk2: one word per 8 clocks.
    // The card's ports are tied off -- an input may be tied to a constant but an
    // output may not, so grp_ack needs a wire of its own.
    wire        dsk_go, dsk_we, dsk_ack, dsk_idle, unused_grp_ack;
    wire [21:0] dsk_addr;
    wire [15:0] dsk_wdata, dsk_rdata;
    wire [1:0]  drv_present, drv_writable;

    reg  [3:0]  dsk_t = 4'd0;
    reg         dsk_busy = 1'b0;
    reg  [21:0] dsk_a_q = 22'd0;
    reg         dsk_we_q = 1'b0;
    reg  [15:0] dsk_d_q = 16'd0;
    reg  [15:0] dsk_r_q = 16'd0;
    reg         dsk_ack_q = 1'b0;

    assign dsk_idle  = !dsk_busy;
    assign dsk_ack   = dsk_ack_q;
    assign dsk_rdata = dsk_r_q;

    // The whole image space in the controller's own byte order, so a check can
    // see where a byte landed rather than what went into it.  Big enough to
    // catch a byte written one drive too far.
    reg [7:0] shadow [0:SHADOWB-1];
    integer si;
    initial for (si = 0; si < SHADOWB; si = si + 1) shadow[si] = 8'h00;

    always @(posedge clk) begin
        dsk_ack_q <= 1'b0;
        if (dsk_go) begin
            dsk_busy <= 1'b1;
            dsk_t    <= 4'd0;
            dsk_a_q  <= dsk_addr;
            dsk_we_q <= dsk_we;
            dsk_d_q  <= dsk_wdata;
        end else if (dsk_busy) begin
            dsk_t <= dsk_t + 4'd1;
            if (dsk_t == 4'd7) begin
                dsk_busy  <= 1'b0;
                dsk_ack_q <= 1'b1;
                dsk_r_q   <= {shadow[byte_of(dsk_a_q, 1'b1)],
                              shadow[byte_of(dsk_a_q, 1'b0)]};
                if (dsk_we_q) begin
                    shadow[byte_of(dsk_a_q, 1'b0)] <= dsk_d_q[7:0];
                    shadow[byte_of(dsk_a_q, 1'b1)] <= dsk_d_q[15:8];
                end
            end
        end
    end

    // The byte address a controller word address names, in the same layout
    // tb_disk2 uses: bank 1, then row, column and the half bit.
    function integer byte_of(input [21:0] a, input half);
        begin
            byte_of = ((a[21:20] - 2'd1) * 1048576) + (a[19:9] * 1024) +
                      (a[8:1] * 2) + half;
        end
    endfunction

    disk2_store u_store (
        .clk(clk), .reset(reset),
        .grp_req(1'b0), .grp_off(9'd0), .grp_sec(4'd0), .grp_track(9'd0),
        .grp_drive(1'b0), .grp_val(), .grp_ack(unused_grp_ack),
        .wr_seen(1'b0), .wr_byte(8'h00), .wr_in_data(1'b0), .wr_off(9'd0),
        .wr_sec(4'd0), .wr_track(9'd0), .wr_drive(1'b0),
        .drv_present(drv_present), .drv_writable(drv_writable),
        .up_go(img_up_go), .up_drive(img_up_drive), .up_addr(img_up_addr),
        .up_data(img_up_data), .up_last(img_up_last),
        .up_busy(img_up_busy), .up_done(img_up_done),
        .down_go(img_dn_go), .down_drive(img_dn_drive), .down_addr(img_dn_addr),
        .down_last(img_dn_last), .down_data(img_dn_data),
        .down_valid(img_dn_valid), .down_done(img_dn_done),
        .dbg_present(), .dbg_track(),
        .dsk_go(dsk_go), .dsk_addr(dsk_addr), .dsk_we(dsk_we), .dsk_wdata(dsk_wdata),
        .dsk_rdata(dsk_rdata), .dsk_ack(dsk_ack), .dsk_idle(dsk_idle)
    );

    // ------------------------------------------------------------------
    // The host
    // ------------------------------------------------------------------
    integer checks = 0;
    integer fails  = 0;

    // Shared by the tasks and the initial block, and declared before them because
    // Icarus will not bind a task port to something declared later.
    integer i, bad, outstanding, acks, WINDOW = 16, match, slen;
    reg [7:0] gotb;
    reg [7:0] skipbuf [0:15];

    task check;
        input ok;
        input [8*64-1:0] what;
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin
                fails = fails + 1;
                $display("FAIL: %0s", what);
            end
        end
    endtask

    // The byte the host sends at offset i of an image.  It depends on the offset,
    // so a byte that lands in the wrong place is not the byte that was sent: a
    // constant image would pass with an off-by-one in the address.
    function [7:0] pat(input integer n);
        begin
            pat = ((n * 8'h1D) ^ (n[15:8] ^ n[7:0]) ^ 8'hA5) & 8'hFF;
        end
    endfunction

    task send(input [7:0] b);
        begin
            @(negedge clk);
            rx_byte  = b;
            rx_valid = 1'b1;
            @(negedge clk);
            rx_valid = 1'b0;
        end
    endtask

    task send_cmd(input [7:0] b);
        begin
            send(b);
            repeat (4000) @(posedge clk);
        end
    endtask

    // 115200 8N1 off the pin, least significant bit first, sampled with delays
    // rather than by counting clock edges: at 2,340 clocks a byte the edge-by-edge
    // version spends all its time in the testbench.
    task rx_byte_task(output [7:0] b);
        integer k;
        reg [9:0] sh;
        begin
            while (uart_tx !== 1'b0) @(posedge clk);   // wait for the start bit
            #(37 * 19);                                 // into the middle of it
            sh[0] = uart_tx;
            for (k = 1; k < 10; k = k + 1) begin
                #(37 * 234);
                sh[k] = uart_tx;
            end
            b = sh[1];
            for (k = 1; k < 8; k = k + 1) b[k] = sh[k + 1];
        end
    endtask

    // Everything the board says, in a queue, drained in the background the way a
    // host's reader does.  Reading it only when a test wants it would mean
    // counting lines, and the debugger prints its banner, two prompts and a
    // register dump before the first command does anything.
    reg [7:0] q [0:65535];
    integer q_wr = 0, q_rd = 0;
    reg [7:0] drain_b;

    initial forever begin
        rx_byte_task(drain_b);
        q[q_wr % 65536] = drain_b;
        q_wr = q_wr + 1;
    end

    task getbyte(output [7:0] b);
        begin
            while (q_rd == q_wr) @(posedge clk);
            b = q[q_rd % 65536];
            q_rd = q_rd + 1;
        end
    endtask

    // Throw bytes away until this string has been seen.  Matching the text is
    // what makes this independent of however much the debugger said beforehand.
    task skip_until(input [8*16-1:0] s);
        integer k;
        begin
            slen = 0;
            while (slen < 16 && s[8*slen +: 8] !== 8'h00) slen = slen + 1;
            for (k = 0; k < 16; k = k + 1) skipbuf[k] = 8'h00;
            forever begin
                getbyte(gotb);
                for (k = slen - 1; k > 0; k = k - 1) skipbuf[k] = skipbuf[k - 1];
                skipbuf[0] = gotb;
                match = 1;
                for (k = 0; k < slen; k = k + 1)
                    if (skipbuf[k] !== s[8*(slen - 1 - k) +: 8]) match = 0;
                if (match) disable skip_until;
            end
        end
    endtask

    // Take this string out of the queue, and check it against what came out.
    task expect_str(input [8*16-1:0] s);
        integer n;
        begin
            n = 0;
            while (n < 16 && s[8*n +: 8] !== 8'h00) begin
                getbyte(gotb);
                if (gotb !== s[8*n +: 8]) begin
                    fails = fails + 1;
                    $display("FAIL: expected %02x, got %02x, at %0d of the string",
                             s[8*n +: 8], gotb, n);
                end
                checks = checks + 1;
                n = n + 1;
            end
        end
    endtask

    task skip_to_eol;
        begin
            forever begin
                getbyte(gotb);
                if (gotb === 8'h0A) disable skip_to_eol;
            end
        end
    endtask

    // An upload, the way a host has to do it: two bytes in, one acknowledgement
    // out, with a window of bytes in flight so the link is never idle waiting for
    // a round trip.  The window is the whole protocol: the board has room for one
    // byte in hand, so a host that ignores the acks and blasts the file has its
    // bytes dropped in the middle and ends up with an image the board believes in.
    task upload(input integer drive, input integer count, input [7:0] xor_mask);
        begin
            send_cmd("d");
            send_cmd(drive == 0 ? "1" : "2");
            skip_until("UPLOAD");
            skip_to_eol;
            outstanding = 0;
            for (i = 0; i < count; i = i + 1) begin
                send(pat(i) ^ xor_mask);
                outstanding = outstanding + 1;
                while (outstanding >= WINDOW) begin
                    getbyte(gotb);
                    if (gotb === 8'h06) begin
                        outstanding = outstanding - 2;
                        acks        = acks + 1;
                    end
                end
            end
            // The acknowledgements for the bytes still in the window.  There is
            // one for every two bytes sent, so with an even number of bytes this
            // ends on zero.
            while (outstanding > 0) begin
                getbyte(gotb);
                if (gotb === 8'h06) begin
                    outstanding = outstanding - 2;
                    acks        = acks + 1;
                end
            end
            expect_str("\r\ndone\r\n");
        end
    endtask

    // ------------------------------------------------------------------
    // The tests
    // ------------------------------------------------------------------
    initial begin
        reset = 1'b1;
        rx_byte = 8'h00;
        rx_valid = 1'b0;
        repeat (8) @(posedge clk);
        reset = 1'b0;
        repeat (8) @(posedge clk);

        // ==============================================================
        // 1. Enter the debugger and look at the drives
        // ==============================================================
        send_cmd(8'h02);
        check(dbg_mode === 1'b1, "Ctrl+B entered the debugger");
        skip_until("Debugger");

        // Before anything is uploaded, neither drive holds an image, so both read
        // as write protected: this is what stops a format going nowhere.
        check(drv_present === 2'b00, "no drive holds an image before an upload");
        check(drv_writable === 2'b00, "an empty drive is write protected");

        // ==============================================================
        // 2. A whole image into drive 2
        // ==============================================================
        acks = 0;
        upload(1, IMG_BYTES, 8'h00);

        check(acks == IMG_BYTES / 2, "one acknowledgement for every two bytes sent");
        check(drv_present[1] === 1'b1, "drive 2 holds an image after a full upload");
        check(drv_present[0] === 1'b0, "an upload to drive 2 does not fill drive 1");
        check(drv_writable[1] === 1'b1, "a drive with an image is writable");

        // The image itself, read out of the SDRAM model rather than back down the
        // wire: the upload's own check is the acknowledgements above, and this one
        // says where the bytes landed.
        bad = 0;
        for (i = 0; i < IMG_BYTES; i = i + 1)
            if (shadow[IMG_BYTES + i] !== pat(i)) bad = bad + 1;
        check(bad == 0, "drive 2's image is byte for byte what was sent");

        // Nothing may have landed outside the drive.  The first IMG_BYTES bytes
        // are drive 1's image, which nothing was sent for.
        bad = 0;
        for (i = 0; i < IMG_BYTES; i = i + 1)
            if (shadow[i] !== 8'h00) bad = bad + 1;
        check(bad == 0, "an upload to drive 2 does not spill into drive 1");

        // ==============================================================
        // 3. Download it again and compare with what went in
        // ==============================================================
        // A download is 143,360 bytes out of the pin at 115200, which is 2,340
        // clocks a byte -- 335 million of them.  So the wire check covers the
        // first DL_BYTES of the image rather than all of it, and the whole image's
        // contents are checked above, through the SDRAM.  What the wire is here
        // for is the *order*: the store's word cache, and which half of a word it
        // takes the byte from, only show up on the way out.
        send_cmd("e2");
        skip_until("DOWNLOAD");
        skip_to_eol;
        bad = 0;
        for (i = 0; i < DL_BYTES; i = i + 1) begin
            getbyte(gotb);
            if (gotb !== pat(i)) bad = bad + 1;
        end
        check(bad == 0, "the download gives back the image that was uploaded");

        // ==============================================================
        // 4. A cut-short upload must not leave a usable drive
        // ==============================================================
        // Checked on drive 1, which is still empty: a link that drops half way
        // through has to leave a drive that reads as empty, because "empty" is
        // the one thing the card will not boot or format.
        send_cmd("d1");
        skip_until("UPLOAD");
        skip_to_eol;
        for (i = 0; i < 64; i = i + 1) send(pat(i));
        repeat (400) @(posedge clk);
        check(drv_present[0] === 1'b0, "a cut-short upload leaves the drive empty");
        check(drv_writable[0] === 1'b0, "a cut-short upload leaves it write protected");

        // ==============================================================
        // 5. A second upload, all the way, and both drives checked
        // ==============================================================
        acks = 0;
        upload(0, IMG_BYTES, 8'h5A);

        check(drv_present[0] === 1'b1, "d1 fills drive 1");
        check(drv_present[1] === 1'b1, "d1 leaves drive 2 alone");

        bad = 0;
        for (i = 0; i < IMG_BYTES; i = i + 1) begin
            if (shadow[i]             !== (pat(i) ^ 8'h5A)) bad = bad + 1;
            if (shadow[IMG_BYTES + i] !== pat(i))             bad = bad + 1;
        end
        check(bad == 0, "both drives hold their own image");

        if (fails == 0)
            $display("tb_diskimg: PASS (%0d checks)", checks);
        else
            $display("tb_diskimg: FAIL (%0d of %0d checks failed)", fails, checks);
        $finish;
    end

    // A watchdog, so a handshake that never completes says so instead of running
    // until the heat death of the universe.
    initial begin
        #2000000000;
        $display("tb_diskimg: FAIL (watchdog)");
        $finish;
    end

endmodule
