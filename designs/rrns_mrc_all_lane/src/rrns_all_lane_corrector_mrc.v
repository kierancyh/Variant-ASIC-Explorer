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

    localparam [3:0]
        S_IDLE     = 4'd0,
        S_PREP     = 4'd1,
        S_LOAD13   = 4'd2,
        S_PRED13   = 4'd3,
        S_LOAD17   = 4'd4,
        S_PRED17   = 4'd5,
        S_COMPARE  = 4'd6,
        S_RESOLVE  = 4'd7,
        S_DONE     = 4'd8;

    reg [3:0] state;

    reg       start_d;
    wire      start_pulse = Correct_Start & ~start_d;

    reg [1:0] lane_idx_r;
    reg       winner_found_r;
    reg       conflict_found_r;
    reg [1:0] winner_lane_r;
    reg [3:0] winner_res_r;

    reg [1:0] n0_r;
    reg [2:0] n1_r;
    reg [2:0] n2_r;
    reg [3:0] n3_r;

    reg       chk13_r;
    reg       chk17_r;

    reg [4:0] src_ref_r;
    reg [4:0] verify_ref_r;

    reg signed [13:0] cand13_x_r;
    reg               cand13_ok_r;
    reg [3:0]         cand13_res_r;

    reg signed [13:0] cand17_x_r;
    reg               cand17_ok_r;
    reg [3:0]         cand17_res_r;

    integer accept_now;

    function integer norm_mod_int;
        input integer x;
        input integer m;
        integer t;
        begin
            t = x % m;
            if (t < 0)
                t = t + m;
            norm_mod_int = t;
        end
    endfunction

    function integer center_with_modulus;
        input integer x;
        input integer p;
        integer t;
        begin
            t = norm_mod_int(x, p);
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
            red_ok = (norm_mod_int(x, m) == norm_mod_int(r, m));
        end
    endfunction

    function [1:0] canon_r0;
        input signed [W0-1:0] x;
        begin
            case ($signed(x))
                -1: canon_r0 = 2'd2;
                 0: canon_r0 = 2'd0;
                 1: canon_r0 = 2'd1;
                default: canon_r0 = norm_mod_int($signed(x), M0);
            endcase
        end
    endfunction

    function [2:0] canon_r1;
        input signed [W1-1:0] x;
        begin
            case ($signed(x))
                -2: canon_r1 = 3'd3;
                -1: canon_r1 = 3'd4;
                 0: canon_r1 = 3'd0;
                 1: canon_r1 = 3'd1;
                 2: canon_r1 = 3'd2;
                default: canon_r1 = norm_mod_int($signed(x), M1);
            endcase
        end
    endfunction

    function [2:0] canon_r2;
        input signed [W2-1:0] x;
        begin
            case ($signed(x))
                -3: canon_r2 = 3'd4;
                -2: canon_r2 = 3'd5;
                -1: canon_r2 = 3'd6;
                 0: canon_r2 = 3'd0;
                 1: canon_r2 = 3'd1;
                 2: canon_r2 = 3'd2;
                 3: canon_r2 = 3'd3;
                default: canon_r2 = norm_mod_int($signed(x), M2);
            endcase
        end
    endfunction

    function [3:0] canon_r3;
        input signed [W3-1:0] x;
        begin
            case ($signed(x))
                -5: canon_r3 = 4'd6;
                -4: canon_r3 = 4'd7;
                -3: canon_r3 = 4'd8;
                -2: canon_r3 = 4'd9;
                -1: canon_r3 = 4'd10;
                 0: canon_r3 = 4'd0;
                 1: canon_r3 = 4'd1;
                 2: canon_r3 = 4'd2;
                 3: canon_r3 = 4'd3;
                 4: canon_r3 = 4'd4;
                 5: canon_r3 = 4'd5;
                default: canon_r3 = norm_mod_int($signed(x), M3);
            endcase
        end
    endfunction

    function [3:0] canon_r4;
        input signed [W4-1:0] x;
        begin
            case ($signed(x))
                -6: canon_r4 = 4'd7;
                -5: canon_r4 = 4'd8;
                -4: canon_r4 = 4'd9;
                -3: canon_r4 = 4'd10;
                -2: canon_r4 = 4'd11;
                -1: canon_r4 = 4'd12;
                 0: canon_r4 = 4'd0;
                 1: canon_r4 = 4'd1;
                 2: canon_r4 = 4'd2;
                 3: canon_r4 = 4'd3;
                 4: canon_r4 = 4'd4;
                 5: canon_r4 = 4'd5;
                 6: canon_r4 = 4'd6;
                default: canon_r4 = norm_mod_int($signed(x), M4);
            endcase
        end
    endfunction

    function [4:0] canon_r5;
        input signed [W5-1:0] x;
        begin
            case ($signed(x))
                -8: canon_r5 = 5'd9;
                -7: canon_r5 = 5'd10;
                -6: canon_r5 = 5'd11;
                -5: canon_r5 = 5'd12;
                -4: canon_r5 = 5'd13;
                -3: canon_r5 = 5'd14;
                -2: canon_r5 = 5'd15;
                -1: canon_r5 = 5'd16;
                 0: canon_r5 = 5'd0;
                 1: canon_r5 = 5'd1;
                 2: canon_r5 = 5'd2;
                 3: canon_r5 = 5'd3;
                 4: canon_r5 = 5'd4;
                 5: canon_r5 = 5'd5;
                 6: canon_r5 = 5'd6;
                 7: canon_r5 = 5'd7;
                 8: canon_r5 = 5'd8;
                default: canon_r5 = norm_mod_int($signed(x), M5);
            endcase
        end
    endfunction

    function integer candidate_x_13;
        input [1:0] lane;
        input integer n0;
        input integer n1;
        input integer n2;
        input integer n3;
        input integer ref13;
        begin
            case (lane)
                2'd0: candidate_x_13 = center_with_modulus(
                    (n1*1001*1 + n2*715*1 + n3*455*3 + ref13*385*5), 5005
                );
                2'd1: candidate_x_13 = center_with_modulus(
                    (n0*1001*2 + n2*429*4 + n3*273*5 + ref13*231*4), 3003
                );
                2'd2: candidate_x_13 = center_with_modulus(
                    (n0*715*1 + n1*429*4 + n3*195*7 + ref13*165*3), 2145
                );
                default: candidate_x_13 = center_with_modulus(
                    (n0*455*2 + n1*273*2 + n2*195*6 + ref13*105*1), 1365
                );
            endcase
        end
    endfunction

    function integer candidate_x_17;
        input [1:0] lane;
        input integer n0;
        input integer n1;
        input integer n2;
        input integer n3;
        input integer ref17;
        begin
            case (lane)
                2'd0: candidate_x_17 = center_with_modulus(
                    (n1*1309*4 + n2*935*2 + n3*595*1 + ref17*385*14), 6545
                );
                2'd1: candidate_x_17 = center_with_modulus(
                    (n0*1309*1 + n2*561*1 + n3*357*9 + ref17*231*12), 3927
                );
                2'd2: candidate_x_17 = center_with_modulus(
                    (n0*935*2 + n1*561*1 + n3*255*6 + ref17*165*10), 2805
                );
                default: candidate_x_17 = center_with_modulus(
                    (n0*595*1 + n1*357*3 + n2*255*5 + ref17*105*6), 1785
                );
            endcase
        end
    endfunction

    function [3:0] residue_for_lane;
        input [1:0] lane;
        input integer x;
        begin
            case (lane)
                2'd0: residue_for_lane = norm_mod_int(x, M0);
                2'd1: residue_for_lane = norm_mod_int(x, M1);
                2'd2: residue_for_lane = norm_mod_int(x, M2);
                default: residue_for_lane = norm_mod_int(x, M3);
            endcase
        end
    endfunction

    always @(posedge clk) begin : p_seq
        integer cand_tmp;
        if (!rst_n) begin
            state           <= S_IDLE;
            start_d         <= 1'b0;
            Correct_Done    <= 1'b0;

            corr_r0         <= '0;
            corr_r1         <= '0;
            corr_r2         <= '0;
            corr_r3         <= '0;
            Error_Detected  <= 1'b0;
            Corrected       <= 1'b0;
            Valid           <= 1'b0;

            lane_idx_r       <= 2'd0;
            winner_found_r   <= 1'b0;
            conflict_found_r <= 1'b0;
            winner_lane_r    <= 2'd0;
            winner_res_r     <= 4'd0;

            n0_r             <= '0;
            n1_r             <= '0;
            n2_r             <= '0;
            n3_r             <= '0;
            chk13_r          <= 1'b0;
            chk17_r          <= 1'b0;
            src_ref_r        <= '0;
            verify_ref_r     <= '0;
            cand13_x_r       <= '0;
            cand13_ok_r      <= 1'b0;
            cand13_res_r     <= '0;
            cand17_x_r       <= '0;
            cand17_ok_r      <= 1'b0;
            cand17_res_r     <= '0;
        end else begin
            start_d      <= Correct_Start;
            Correct_Done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_pulse) begin
                        n0_r <= canon_r0(r0);
                        n1_r <= canon_r1(r1);
                        n2_r <= canon_r2(r2);
                        n3_r <= canon_r3(r3);

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
                    chk13_r <= red_ok(X_base, canon_r4(r4), M4);
                    chk17_r <= red_ok(X_base, canon_r5(r5), M5);

                    if (red_ok(X_base, canon_r4(r4), M4) && red_ok(X_base, canon_r5(r5), M5)) begin
                        corr_r0        <= r0;
                        corr_r1        <= r1;
                        corr_r2        <= r2;
                        corr_r3        <= r3;
                        Error_Detected <= 1'b0;
                        Corrected      <= 1'b0;
                        Valid          <= 1'b1;
                        state          <= S_DONE;
                    end else if (red_ok(X_base, canon_r4(r4), M4) ^ red_ok(X_base, canon_r5(r5), M5)) begin
                        corr_r0        <= r0;
                        corr_r1        <= r1;
                        corr_r2        <= r2;
                        corr_r3        <= r3;
                        Error_Detected <= 1'b1;
                        Corrected      <= 1'b1;
                        Valid          <= 1'b1;
                        state          <= S_DONE;
                    end else begin
                        Error_Detected   <= 1'b1;
                        Corrected        <= 1'b0;
                        Valid            <= 1'b0;
                        lane_idx_r       <= 2'd0;
                        winner_found_r   <= 1'b0;
                        conflict_found_r <= 1'b0;
                        state            <= S_LOAD13;
                    end
                end

                S_LOAD13: begin
                    src_ref_r    <= {1'b0, canon_r4(r4)};
                    verify_ref_r <= canon_r5(r5);
                    state        <= S_PRED13;
                end

                S_PRED13: begin
                    cand_tmp     = candidate_x_13(lane_idx_r, n0_r, n1_r, n2_r, n3_r, src_ref_r[3:0]);
                    cand13_x_r   <= cand_tmp;
                    cand13_ok_r  <= in_base_range(cand_tmp) && red_ok(cand_tmp, verify_ref_r, M5);
                    cand13_res_r <= residue_for_lane(lane_idx_r, cand_tmp);
                    state        <= S_LOAD17;
                end

                S_LOAD17: begin
                    src_ref_r    <= canon_r5(r5);
                    verify_ref_r <= {1'b0, canon_r4(r4)};
                    state        <= S_PRED17;
                end

                S_PRED17: begin
                    cand_tmp     = candidate_x_17(lane_idx_r, n0_r, n1_r, n2_r, n3_r, src_ref_r);
                    cand17_x_r   <= cand_tmp;
                    cand17_ok_r  <= in_base_range(cand_tmp) && red_ok(cand_tmp, verify_ref_r, M4);
                    cand17_res_r <= residue_for_lane(lane_idx_r, cand_tmp);
                    state        <= S_COMPARE;
                end

                S_COMPARE: begin
                    accept_now = cand13_ok_r && cand17_ok_r && (cand13_x_r == cand17_x_r) && (cand13_res_r == cand17_res_r);

                    if (accept_now) begin
                        if (!winner_found_r) begin
                            winner_found_r <= 1'b1;
                            winner_lane_r  <= lane_idx_r;
                            winner_res_r   <= cand13_res_r;
                        end else begin
                            conflict_found_r <= 1'b1;
                        end
                    end

                    if ((accept_now && winner_found_r) || conflict_found_r || (lane_idx_r == 2'd3)) begin
                        state <= S_RESOLVE;
                    end else begin
                        lane_idx_r <= lane_idx_r + 2'd1;
                        state      <= S_LOAD13;
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
