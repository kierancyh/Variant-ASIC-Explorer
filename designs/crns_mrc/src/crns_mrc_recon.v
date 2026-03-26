`timescale 1ns/1ps
module crns_mrc_recon #(
    parameter W0        = 2,   // modulus 3
    parameter W1        = 3,   // modulus 5
    parameter W2        = 3,   // modulus 7
    parameter W3        = 4,   // modulus 11
    parameter OUT_WIDTH = 16
)(
    input  wire                          clk,
    input  wire                          rst_n,

    input  wire                          MRC_Start,

    input  wire signed [W0-1:0]          r0,
    input  wire signed [W1-1:0]          r1,
    input  wire signed [W2-1:0]          r2,
    input  wire signed [W3-1:0]          r3,

    output reg  signed [OUT_WIDTH-1:0]   X_out,
    output reg                           MRC_Done
);

    // Moduli
    localparam integer MOD0      = 3;
    localparam integer MOD1      = 5;
    localparam integer MOD2      = 7;
    localparam integer MOD3      = 11;

    // Progressive products
    localparam integer MPREV1    = 3;      // 3
    localparam integer MPREV2    = 15;     // 3*5
    localparam integer MPREV3    = 105;    // 3*5*7
    localparam integer M_TOTAL   = 1155;   // 3*5*7*11
    localparam integer HALF_M    = M_TOTAL / 2;  // 577

    // Precomputed inverses
    // inv(3 mod 5)     = 2
    // inv(15 mod 7)    = 1
    // inv(105 mod 11)  = 2
    localparam integer INV_12    = 2;
    localparam integer INV_123   = 1;
    localparam integer INV_1234  = 2;

    // FSM states
    localparam [2:0]
        S_IDLE = 3'd0,
        S_S1   = 3'd1,
        S_S2   = 3'd2,
        S_S3   = 3'd3,
        S_S4   = 3'd4,
        S_DONE = 3'd5;

    reg [2:0] state;

    // Start edge detect
    reg start_d;
    wire start_pulse = MRC_Start & ~start_d;

    // Latched normalized residues (standard representatives, internal only)
    integer r0_mod_r, r1_mod_r, r2_mod_r, r3_mod_r;

    // Intermediate registers
    integer X1_r, X2_r, X3_r;
    integer t2, t3, t4;
    integer X4;
    integer total_mod;
    integer total_centered;

    // Integer normalizer: maps any integer into [0 .. m-1]
    function integer norm_mod;
        input integer x;
        input integer m;
        integer t;
        begin
            t = x % m;
            if (t < 0)
                t = t + m;
            norm_mod = t;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            start_d        <= 1'b0;

            r0_mod_r       <= 0;
            r1_mod_r       <= 0;
            r2_mod_r       <= 0;
            r3_mod_r       <= 0;

            X1_r           <= 0;
            X2_r           <= 0;
            X3_r           <= 0;

            X_out          <= {OUT_WIDTH{1'b0}};
            MRC_Done       <= 1'b0;
        end else begin
            start_d  <= MRC_Start;
            MRC_Done <= 1'b0; // one-cycle pulse only in S_DONE

            case (state)
                S_IDLE: begin
                    if (start_pulse) begin
                        // Accept centered residues directly and normalize only internally
                        r0_mod_r <= norm_mod(r0, MOD0);
                        r1_mod_r <= norm_mod(r1, MOD1);
                        r2_mod_r <= norm_mod(r2, MOD2);
                        r3_mod_r <= norm_mod(r3, MOD3);
                        state    <= S_S1;
                    end
                end

                // Stage 1
                // X1 = r0 (mod 3)
                S_S1: begin
                    X1_r  <= r0_mod_r;
                    state <= S_S2;
                end

                // Stage 2
                // t2 = ((r1 - (X1 mod 5)) * inv(3 mod 5)) mod 5
                // X2 = X1 + t2*3
                S_S2: begin
                    t2 = r1_mod_r - norm_mod(X1_r, MOD1);
                    t2 = norm_mod(t2, MOD1);
                    t2 = norm_mod(t2 * INV_12, MOD1);

                    X2_r  <= X1_r + t2 * MPREV1;
                    state <= S_S3;
                end

                // Stage 3
                // t3 = ((r2 - (X2 mod 7)) * inv(15 mod 7)) mod 7
                // X3 = X2 + t3*15
                S_S3: begin
                    t3 = r2_mod_r - norm_mod(X2_r, MOD2);
                    t3 = norm_mod(t3, MOD2);
                    t3 = norm_mod(t3 * INV_123, MOD2);

                    X3_r  <= X2_r + t3 * MPREV2;
                    state <= S_S4;
                end

                // Stage 4
                // t4 = ((r3 - (X3 mod 11)) * inv(105 mod 11)) mod 11
                // X4 = X3 + t4*105
                // Then map final result to centered representative
                S_S4: begin
                    t4 = r3_mod_r - norm_mod(X3_r, MOD3);
                    t4 = norm_mod(t4, MOD3);
                    t4 = norm_mod(t4 * INV_1234, MOD3);

                    X4 = X3_r + t4 * MPREV3;

                    total_mod = norm_mod(X4, M_TOTAL);

                    if (total_mod > HALF_M)
                        total_centered = total_mod - M_TOTAL;
                    else
                        total_centered = total_mod;

                    X_out <= total_centered;
                    state <= S_DONE;
                end

                // Done pulse
                S_DONE: begin
                    MRC_Done <= 1'b1;
                    state    <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule