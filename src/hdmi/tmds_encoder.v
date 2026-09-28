// Pipelined DVI 8b/10b TMDS Encoder
// High performance 2-stage pipelined architecture with clean timing closure

module tmds_encoder (
    input  wire       clk,
    input  wire [7:0] din,
    input  wire [1:0] c,
    input  wire       de,
    output reg  [9:0] dout
);

    // ==========================================
    // Stage 1: Transition minimization (q_m)
    // ==========================================
    wire [3:0] num_ones = din[0] + din[1] + din[2] + din[3] +
                          din[4] + din[5] + din[6] + din[7];

    wire use_xnor = (num_ones > 4'd4) || (num_ones == 4'd4 && din[0] == 1'b0);

    wire [8:0] q_m_comb;
    assign q_m_comb[0] = din[0];
    assign q_m_comb[1] = use_xnor ? ~(q_m_comb[0] ^ din[1]) : (q_m_comb[0] ^ din[1]);
    assign q_m_comb[2] = use_xnor ? ~(q_m_comb[1] ^ din[2]) : (q_m_comb[1] ^ din[2]);
    assign q_m_comb[3] = use_xnor ? ~(q_m_comb[2] ^ din[3]) : (q_m_comb[2] ^ din[3]);
    assign q_m_comb[4] = use_xnor ? ~(q_m_comb[3] ^ din[4]) : (q_m_comb[3] ^ din[4]);
    assign q_m_comb[5] = use_xnor ? ~(q_m_comb[4] ^ din[5]) : (q_m_comb[4] ^ din[5]);
    assign q_m_comb[6] = use_xnor ? ~(q_m_comb[5] ^ din[6]) : (q_m_comb[5] ^ din[6]);
    assign q_m_comb[7] = use_xnor ? ~(q_m_comb[6] ^ din[7]) : (q_m_comb[6] ^ din[7]);
    assign q_m_comb[8] = ~use_xnor;

    // Pipeline registers between Stage 1 and Stage 2
    reg [8:0] q_m;
    reg [3:0] q_m_ones;
    reg [1:0] c_reg;
    reg       de_reg;

    always @(posedge clk) begin
        q_m      <= q_m_comb;
        q_m_ones <= q_m_comb[0] + q_m_comb[1] + q_m_comb[2] + q_m_comb[3] +
                    q_m_comb[4] + q_m_comb[5] + q_m_comb[6] + q_m_comb[7];
        c_reg    <= c;
        de_reg   <= de;
    end

    // ==========================================
    // Stage 2: DC Balance & Disparity tracking
    // ==========================================
    wire signed [4:0] q_m_disp = {1'b0, q_m_ones} - (5'd8 - {1'b0, q_m_ones});
    reg  signed [4:0] disparity = 5'sd0;

    always @(posedge clk) begin
        if (!de_reg) begin
            disparity <= 5'sd0;
            case (c_reg)
                2'b00:   dout <= 10'b1101010100;
                2'b01:   dout <= 10'b0010101011;
                2'b10:   dout <= 10'b0101010100;
                default: dout <= 10'b1010101011;
            endcase
        end else begin
            if (disparity == 5'sd0 || q_m_disp == 5'sd0) begin
                if (q_m[8]) begin
                    dout <= {2'b01, q_m[7:0]};
                    disparity <= disparity + q_m_disp;
                end else begin
                    dout <= {2'b10, ~q_m[7:0]};
                    disparity <= disparity - q_m_disp;
                end
            end else if ((disparity > 0 && q_m_disp > 0) || (disparity < 0 && q_m_disp < 0)) begin
                dout <= {1'b1, q_m[8], ~q_m[7:0]};
                disparity <= disparity + {q_m[8], 1'b0} - q_m_disp;
            end else begin
                dout <= {1'b0, q_m[8], q_m[7:0]};
                disparity <= disparity - {~q_m[8], 1'b0} + q_m_disp;
            end
        end
    end

endmodule
