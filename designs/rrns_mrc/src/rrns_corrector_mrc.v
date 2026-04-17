`timescale 1ns/1ps
module rrns_corrector_mrc #(
    parameter W0        = 2,
    parameter W1        = 3,
    parameter W2        = 3,
    parameter W3        = 4,
    parameter W4        = 4,
    parameter W5        = 5,
    parameter OUT_WIDTH = 16
)(
    input  wire signed [OUT_WIDTH-1:0] X_base,
    input  wire signed [W0-1:0]        r0,
    input  wire signed [W1-1:0]        r1,
    input  wire signed [W2-1:0]        r2,
    input  wire signed [W3-1:0]        r3,
    input  wire signed [W4-1:0]        r4,
    input  wire signed [W5-1:0]        r5,
    output reg  signed [OUT_WIDTH-1:0] X_corr,
    output reg                         Error_Detected,
    output reg                         Corrected,
    output reg                         Valid
);

    localparam signed [OUT_WIDTH-1:0] HALF_BASE  = 16'sd577;
    localparam signed [17:0] MOD_5005 = 18'sd5005;
    localparam signed [17:0] MOD_3003 = 18'sd3003;
    localparam signed [17:0] MOD_2145 = 18'sd2145;
    localparam signed [17:0] MOD_1365 = 18'sd1365;
    localparam signed [17:0] MOD_6545 = 18'sd6545;
    localparam signed [17:0] MOD_3927 = 18'sd3927;
    localparam signed [17:0] MOD_2805 = 18'sd2805;
    localparam signed [17:0] MOD_1785 = 18'sd1785;

    reg [4:0] n0, n1, n2, n3, n4, n5;
    reg       chk13, chk17;
    reg       ok0_13, ok1_13, ok2_13, ok3_13;
    reg       ok0_17, ok1_17, ok2_17, ok3_17;
    reg [2:0] count13, count17;

    reg signed [OUT_WIDTH-1:0] cand0_13, cand1_13, cand2_13, cand3_13;
    reg signed [OUT_WIDTH-1:0] cand0_17, cand1_17, cand2_17, cand3_17;
    reg signed [OUT_WIDTH-1:0] sel13, sel17;
    reg signed [17:0] sum0_13, sum1_13, sum2_13, sum3_13;
    reg signed [17:0] sum0_17, sum1_17, sum2_17, sum3_17;
    reg signed [5:0]  s0, s1, s2, s3, s4, s5;

    function [4:0] norm_mod13_s16;
        input signed [OUT_WIDTH-1:0] x;
        reg signed [OUT_WIDTH-1:0] t;
        begin
            t = x % 16'sd13;
            if (t < 0)
                t = t + 16'sd13;
            norm_mod13_s16 = t[4:0];
        end
    endfunction

    function [4:0] norm_mod17_s16;
        input signed [OUT_WIDTH-1:0] x;
        reg signed [OUT_WIDTH-1:0] t;
        begin
            t = x % 16'sd17;
            if (t < 0)
                t = t + 16'sd17;
            norm_mod17_s16 = t[4:0];
        end
    endfunction

    function signed [OUT_WIDTH-1:0] center_mod_s18;
        input signed [17:0] x;
        input signed [17:0] p;
        reg signed [17:0] t;
        begin
            t = x % p;
            if (t < 0)
                t = t + p;
            if (t > (p >>> 1))
                center_mod_s18 = t - p;
            else
                center_mod_s18 = t;
        end
    endfunction

    function in_base_range_s16;
        input signed [OUT_WIDTH-1:0] x;
        begin
            in_base_range_s16 = (x >= -HALF_BASE) && (x <= HALF_BASE);
        end
    endfunction

    always @* begin
        s0 = {{(6-W0){r0[W0-1]}}, r0};
        s1 = {{(6-W1){r1[W1-1]}}, r1};
        s2 = {{(6-W2){r2[W2-1]}}, r2};
        s3 = {{(6-W3){r3[W3-1]}}, r3};
        s4 = {{(6-W4){r4[W4-1]}}, r4};
        s5 = {{(6-W5){r5[W5-1]}}, r5};

        n0 = (s0 < 0) ? (s0 + 6'sd3)  : s0[4:0];
        n1 = (s1 < 0) ? (s1 + 6'sd5)  : s1[4:0];
        n2 = (s2 < 0) ? (s2 + 6'sd7)  : s2[4:0];
        n3 = (s3 < 0) ? (s3 + 6'sd11) : s3[4:0];
        n4 = (s4 < 0) ? (s4 + 6'sd13) : s4[4:0];
        n5 = (s5 < 0) ? (s5 + 6'sd17) : s5[4:0];

        chk13 = (norm_mod13_s16(X_base) == n4);
        chk17 = (norm_mod17_s16(X_base) == n5);

        sum0_13 = $signed({1'b0,n1}) * 18'sd1001 + $signed({1'b0,n2}) * 18'sd715 + $signed({1'b0,n3}) * 18'sd1365 + $signed({1'b0,n4}) * 18'sd1925;
        sum1_13 = $signed({1'b0,n0}) * 18'sd2002 + $signed({1'b0,n2}) * 18'sd1716 + $signed({1'b0,n3}) * 18'sd1365 + $signed({1'b0,n4}) * 18'sd924;
        sum2_13 = $signed({1'b0,n0}) * 18'sd715  + $signed({1'b0,n1}) * 18'sd1716 + $signed({1'b0,n3}) * 18'sd1365 + $signed({1'b0,n4}) * 18'sd495;
        sum3_13 = $signed({1'b0,n0}) * 18'sd910  + $signed({1'b0,n1}) * 18'sd546  + $signed({1'b0,n2}) * 18'sd1170 + $signed({1'b0,n4}) * 18'sd105;

        sum0_17 = $signed({1'b0,n1}) * 18'sd5236 + $signed({1'b0,n2}) * 18'sd1870 + $signed({1'b0,n3}) * 18'sd595  + $signed({1'b0,n5}) * 18'sd5390;
        sum1_17 = $signed({1'b0,n0}) * 18'sd1309 + $signed({1'b0,n2}) * 18'sd561  + $signed({1'b0,n3}) * 18'sd3213 + $signed({1'b0,n5}) * 18'sd2772;
        sum2_17 = $signed({1'b0,n0}) * 18'sd1870 + $signed({1'b0,n1}) * 18'sd561  + $signed({1'b0,n3}) * 18'sd1530 + $signed({1'b0,n5}) * 18'sd1650;
        sum3_17 = $signed({1'b0,n0}) * 18'sd595  + $signed({1'b0,n1}) * 18'sd1071 + $signed({1'b0,n2}) * 18'sd1275 + $signed({1'b0,n5}) * 18'sd630;

        cand0_13 = center_mod_s18(sum0_13, MOD_5005);
        cand1_13 = center_mod_s18(sum1_13, MOD_3003);
        cand2_13 = center_mod_s18(sum2_13, MOD_2145);
        cand3_13 = center_mod_s18(sum3_13, MOD_1365);

        cand0_17 = center_mod_s18(sum0_17, MOD_6545);
        cand1_17 = center_mod_s18(sum1_17, MOD_3927);
        cand2_17 = center_mod_s18(sum2_17, MOD_2805);
        cand3_17 = center_mod_s18(sum3_17, MOD_1785);

        ok0_13 = (norm_mod17_s16(cand0_13) == n5) && in_base_range_s16(cand0_13);
        ok1_13 = (norm_mod17_s16(cand1_13) == n5) && in_base_range_s16(cand1_13);
        ok2_13 = (norm_mod17_s16(cand2_13) == n5) && in_base_range_s16(cand2_13);
        ok3_13 = (norm_mod17_s16(cand3_13) == n5) && in_base_range_s16(cand3_13);

        ok0_17 = (norm_mod13_s16(cand0_17) == n4) && in_base_range_s16(cand0_17);
        ok1_17 = (norm_mod13_s16(cand1_17) == n4) && in_base_range_s16(cand1_17);
        ok2_17 = (norm_mod13_s16(cand2_17) == n4) && in_base_range_s16(cand2_17);
        ok3_17 = (norm_mod13_s16(cand3_17) == n4) && in_base_range_s16(cand3_17);

        count13 = {2'b00, ok0_13} + {2'b00, ok1_13} + {2'b00, ok2_13} + {2'b00, ok3_13};
        count17 = {2'b00, ok0_17} + {2'b00, ok1_17} + {2'b00, ok2_17} + {2'b00, ok3_17};

        sel13 = 16'sd0;
        if (ok0_13) sel13 = cand0_13;
        else if (ok1_13) sel13 = cand1_13;
        else if (ok2_13) sel13 = cand2_13;
        else if (ok3_13) sel13 = cand3_13;

        sel17 = 16'sd0;
        if (ok0_17) sel17 = cand0_17;
        else if (ok1_17) sel17 = cand1_17;
        else if (ok2_17) sel17 = cand2_17;
        else if (ok3_17) sel17 = cand3_17;

        X_corr         = X_base;
        Error_Detected = 1'b0;
        Corrected      = 1'b0;
        Valid          = 1'b1;

        if (chk13 && chk17) begin
            X_corr         = X_base;
            Error_Detected = 1'b0;
            Corrected      = 1'b0;
            Valid          = 1'b1;
        end else if (chk13 && !chk17) begin
            Error_Detected = 1'b1;
            if ((count13 == 3'd1) && (sel13 != X_base)) begin
                X_corr    = sel13;
                Corrected = 1'b1;
                Valid     = 1'b1;
            end else begin
                X_corr    = X_base;
                Corrected = 1'b1;
                Valid     = 1'b1;
            end
        end else if (!chk13 && chk17) begin
            Error_Detected = 1'b1;
            if ((count17 == 3'd1) && (sel17 != X_base)) begin
                X_corr    = sel17;
                Corrected = 1'b1;
                Valid     = 1'b1;
            end else begin
                X_corr    = X_base;
                Corrected = 1'b1;
                Valid     = 1'b1;
            end
        end else begin
            Error_Detected = 1'b1;
            if ((count13 == 3'd1) && (count17 == 3'd1)) begin
                if (sel13 == sel17) begin
                    X_corr    = sel13;
                    Corrected = 1'b1;
                    Valid     = 1'b1;
                end else begin
                    X_corr    = X_base;
                    Corrected = 1'b0;
                    Valid     = 1'b0;
                end
            end else if (count13 == 3'd1) begin
                X_corr    = sel13;
                Corrected = 1'b1;
                Valid     = 1'b1;
            end else if (count17 == 3'd1) begin
                X_corr    = sel17;
                Corrected = 1'b1;
                Valid     = 1'b1;
            end else begin
                X_corr    = X_base;
                Corrected = 1'b0;
                Valid     = 1'b0;
            end
        end
    end

endmodule
