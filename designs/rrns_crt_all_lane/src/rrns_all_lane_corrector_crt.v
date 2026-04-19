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

    localparam [0:0]
        S_IDLE = 1'b0,
        S_EVAL = 1'b1;

    reg state;
    reg start_d;
    wire start_pulse = Correct_Start & ~start_d;

    // ---------------------------------------------------------------------
    // Stage 0 combinational preparation from live residues / X_base.
    // This logic is only sampled when Correct_Start is accepted.
    // ---------------------------------------------------------------------
    integer n0_w, n1_w, n2_w, n3_w, n4_w, n5_w;
    integer x_base_w;
    reg     chk13_w;
    reg     chk17_w;

    integer cand0_13_w, cand0_17_w;
    integer cand1_13_w, cand1_17_w;
    integer cand2_13_w, cand2_17_w;
    integer cand3_13_w, cand3_17_w;

    // ---------------------------------------------------------------------
    // Stage 1 registered candidate bank.
    // This is the new register boundary that splits:
    //   (a) candidate generation
    //   (b) candidate validation / winner selection
    // ---------------------------------------------------------------------
    reg signed [OUT_WIDTH-1:0] x_base_r;
    integer n4_r, n5_r;
    reg     chk13_r;
    reg     chk17_r;

    integer cand0_13_r, cand0_17_r;
    integer cand1_13_r, cand1_17_r;
    integer cand2_13_r, cand2_17_r;
    integer cand3_13_r, cand3_17_r;

    // ---------------------------------------------------------------------
    // Stage 2 combinational evaluation from the registered candidate bank.
    // ---------------------------------------------------------------------
    reg ok0_13_w, ok0_17_w, acc0_w;
    reg ok1_13_w, ok1_17_w, acc1_w;
    reg ok2_13_w, ok2_17_w, acc2_w;
    reg ok3_13_w, ok3_17_w, acc3_w;

    reg [3:0] acc_vec_w;
    reg       unique_winner_w;

    reg signed [OUT_WIDTH-1:0] x_corr_next_w;
    reg                        err_next_w;
    reg                        corr_next_w;
    reg                        valid_next_w;

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

    // Stage 0: normalize live residues and build all lane-drop candidates.
    always @* begin
        n0_w     = norm_mod(r0, 3);
        n1_w     = norm_mod(r1, 5);
        n2_w     = norm_mod(r2, 7);
        n3_w     = norm_mod(r3, 11);
        n4_w     = norm_mod(r4, 13);
        n5_w     = norm_mod(r5, 17);
        x_base_w = X_base;

        chk13_w = red_ok(x_base_w, n4_w, 13);
        chk17_w = red_ok(x_base_w, n5_w, 17);

        // Drop r0 / mod-3
        cand0_13_w = center_with_modulus(
            (n1_w*1001*1 + n2_w*715*1 + n3_w*455*3 + n4_w*385*5), 5005
        ); // [5,7,11,13]

        cand0_17_w = center_with_modulus(
            (n1_w*1309*4 + n2_w*935*2 + n3_w*595*1 + n5_w*385*14), 6545
        ); // [5,7,11,17]

        // Drop r1 / mod-5
        cand1_13_w = center_with_modulus(
            (n0_w*1001*2 + n2_w*429*4 + n3_w*273*5 + n4_w*231*4), 3003
        ); // [3,7,11,13]

        cand1_17_w = center_with_modulus(
            (n0_w*1309*1 + n2_w*561*1 + n3_w*357*9 + n5_w*231*12), 3927
        ); // [3,7,11,17]

        // Drop r2 / mod-7
        cand2_13_w = center_with_modulus(
            (n0_w*715*1 + n1_w*429*4 + n3_w*195*7 + n4_w*165*3), 2145
        ); // [3,5,11,13]

        cand2_17_w = center_with_modulus(
            (n0_w*935*2 + n1_w*561*1 + n3_w*255*6 + n5_w*165*10), 2805
        ); // [3,5,11,17]

        // Drop r3 / mod-11
        cand3_13_w = center_with_modulus(
            (n0_w*455*2 + n1_w*273*2 + n2_w*195*6 + n4_w*105*1), 1365
        ); // [3,5,7,13]

        cand3_17_w = center_with_modulus(
            (n0_w*595*1 + n1_w*357*3 + n2_w*255*5 + n5_w*105*6), 1785
        ); // [3,5,7,17]
    end

    // Stage 2: validate / cross-check / choose a unique winner.
    always @* begin
        ok0_13_w = red_ok(cand0_13_r, n5_r, 17) && in_base_range(cand0_13_r);
        ok0_17_w = red_ok(cand0_17_r, n4_r, 13) && in_base_range(cand0_17_r);
        acc0_w   = ok0_13_w && ok0_17_w && (cand0_13_r == cand0_17_r);

        ok1_13_w = red_ok(cand1_13_r, n5_r, 17) && in_base_range(cand1_13_r);
        ok1_17_w = red_ok(cand1_17_r, n4_r, 13) && in_base_range(cand1_17_r);
        acc1_w   = ok1_13_w && ok1_17_w && (cand1_13_r == cand1_17_r);

        ok2_13_w = red_ok(cand2_13_r, n5_r, 17) && in_base_range(cand2_13_r);
        ok2_17_w = red_ok(cand2_17_r, n4_r, 13) && in_base_range(cand2_17_r);
        acc2_w   = ok2_13_w && ok2_17_w && (cand2_13_r == cand2_17_r);

        ok3_13_w = red_ok(cand3_13_r, n5_r, 17) && in_base_range(cand3_13_r);
        ok3_17_w = red_ok(cand3_17_r, n4_r, 13) && in_base_range(cand3_17_r);
        acc3_w   = ok3_13_w && ok3_17_w && (cand3_13_r == cand3_17_r);

        acc_vec_w       = {acc3_w, acc2_w, acc1_w, acc0_w};
        unique_winner_w = (acc_vec_w != 4'b0000) && ((acc_vec_w & (acc_vec_w - 4'b0001)) == 4'b0000);

        x_corr_next_w = x_base_r;
        err_next_w    = 1'b0;
        corr_next_w   = 1'b0;
        valid_next_w  = 1'b1;

        // Decision policy stays the same as the original all-lane branch.
        if (chk13_r && chk17_r) begin
            x_corr_next_w = x_base_r;
            err_next_w    = 1'b0;
            corr_next_w   = 1'b0;
            valid_next_w  = 1'b1;

        end else if (chk13_r ^ chk17_r) begin
            x_corr_next_w = x_base_r;
            err_next_w    = 1'b1;
            corr_next_w   = 1'b1;  // tolerated redundant-lane fault
            valid_next_w  = 1'b1;

        end else if (unique_winner_w) begin
            err_next_w   = 1'b1;
            corr_next_w  = 1'b1;
            valid_next_w = 1'b1;

            case (acc_vec_w)
                4'b0001: x_corr_next_w = cand0_13_r[OUT_WIDTH-1:0];
                4'b0010: x_corr_next_w = cand1_13_r[OUT_WIDTH-1:0];
                4'b0100: x_corr_next_w = cand2_13_r[OUT_WIDTH-1:0];
                4'b1000: x_corr_next_w = cand3_13_r[OUT_WIDTH-1:0];
                default: x_corr_next_w = x_base_r;
            endcase
        end else begin
            x_corr_next_w = x_base_r;
            err_next_w    = 1'b1;
            corr_next_w   = 1'b0;
            valid_next_w  = 1'b0;
        end
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
            n4_r           <= 0;
            n5_r           <= 0;
            chk13_r        <= 1'b0;
            chk17_r        <= 1'b0;
            cand0_13_r     <= 0;
            cand0_17_r     <= 0;
            cand1_13_r     <= 0;
            cand1_17_r     <= 0;
            cand2_13_r     <= 0;
            cand2_17_r     <= 0;
            cand3_13_r     <= 0;
            cand3_17_r     <= 0;
        end else begin
            start_d      <= Correct_Start;
            Correct_Done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_pulse) begin
                        x_base_r   <= X_base;
                        n4_r       <= n4_w;
                        n5_r       <= n5_w;
                        chk13_r    <= chk13_w;
                        chk17_r    <= chk17_w;
                        cand0_13_r <= cand0_13_w;
                        cand0_17_r <= cand0_17_w;
                        cand1_13_r <= cand1_13_w;
                        cand1_17_r <= cand1_17_w;
                        cand2_13_r <= cand2_13_w;
                        cand2_17_r <= cand2_17_w;
                        cand3_13_r <= cand3_13_w;
                        cand3_17_r <= cand3_17_w;
                        state      <= S_EVAL;
                    end
                end

                S_EVAL: begin
                    X_corr         <= x_corr_next_w;
                    Error_Detected <= err_next_w;
                    Corrected      <= corr_next_w;
                    Valid          <= valid_next_w;
                    Correct_Done   <= 1'b1;
                    state          <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
