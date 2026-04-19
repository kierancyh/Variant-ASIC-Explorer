`timescale 1ns/1ps
module rrns_all_lane_corrector_mrc #(
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
    input  wire signed [W4-1:0]          r4,
    input  wire signed [W5-1:0]          r5,

    output reg  signed [W0-1:0]          corr_r0,
    output reg  signed [W1-1:0]          corr_r1,
    output reg  signed [W2-1:0]          corr_r2,
    output reg  signed [W3-1:0]          corr_r3,
    output reg                           Error_Detected,
    output reg                           Corrected,
    output reg                           Valid,
    output reg                           Correct_Done
);

    localparam integer M0        = 3;
    localparam integer M1        = 5;
    localparam integer M2        = 7;
    localparam integer M3        = 11;
    localparam integer M4        = 13;
    localparam integer M5        = 17;
    localparam integer M_BASE    = 1155;
    localparam integer HALF_BASE = M_BASE / 2;

    localparam [2:0]
        S_IDLE    = 3'd0,
        S_PREP    = 3'd1,
        S_EVAL_A  = 3'd2,
        S_EVAL_B  = 3'd3,
        S_RESOLVE = 3'd4,
        S_DONE    = 3'd5;

    reg [2:0] state;

    reg start_d;
    wire start_pulse = Correct_Start & ~start_d;

    reg [1:0] lane_idx_r;
    reg       winner_found_r;
    reg       conflict_found_r;
    reg [1:0] winner_lane_r;
    reg [3:0] winner_res_r;

    reg [1:0] n0_r;
    reg [2:0] n1_r;
    reg [2:0] n2_r;
    reg [3:0] n3_r;
    reg [3:0] n4_r;
    reg [4:0] n5_r;

    reg       chk13_r;
    reg       chk17_r;

    reg signed [13:0] cand_a_x_r;
    reg               cand_a_ok_r;

    reg signed [13:0] cand_x_w;
    reg               cand_ok_w;
    reg [3:0]         cand_res_w;

    integer x_base_int;

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

    function integer candidate_x;
        input [1:0] lane;
        input       use_red17;
        input integer n0;
        input integer n1;
        input integer n2;
        input integer n3;
        input integer n4;
        input integer n5;
        begin
            case (lane)
                2'd0: begin
                    if (!use_red17)
                        candidate_x = center_with_modulus(
                            (n1*1001*1 + n2*715*1 + n3*455*3 + n4*385*5), 5005
                        );
                    else
                        candidate_x = center_with_modulus(
                            (n1*1309*4 + n2*935*2 + n3*595*1 + n5*385*14), 6545
                        );
                end

                2'd1: begin
                    if (!use_red17)
                        candidate_x = center_with_modulus(
                            (n0*1001*2 + n2*429*4 + n3*273*5 + n4*231*4), 3003
                        );
                    else
                        candidate_x = center_with_modulus(
                            (n0*1309*1 + n2*561*1 + n3*357*9 + n5*231*12), 3927
                        );
                end

                2'd2: begin
                    if (!use_red17)
                        candidate_x = center_with_modulus(
                            (n0*715*1 + n1*429*4 + n3*195*7 + n4*165*3), 2145
                        );
                    else
                        candidate_x = center_with_modulus(
                            (n0*935*2 + n1*561*1 + n3*255*6 + n5*165*10), 2805
                        );
                end

                default: begin
                    if (!use_red17)
                        candidate_x = center_with_modulus(
                            (n0*455*2 + n1*273*2 + n2*195*6 + n4*105*1), 1365
                        );
                    else
                        candidate_x = center_with_modulus(
                            (n0*595*1 + n1*357*3 + n2*255*5 + n5*105*6), 1785
                        );
                end
            endcase
        end
    endfunction

    always @* begin
        cand_x_w  = candidate_x(lane_idx_r, (state == S_EVAL_B), n0_r, n1_r, n2_r, n3_r, n4_r, n5_r);
        cand_ok_w = 1'b0;
        cand_res_w = 4'd0;

        if (state == S_EVAL_A) begin
            cand_ok_w = red_ok(cand_x_w, n5_r, M5) && in_base_range(cand_x_w);
        end else if (state == S_EVAL_B) begin
            cand_ok_w = red_ok(cand_x_w, n4_r, M4) && in_base_range(cand_x_w);
        end

        case (lane_idx_r)
            2'd0: cand_res_w = norm_mod(cand_x_w, M0);
            2'd1: cand_res_w = norm_mod(cand_x_w, M1);
            2'd2: cand_res_w = norm_mod(cand_x_w, M2);
            default: cand_res_w = norm_mod(cand_x_w, M3);
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            start_d        <= 1'b0;
            Correct_Done   <= 1'b0;

            corr_r0        <= '0;
            corr_r1        <= '0;
            corr_r2        <= '0;
            corr_r3        <= '0;
            Error_Detected <= 1'b0;
            Corrected      <= 1'b0;
            Valid          <= 1'b0;

            lane_idx_r      <= 2'd0;
            winner_found_r  <= 1'b0;
            conflict_found_r<= 1'b0;
            winner_lane_r   <= 2'd0;
            winner_res_r    <= 4'd0;
            cand_a_x_r      <= '0;
            cand_a_ok_r     <= 1'b0;
        end else begin
            start_d      <= Correct_Start;
            Correct_Done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_pulse) begin
                        n0_r <= norm_mod(r0, M0);
                        n1_r <= norm_mod(r1, M1);
                        n2_r <= norm_mod(r2, M2);
                        n3_r <= norm_mod(r3, M3);
                        n4_r <= norm_mod(r4, M4);
                        n5_r <= norm_mod(r5, M5);

                        corr_r0 <= r0;
                        corr_r1 <= r1;
                        corr_r2 <= r2;
                        corr_r3 <= r3;

                        winner_found_r   <= 1'b0;
                        conflict_found_r <= 1'b0;
                        winner_lane_r    <= 2'd0;
                        winner_res_r     <= 4'd0;
                        lane_idx_r       <= 2'd0;
                        state            <= S_PREP;
                    end
                end

                S_PREP: begin
                    x_base_int <= X_base;
                    chk13_r    <= red_ok(X_base, n4_r, M4);
                    chk17_r    <= red_ok(X_base, n5_r, M5);

                    if (red_ok(X_base, n4_r, M4) && red_ok(X_base, n5_r, M5)) begin
                        corr_r0        <= r0;
                        corr_r1        <= r1;
                        corr_r2        <= r2;
                        corr_r3        <= r3;
                        Error_Detected <= 1'b0;
                        Corrected      <= 1'b0;
                        Valid          <= 1'b1;
                        state          <= S_DONE;
                    end else if (red_ok(X_base, n4_r, M4) ^ red_ok(X_base, n5_r, M5)) begin
                        corr_r0        <= r0;
                        corr_r1        <= r1;
                        corr_r2        <= r2;
                        corr_r3        <= r3;
                        Error_Detected <= 1'b1;
                        Corrected      <= 1'b1;
                        Valid          <= 1'b1;
                        state          <= S_DONE;
                    end else begin
                        Error_Detected  <= 1'b1;
                        Corrected       <= 1'b0;
                        Valid           <= 1'b0;
                        lane_idx_r      <= 2'd0;
                        winner_found_r  <= 1'b0;
                        conflict_found_r<= 1'b0;
                        state           <= S_EVAL_A;
                    end
                end

                S_EVAL_A: begin
                    cand_a_x_r  <= cand_x_w;
                    cand_a_ok_r <= cand_ok_w;
                    state       <= S_EVAL_B;
                end

                S_EVAL_B: begin
                    if (cand_a_ok_r && cand_ok_w && (cand_a_x_r == cand_x_w)) begin
                        if (!winner_found_r) begin
                            winner_found_r <= 1'b1;
                            winner_lane_r  <= lane_idx_r;
                            winner_res_r   <= cand_res_w;
                        end else begin
                            conflict_found_r <= 1'b1;
                        end
                    end

                    if (conflict_found_r || (winner_found_r && cand_a_ok_r && cand_ok_w && (cand_a_x_r == cand_x_w))) begin
                        if (winner_found_r)
                            state <= S_RESOLVE;
                        else if (cand_a_ok_r && cand_ok_w && (cand_a_x_r == cand_x_w))
                            state <= S_RESOLVE;
                        else
                            state <= S_RESOLVE;
                    end else if (lane_idx_r == 2'd3) begin
                        state <= S_RESOLVE;
                    end else begin
                        lane_idx_r <= lane_idx_r + 2'd1;
                        state      <= S_EVAL_A;
                    end
                end

                S_RESOLVE: begin
                    corr_r0 <= r0;
                    corr_r1 <= r1;
                    corr_r2 <= r2;
                    corr_r3 <= r3;

                    if (!winner_found_r || conflict_found_r) begin
                        Error_Detected <= 1'b1;
                        Corrected      <= 1'b0;
                        Valid          <= 1'b0;
                    end else begin
                        Error_Detected <= 1'b1;
                        Corrected      <= 1'b1;
                        Valid          <= 1'b1;

                        case (winner_lane_r)
                            2'd0: corr_r0 <= center_with_modulus(winner_res_r, M0);
                            2'd1: corr_r1 <= center_with_modulus(winner_res_r, M1);
                            2'd2: corr_r2 <= center_with_modulus(winner_res_r, M2);
                            default: corr_r3 <= center_with_modulus(winner_res_r, M3);
                        endcase
                    end
                    state <= S_DONE;
                end

                S_DONE: begin
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
