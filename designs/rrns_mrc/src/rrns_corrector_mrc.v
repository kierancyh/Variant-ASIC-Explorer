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
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire                         Corr_Start,

    input  wire signed [OUT_WIDTH-1:0]  X_base,
    input  wire signed [W0-1:0]         r0,
    input  wire signed [W1-1:0]         r1,
    input  wire signed [W2-1:0]         r2,
    input  wire signed [W3-1:0]         r3,
    input  wire signed [W4-1:0]         r4,
    input  wire signed [W5-1:0]         r5,

    output reg                          Corr_Done,
    output reg  signed [OUT_WIDTH-1:0]  X_corr,
    output reg                          Error_Detected,
    output reg                          Corrected,
    output reg                          Valid
);

    localparam signed [17:0] HALF_BASE = 18'sd577;
    localparam [1:0]
        ST_IDLE  = 2'd0,
        ST_CHECK = 2'd1,
        ST_SCAN  = 2'd2,
        ST_FINAL = 2'd3;

    reg [1:0] state;
    reg [1:0] scan_idx;
    reg       busy;

    reg signed [OUT_WIDTH-1:0] x_base_q;
    reg signed [4:0] n0_q, n1_q, n2_q, n3_q, n4_q, n5_q;

    reg chk13_q, chk17_q;
    reg [2:0] count13_q, count17_q;
    reg signed [OUT_WIDTH-1:0] sel13_q, sel17_q;

    reg signed [17:0] cand13_v, cand17_v;
    reg               ok13_v, ok17_v;

    function signed [17:0] norm_mod18;
        input signed [17:0] x;
        input integer m;
        reg signed [17:0] t;
        begin
            t = x % m;
            if (t < 0)
                t = t + m;
            norm_mod18 = t;
        end
    endfunction

    function signed [17:0] center_with_modulus;
        input signed [17:0] x;
        input integer p;
        reg signed [17:0] t;
        begin
            t = norm_mod18(x, p);
            if (t > (p / 2))
                center_with_modulus = t - p;
            else
                center_with_modulus = t;
        end
    endfunction

    function in_base_range;
        input signed [17:0] x;
        begin
            in_base_range = (x >= -HALF_BASE) && (x <= HALF_BASE);
        end
    endfunction

    function red_ok;
        input signed [17:0] x;
        input signed [4:0]  r;
        input integer       m;
        begin
            red_ok = (norm_mod18(x, m) == r);
        end
    endfunction

    function signed [17:0] candidate13;
        input [1:0] idx;
        input signed [4:0] n0, n1, n2, n3, n4;
        begin
            case (idx)
                2'd0: candidate13 = center_with_modulus((n1 * 18'sd1001) + (n2 * 18'sd715)  + (n3 * 18'sd1365) + (n4 * 18'sd1925), 5005);
                2'd1: candidate13 = center_with_modulus((n0 * 18'sd2002) + (n2 * 18'sd1716) + (n3 * 18'sd1365) + (n4 * 18'sd924),  3003);
                2'd2: candidate13 = center_with_modulus((n0 * 18'sd715)  + (n1 * 18'sd1716) + (n3 * 18'sd1365) + (n4 * 18'sd495),  2145);
                default:
                      candidate13 = center_with_modulus((n0 * 18'sd910)  + (n1 * 18'sd546)  + (n2 * 18'sd1170) + (n4 * 18'sd105),  1365);
            endcase
        end
    endfunction

    function signed [17:0] candidate17;
        input [1:0] idx;
        input signed [4:0] n0, n1, n2, n3, n5;
        begin
            case (idx)
                2'd0: candidate17 = center_with_modulus((n1 * 18'sd5236) + (n2 * 18'sd1870) + (n3 * 18'sd595)  + (n5 * 18'sd5390), 6545);
                2'd1: candidate17 = center_with_modulus((n0 * 18'sd1309) + (n2 * 18'sd561)  + (n3 * 18'sd3213) + (n5 * 18'sd2772), 3927);
                2'd2: candidate17 = center_with_modulus((n0 * 18'sd1870) + (n1 * 18'sd561)  + (n3 * 18'sd1530) + (n5 * 18'sd1650), 2805);
                default:
                      candidate17 = center_with_modulus((n0 * 18'sd595)  + (n1 * 18'sd1071) + (n2 * 18'sd1275) + (n5 * 18'sd630),  1785);
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            scan_idx       <= 2'd0;
            busy           <= 1'b0;
            x_base_q       <= {OUT_WIDTH{1'b0}};
            n0_q           <= 5'sd0;
            n1_q           <= 5'sd0;
            n2_q           <= 5'sd0;
            n3_q           <= 5'sd0;
            n4_q           <= 5'sd0;
            n5_q           <= 5'sd0;
            chk13_q        <= 1'b0;
            chk17_q        <= 1'b0;
            count13_q      <= 3'd0;
            count17_q      <= 3'd0;
            sel13_q        <= {OUT_WIDTH{1'b0}};
            sel17_q        <= {OUT_WIDTH{1'b0}};
            X_corr         <= {OUT_WIDTH{1'b0}};
            Error_Detected <= 1'b0;
            Corrected      <= 1'b0;
            Valid          <= 1'b0;
            Corr_Done      <= 1'b0;
        end else begin
            Corr_Done <= 1'b0;

            if (!busy) begin
                if (Corr_Start) begin
                    busy      <= 1'b1;
                    state     <= ST_CHECK;
                    scan_idx  <= 2'd0;
                    x_base_q  <= X_base;

                    n0_q <= norm_mod18(r0, 3);
                    n1_q <= norm_mod18(r1, 5);
                    n2_q <= norm_mod18(r2, 7);
                    n3_q <= norm_mod18(r3, 11);
                    n4_q <= norm_mod18(r4, 13);
                    n5_q <= norm_mod18(r5, 17);

                    chk13_q   <= 1'b0;
                    chk17_q   <= 1'b0;
                    count13_q <= 3'd0;
                    count17_q <= 3'd0;
                    sel13_q   <= {OUT_WIDTH{1'b0}};
                    sel17_q   <= {OUT_WIDTH{1'b0}};
                end
            end else begin
                case (state)
                    ST_CHECK: begin
                        chk13_q   <= red_ok(x_base_q, n4_q, 13);
                        chk17_q   <= red_ok(x_base_q, n5_q, 17);
                        count13_q <= 3'd0;
                        count17_q <= 3'd0;
                        sel13_q   <= {OUT_WIDTH{1'b0}};
                        sel17_q   <= {OUT_WIDTH{1'b0}};
                        scan_idx  <= 2'd0;

                        if (red_ok(x_base_q, n4_q, 13) && red_ok(x_base_q, n5_q, 17)) begin
                            X_corr         <= x_base_q;
                            Error_Detected <= 1'b0;
                            Corrected      <= 1'b0;
                            Valid          <= 1'b1;
                            Corr_Done      <= 1'b1;
                            busy           <= 1'b0;
                            state          <= ST_IDLE;
                        end else begin
                            state <= ST_SCAN;
                        end
                    end

                    ST_SCAN: begin
                        cand13_v = candidate13(scan_idx, n0_q, n1_q, n2_q, n3_q, n4_q);
                        cand17_v = candidate17(scan_idx, n0_q, n1_q, n2_q, n3_q, n5_q);
                        ok13_v   = red_ok(cand13_v, n5_q, 17) && in_base_range(cand13_v);
                        ok17_v   = red_ok(cand17_v, n4_q, 13) && in_base_range(cand17_v);

                        if (ok13_v) begin
                            count13_q <= count13_q + 3'd1;
                            sel13_q   <= cand13_v[OUT_WIDTH-1:0];
                        end
                        if (ok17_v) begin
                            count17_q <= count17_q + 3'd1;
                            sel17_q   <= cand17_v[OUT_WIDTH-1:0];
                        end

                        if (scan_idx == 2'd3)
                            state <= ST_FINAL;
                        else
                            scan_idx <= scan_idx + 2'd1;
                    end

                    ST_FINAL: begin
                        Error_Detected <= 1'b1;

                        if (chk13_q && !chk17_q) begin
                            if ((count13_q == 3'd1) && (sel13_q != x_base_q)) begin
                                X_corr    <= sel13_q;
                                Corrected <= 1'b1;
                                Valid     <= 1'b1;
                            end else begin
                                X_corr    <= x_base_q;
                                Corrected <= 1'b1;
                                Valid     <= 1'b1;
                            end
                        end else if (!chk13_q && chk17_q) begin
                            if ((count17_q == 3'd1) && (sel17_q != x_base_q)) begin
                                X_corr    <= sel17_q;
                                Corrected <= 1'b1;
                                Valid     <= 1'b1;
                            end else begin
                                X_corr    <= x_base_q;
                                Corrected <= 1'b1;
                                Valid     <= 1'b1;
                            end
                        end else begin
                            if ((count13_q == 3'd1) && (count17_q == 3'd1)) begin
                                if (sel13_q == sel17_q) begin
                                    X_corr    <= sel13_q;
                                    Corrected <= 1'b1;
                                    Valid     <= 1'b1;
                                end else begin
                                    X_corr    <= x_base_q;
                                    Corrected <= 1'b0;
                                    Valid     <= 1'b0;
                                end
                            end else if (count13_q == 3'd1) begin
                                X_corr    <= sel13_q;
                                Corrected <= 1'b1;
                                Valid     <= 1'b1;
                            end else if (count17_q == 3'd1) begin
                                X_corr    <= sel17_q;
                                Corrected <= 1'b1;
                                Valid     <= 1'b1;
                            end else begin
                                X_corr    <= x_base_q;
                                Corrected <= 1'b0;
                                Valid     <= 1'b0;
                            end
                        end

                        Corr_Done <= 1'b1;
                        busy      <= 1'b0;
                        state     <= ST_IDLE;
                    end

                    default: begin
                        state <= ST_IDLE;
                        busy  <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule
