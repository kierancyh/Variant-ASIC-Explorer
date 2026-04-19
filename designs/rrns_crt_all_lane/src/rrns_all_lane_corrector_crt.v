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

    output reg  signed [W0-1:0]          corr_r0,
    output reg  signed [W1-1:0]          corr_r1,
    output reg  signed [W2-1:0]          corr_r2,
    output reg  signed [W3-1:0]          corr_r3,

    output reg                           Base_Fault_Found,
    output reg                           Error_Detected,
    output reg                           Corrected,
    output reg                           Valid,
    output reg                           Correct_Done
);

    localparam integer HALF_BASE = 1155 / 2;   // 577

    localparam [2:0]
        S_IDLE    = 3'd0,
        S_CLASSIFY= 3'd1,
        S_SCAN    = 3'd2,
        S_RESOLVE = 3'd3,
        S_DONE    = 3'd4;

    reg [2:0] state;
    reg       start_d;

    reg [1:0] n0_r;
    reg [2:0] n1_r;
    reg [2:0] n2_r;
    reg [3:0] n3_r;
    reg [3:0] n4_r;
    reg [4:0] n5_r;

    reg signed [W0-1:0] r0_keep_r;
    reg signed [W1-1:0] r1_keep_r;
    reg signed [W2-1:0] r2_keep_r;
    reg signed [W3-1:0] r3_keep_r;

    reg signed [OUT_WIDTH-1:0] x_base_r;

    reg [1:0] lane_idx_r;
    reg       winner_found_r;
    reg       conflict_found_r;
    reg [1:0] winner_lane_r;
    reg [3:0] winner_residue_r;

    integer cand13_x_cur;
    integer cand17_x_cur;
    integer repair13_canon_cur;
    integer repair17_canon_cur;
    reg     ok13_cur;
    reg     ok17_cur;
    reg     accept_cur;

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

    function integer center_base_residue;
        input integer canon_res;
        input integer lane_sel;
        begin
            case (lane_sel)
                0: center_base_residue = (canon_res > 1) ? (canon_res - 3)  : canon_res;
                1: center_base_residue = (canon_res > 2) ? (canon_res - 5)  : canon_res;
                2: center_base_residue = (canon_res > 3) ? (canon_res - 7)  : canon_res;
                default:
                   center_base_residue = (canon_res > 5) ? (canon_res - 11) : canon_res;
            endcase
        end
    endfunction

    wire start_pulse = Correct_Start & ~start_d;

    wire chk13_w = (norm_mod(x_base_r, 13) == n4_r);
    wire chk17_w = (norm_mod(x_base_r, 17) == n5_r);

    always @* begin
        cand13_x_cur        = 0;
        cand17_x_cur        = 0;
        repair13_canon_cur  = 0;
        repair17_canon_cur  = 0;
        ok13_cur            = 1'b0;
        ok17_cur            = 1'b0;
        accept_cur          = 1'b0;

        case (lane_idx_r)
            2'd0: begin
                cand13_x_cur       = center_with_modulus((n1_r * 1001) + (n2_r * 715) + (n3_r * 1365) + (n4_r * 1925), 5005);
                cand17_x_cur       = center_with_modulus((n1_r * 5236) + (n2_r * 1870) + (n3_r * 595)  + (n5_r * 5390), 6545);
                repair13_canon_cur = norm_mod(cand13_x_cur, 3);
                repair17_canon_cur = norm_mod(cand17_x_cur, 3);
                ok13_cur           = in_base_range(cand13_x_cur) && (norm_mod(cand13_x_cur, 17) == n5_r);
                ok17_cur           = in_base_range(cand17_x_cur) && (norm_mod(cand17_x_cur, 13) == n4_r);
                accept_cur         = ok13_cur && ok17_cur && (repair13_canon_cur == repair17_canon_cur);
            end

            2'd1: begin
                cand13_x_cur       = center_with_modulus((n0_r * 2002) + (n2_r * 1716) + (n3_r * 1365) + (n4_r * 924), 3003);
                cand17_x_cur       = center_with_modulus((n0_r * 1309) + (n2_r * 561)  + (n3_r * 3213) + (n5_r * 2772), 3927);
                repair13_canon_cur = norm_mod(cand13_x_cur, 5);
                repair17_canon_cur = norm_mod(cand17_x_cur, 5);
                ok13_cur           = in_base_range(cand13_x_cur) && (norm_mod(cand13_x_cur, 17) == n5_r);
                ok17_cur           = in_base_range(cand17_x_cur) && (norm_mod(cand17_x_cur, 13) == n4_r);
                accept_cur         = ok13_cur && ok17_cur && (repair13_canon_cur == repair17_canon_cur);
            end

            2'd2: begin
                cand13_x_cur       = center_with_modulus((n0_r * 715)  + (n1_r * 1716) + (n3_r * 1365) + (n4_r * 495), 2145);
                cand17_x_cur       = center_with_modulus((n0_r * 1870) + (n1_r * 561)  + (n3_r * 1530) + (n5_r * 1650), 2805);
                repair13_canon_cur = norm_mod(cand13_x_cur, 7);
                repair17_canon_cur = norm_mod(cand17_x_cur, 7);
                ok13_cur           = in_base_range(cand13_x_cur) && (norm_mod(cand13_x_cur, 17) == n5_r);
                ok17_cur           = in_base_range(cand17_x_cur) && (norm_mod(cand17_x_cur, 13) == n4_r);
                accept_cur         = ok13_cur && ok17_cur && (repair13_canon_cur == repair17_canon_cur);
            end

            default: begin
                cand13_x_cur       = center_with_modulus((n0_r * 910) + (n1_r * 546)  + (n2_r * 1170) + (n4_r * 105), 1365);
                cand17_x_cur       = center_with_modulus((n0_r * 595) + (n1_r * 1071) + (n2_r * 1275) + (n5_r * 630), 1785);
                repair13_canon_cur = norm_mod(cand13_x_cur, 11);
                repair17_canon_cur = norm_mod(cand17_x_cur, 11);
                ok13_cur           = in_base_range(cand13_x_cur) && (norm_mod(cand13_x_cur, 17) == n5_r);
                ok17_cur           = in_base_range(cand17_x_cur) && (norm_mod(cand17_x_cur, 13) == n4_r);
                accept_cur         = ok13_cur && ok17_cur && (repair13_canon_cur == repair17_canon_cur);
            end
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            start_d           <= 1'b0;
            corr_r0           <= '0;
            corr_r1           <= '0;
            corr_r2           <= '0;
            corr_r3           <= '0;
            Base_Fault_Found  <= 1'b0;
            Error_Detected    <= 1'b0;
            Corrected         <= 1'b0;
            Valid             <= 1'b0;
            Correct_Done      <= 1'b0;
            n0_r              <= '0;
            n1_r              <= '0;
            n2_r              <= '0;
            n3_r              <= '0;
            n4_r              <= '0;
            n5_r              <= '0;
            r0_keep_r         <= '0;
            r1_keep_r         <= '0;
            r2_keep_r         <= '0;
            r3_keep_r         <= '0;
            x_base_r          <= '0;
            lane_idx_r        <= 2'd0;
            winner_found_r    <= 1'b0;
            conflict_found_r  <= 1'b0;
            winner_lane_r     <= 2'd0;
            winner_residue_r  <= 4'd0;
        end else begin
            start_d      <= Correct_Start;
            Correct_Done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_pulse) begin
                        n0_r      <= norm_mod(r0, 3);
                        n1_r      <= norm_mod(r1, 5);
                        n2_r      <= norm_mod(r2, 7);
                        n3_r      <= norm_mod(r3, 11);
                        n4_r      <= norm_mod(r4, 13);
                        n5_r      <= norm_mod(r5, 17);

                        r0_keep_r <= r0;
                        r1_keep_r <= r1;
                        r2_keep_r <= r2;
                        r3_keep_r <= r3;
                        x_base_r  <= X_base;

                        state     <= S_CLASSIFY;
                    end
                end

                S_CLASSIFY: begin
                    corr_r0          <= r0_keep_r;
                    corr_r1          <= r1_keep_r;
                    corr_r2          <= r2_keep_r;
                    corr_r3          <= r3_keep_r;
                    Base_Fault_Found <= 1'b0;

                    if (chk13_w && chk17_w) begin
                        Error_Detected <= 1'b0;
                        Corrected      <= 1'b0;
                        Valid          <= 1'b1;
                        state          <= S_DONE;
                    end else if (chk13_w ^ chk17_w) begin
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
                        winner_lane_r    <= 2'd0;
                        winner_residue_r <= 4'd0;
                        state            <= S_SCAN;
                    end
                end

                S_SCAN: begin
                    if (accept_cur) begin
                        if (!winner_found_r) begin
                            winner_found_r   <= 1'b1;
                            winner_lane_r    <= lane_idx_r;
                            winner_residue_r <= repair13_canon_cur[3:0];
                        end else begin
                            conflict_found_r <= 1'b1;
                        end
                    end

                    if (lane_idx_r == 2'd3)
                        state <= S_RESOLVE;
                    else
                        lane_idx_r <= lane_idx_r + 2'd1;
                end

                S_RESOLVE: begin
                    corr_r0          <= r0_keep_r;
                    corr_r1          <= r1_keep_r;
                    corr_r2          <= r2_keep_r;
                    corr_r3          <= r3_keep_r;
                    Base_Fault_Found <= 1'b0;

                    if (winner_found_r && !conflict_found_r) begin
                        Base_Fault_Found <= 1'b1;
                        Corrected        <= 1'b1;
                        Valid            <= 1'b1;

                        case (winner_lane_r)
                            2'd0: corr_r0 <= center_base_residue(winner_residue_r, 0);
                            2'd1: corr_r1 <= center_base_residue(winner_residue_r, 1);
                            2'd2: corr_r2 <= center_base_residue(winner_residue_r, 2);
                            default: corr_r3 <= center_base_residue(winner_residue_r, 3);
                        endcase
                    end else begin
                        Corrected <= 1'b0;
                        Valid     <= 1'b0;
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
