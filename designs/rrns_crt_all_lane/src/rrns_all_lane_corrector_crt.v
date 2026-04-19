`timescale 1ns/1ps
module rrns_all_lane_corrector_crt #(
    parameter W0        = 2,
    parameter W1        = 3,
    parameter W2        = 3,
    parameter W3        = 4,
    parameter W4        = 4,
    parameter W5        = 5,
    parameter OUT_WIDTH = 16
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          Correct_Start,

    input  wire signed [OUT_WIDTH-1:0]   X_base,

    input  wire signed [W0-1:0]          r0,
    input  wire signed [W1-1:0]          r1,
    input  wire signed [W2-1:0]          r2,
    input  wire signed [W3-1:0]          r3,
    input  wire signed [W4-1:0]          r4, // mod 13
    input  wire signed [W5-1:0]          r5, // mod 17

    output reg  signed [OUT_WIDTH-1:0]   X_corr,
    output reg                           Error_Detected,
    output reg                           Corrected,
    output reg                           Valid,
    output reg                           Correct_Done
);

    localparam integer M_BASE    = 1155;
    localparam integer HALF_BASE = M_BASE / 2;   // 577

    localparam [1:0]
        S_IDLE  = 2'd0,
        S_QUICK = 2'd1,
        S_EVAL  = 2'd2,
        S_FINAL = 2'd3;

    reg [1:0] state;
    reg       start_d;
    wire      start_pulse = Correct_Start & ~start_d;

    reg signed [OUT_WIDTH-1:0] x_base_r;
    integer n0_r, n1_r, n2_r, n3_r, n4_r, n5_r;
    reg     chk13_r, chk17_r;

    reg [1:0] eval_lane_r;
    reg       winner_seen_r;
    reg       multi_winner_r;
    reg [1:0] winner_lane_r;
    reg signed [OUT_WIDTH-1:0] winner_value_r;

    integer cand13_w, cand17_w;
    reg     ok13_w, ok17_w, accept_w;

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

    function integer center_with_modulus;
        input integer x;
        input integer p;
        integer t;
        begin
            t = norm_mod(x, p);
            if (t > (p / 2))
                center_with_modulus = t - p;
            else
                center_with_modulus = t;
        end
    endfunction

    function integer in_base_range;
        input integer x;
        begin
            in_base_range = (x >= -HALF_BASE) && (x <= HALF_BASE);
        end
    endfunction

    function integer red_ok;
        input integer x;
        input integer r;
        input integer m;
        begin
            red_ok = (norm_mod(x, m) == norm_mod(r, m));
        end
    endfunction

    function integer lane_cand13;
        input [1:0] lane;
        input integer n0;
        input integer n1;
        input integer n2;
        input integer n3;
        input integer n4;
        begin
            case (lane)
                2'd0: lane_cand13 = center_with_modulus(
                    (n1*1001*1 + n2*715*1 + n3*455*3 + n4*385*5), 5005
                ); // [5,7,11,13]

                2'd1: lane_cand13 = center_with_modulus(
                    (n0*1001*2 + n2*429*4 + n3*273*5 + n4*231*4), 3003
                ); // [3,7,11,13]

                2'd2: lane_cand13 = center_with_modulus(
                    (n0*715*1 + n1*429*4 + n3*195*7 + n4*165*3), 2145
                ); // [3,5,11,13]

                default: lane_cand13 = center_with_modulus(
                    (n0*455*2 + n1*273*2 + n2*195*6 + n4*105*1), 1365
                ); // [3,5,7,13]
            endcase
        end
    endfunction

    function integer lane_cand17;
        input [1:0] lane;
        input integer n0;
        input integer n1;
        input integer n2;
        input integer n3;
        input integer n5;
        begin
            case (lane)
                2'd0: lane_cand17 = center_with_modulus(
                    (n1*1309*4 + n2*935*2 + n3*595*1 + n5*385*14), 6545
                ); // [5,7,11,17]

                2'd1: lane_cand17 = center_with_modulus(
                    (n0*1309*1 + n2*561*1 + n3*357*9 + n5*231*12), 3927
                ); // [3,7,11,17]

                2'd2: lane_cand17 = center_with_modulus(
                    (n0*935*2 + n1*561*1 + n3*255*6 + n5*165*10), 2805
                ); // [3,5,11,17]

                default: lane_cand17 = center_with_modulus(
                    (n0*595*1 + n1*357*3 + n2*255*5 + n5*105*6), 1785
                ); // [3,5,7,17]
            endcase
        end
    endfunction

    always @* begin
        cand13_w = lane_cand13(eval_lane_r, n0_r, n1_r, n2_r, n3_r, n4_r);
        cand17_w = lane_cand17(eval_lane_r, n0_r, n1_r, n2_r, n3_r, n5_r);

        ok13_w   = red_ok(cand13_w, n5_r, 17) && in_base_range(cand13_w);
        ok17_w   = red_ok(cand17_w, n4_r, 13) && in_base_range(cand17_w);
        accept_w = ok13_w && ok17_w && (cand13_w == cand17_w);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            start_d        <= 1'b0;
            Correct_Done   <= 1'b0;
            X_corr         <= '0;
            Error_Detected <= 1'b0;
            Corrected      <= 1'b0;
            Valid          <= 1'b0;

            x_base_r       <= '0;
            n0_r           <= 0;
            n1_r           <= 0;
            n2_r           <= 0;
            n3_r           <= 0;
            n4_r           <= 0;
            n5_r           <= 0;
            chk13_r        <= 1'b0;
            chk17_r        <= 1'b0;

            eval_lane_r    <= 2'd0;
            winner_seen_r  <= 1'b0;
            multi_winner_r <= 1'b0;
            winner_lane_r  <= 2'd0;
            winner_value_r <= '0;
        end else begin
            start_d      <= Correct_Start;
            Correct_Done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_pulse) begin
                        x_base_r       <= X_base;
                        n0_r           <= norm_mod(r0, 3);
                        n1_r           <= norm_mod(r1, 5);
                        n2_r           <= norm_mod(r2, 7);
                        n3_r           <= norm_mod(r3, 11);
                        n4_r           <= norm_mod(r4, 13);
                        n5_r           <= norm_mod(r5, 17);
                        chk13_r        <= red_ok(X_base, norm_mod(r4, 13), 13);
                        chk17_r        <= red_ok(X_base, norm_mod(r5, 17), 17);
                        eval_lane_r    <= 2'd0;
                        winner_seen_r  <= 1'b0;
                        multi_winner_r <= 1'b0;
                        winner_lane_r  <= 2'd0;
                        winner_value_r <= '0;
                        state          <= S_QUICK;
                    end
                end

                S_QUICK: begin
                    if (chk13_r && chk17_r) begin
                        X_corr         <= x_base_r;
                        Error_Detected <= 1'b0;
                        Corrected      <= 1'b0;
                        Valid          <= 1'b1;
                        Correct_Done   <= 1'b1;
                        state          <= S_IDLE;
                    end else if (chk13_r ^ chk17_r) begin
                        X_corr         <= x_base_r;
                        Error_Detected <= 1'b1;
                        Corrected      <= 1'b1;
                        Valid          <= 1'b1;
                        Correct_Done   <= 1'b1;
                        state          <= S_IDLE;
                    end else begin
                        state <= S_EVAL;
                    end
                end

                S_EVAL: begin
                    if (accept_w) begin
                        if (!winner_seen_r) begin
                            winner_seen_r  <= 1'b1;
                            winner_lane_r  <= eval_lane_r;
                            winner_value_r <= cand13_w[OUT_WIDTH-1:0];
                        end else begin
                            multi_winner_r <= 1'b1;
                        end
                    end

                    if (eval_lane_r == 2'd3) begin
                        state <= S_FINAL;
                    end else begin
                        eval_lane_r <= eval_lane_r + 2'd1;
                    end
                end

                S_FINAL: begin
                    if (winner_seen_r && !multi_winner_r) begin
                        X_corr         <= winner_value_r;
                        Error_Detected <= 1'b1;
                        Corrected      <= 1'b1;
                        Valid          <= 1'b1;
                    end else begin
                        X_corr         <= x_base_r;
                        Error_Detected <= 1'b1;
                        Corrected      <= 1'b0;
                        Valid          <= 1'b0;
                    end
                    Correct_Done <= 1'b1;
                    state        <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
