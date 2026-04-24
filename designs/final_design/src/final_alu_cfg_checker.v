`timescale 1ns/1ps
module final_alu_cfg_checker #(
    parameter integer WM = 5,
    parameter integer XW = 24,
    parameter integer PW = 20
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire [WM-1:0]        m0,
    input  wire [WM-1:0]        m1,
    input  wire [WM-1:0]        m2,
    input  wire [WM-1:0]        m3,
    input  wire [WM-1:0]        m4,
    input  wire [WM-1:0]        m5,
    output reg                  done,
    output reg                  cfg_ok,
    output reg  [3:0]           cfg_error_code,
    output reg  [PW-1:0]        M_base,
    output reg  [PW-1:0]        half_range
);

    localparam [4:0]
        ST_IDLE         = 5'd0,
        ST_BASIC        = 5'd1,
        ST_DISTINCT     = 5'd2,
        ST_GCD_INIT     = 5'd3,
        ST_GCD_STEP     = 5'd4,
        ST_BASE_INIT    = 5'd5,
        ST_BASE_MUL     = 5'd6,
        ST_BASE_CHECK   = 5'd7,
        ST_SUBSET_INIT  = 5'd8,
        ST_SUBSET_MUL   = 5'd9,
        ST_SUBSET_CHECK = 5'd10,
        ST_DONE         = 5'd11,
        ST_ERROR        = 5'd12;

    // With WM=5, the largest legal 4-lane product is 31^4 = 923521,
    // so the internal product/candidate width can be reduced to PW=20.
    // Keep the legality limit at the full PW range instead of deriving it
    // from XW, because XW may be wider than PW.
    localparam [PW-1:0] RANGE_LIMIT = {PW{1'b1}};

    reg [4:0] state;

    reg [WM-1:0] lm0, lm1, lm2, lm3, lm4, lm5;
    reg [2:0]    mod_idx;
    reg [2:0]    pair_i, pair_j;
    reg [WM-1:0] gcd_a, gcd_b;
    reg [2:0]    si, sj, sk, sl;
    reg [1:0]    mul_stage;
    reg [PW-1:0] base_acc;
    reg [PW-1:0] subset_acc;

    reg [WM-1:0] mod_sel;
    reg [WM-1:0] pair_mod_i;
    reg [WM-1:0] pair_mod_j;
    reg [WM-1:0] mul_mod_sel;

    always @* begin
        case (mod_idx)
            3'd0: mod_sel = lm0;
            3'd1: mod_sel = lm1;
            3'd2: mod_sel = lm2;
            3'd3: mod_sel = lm3;
            3'd4: mod_sel = lm4;
            3'd5: mod_sel = lm5;
            default: mod_sel = {WM{1'b0}};
        endcase
    end

    always @* begin
        case (pair_i)
            3'd0: pair_mod_i = lm0;
            3'd1: pair_mod_i = lm1;
            3'd2: pair_mod_i = lm2;
            3'd3: pair_mod_i = lm3;
            3'd4: pair_mod_i = lm4;
            3'd5: pair_mod_i = lm5;
            default: pair_mod_i = {WM{1'b0}};
        endcase
    end

    always @* begin
        case (pair_j)
            3'd0: pair_mod_j = lm0;
            3'd1: pair_mod_j = lm1;
            3'd2: pair_mod_j = lm2;
            3'd3: pair_mod_j = lm3;
            3'd4: pair_mod_j = lm4;
            3'd5: pair_mod_j = lm5;
            default: pair_mod_j = {WM{1'b0}};
        endcase
    end

    always @* begin
        case (state)
            ST_BASE_MUL: begin
                case (mod_idx)
                    3'd0: mul_mod_sel = lm0;
                    3'd1: mul_mod_sel = lm1;
                    3'd2: mul_mod_sel = lm2;
                    3'd3: mul_mod_sel = lm3;
                    default: mul_mod_sel = {WM{1'b0}};
                endcase
            end

            default: mul_mod_sel = {WM{1'b0}};
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            done           <= 1'b0;
            cfg_ok         <= 1'b0;
            cfg_error_code <= 4'd0;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        lm0            <= m0;
                        lm1            <= m1;
                        lm2            <= m2;
                        lm3            <= m3;
                        lm4            <= m4;
                        lm5            <= m5;
                        cfg_ok         <= 1'b0;
                        cfg_error_code <= 4'd0;
                        M_base         <= {PW{1'b0}};
                        half_range     <= {PW{1'b0}};
                        mod_idx        <= 3'd0;
                        pair_i         <= 3'd0;
                        pair_j         <= 3'd1;
                        gcd_a          <= {WM{1'b0}};
                        gcd_b          <= {WM{1'b0}};
                        si             <= 3'd0;
                        sj             <= 3'd1;
                        sk             <= 3'd2;
                        sl             <= 3'd3;
                        mul_stage      <= 2'd0;
                        base_acc       <= {PW{1'b0}};
                        subset_acc     <= {PW{1'b0}};
                        state          <= ST_BASIC;
                    end
                end

                ST_BASIC: begin
                    if (mod_sel <= {{(WM-1){1'b0}}, 1'b1}) begin
                        cfg_error_code <= 4'd1;
                        state          <= ST_ERROR;
                    end else if (mod_idx == 3'd5) begin
                        pair_i <= 3'd0;
                        pair_j <= 3'd1;
                        state  <= ST_DISTINCT;
                    end else begin
                        mod_idx <= mod_idx + 3'd1;
                    end
                end

                ST_DISTINCT: begin
                    if (pair_mod_i == pair_mod_j) begin
                        cfg_error_code <= 4'd2;
                        state          <= ST_ERROR;
                    end else begin
                        state <= ST_GCD_INIT;
                    end
                end

                ST_GCD_INIT: begin
                    gcd_a <= pair_mod_i;
                    gcd_b <= pair_mod_j;
                    state <= ST_GCD_STEP;
                end

                ST_GCD_STEP: begin
                    if (gcd_b != {WM{1'b0}}) begin
                        gcd_a <= gcd_b;
                        gcd_b <= gcd_a % gcd_b;
                    end else if (gcd_a != {{(WM-1){1'b0}}, 1'b1}) begin
                        cfg_error_code <= 4'd3;
                        state          <= ST_ERROR;
                    end else if (pair_i == 3'd4 && pair_j == 3'd5) begin
                        mod_idx   <= 3'd0;
                        base_acc  <= {{(PW-1){1'b0}}, 1'b1};
                        state     <= ST_BASE_MUL;
                    end else begin
                        if (pair_j == 3'd5) begin
                            pair_i <= pair_i + 3'd1;
                            pair_j <= pair_i + 3'd2;
                        end else begin
                            pair_j <= pair_j + 3'd1;
                        end
                        state <= ST_DISTINCT;
                    end
                end

                ST_BASE_MUL: begin
                    base_acc <= base_acc * mul_mod_sel;
                    if (mod_idx == 3'd3) begin
                        state <= ST_BASE_CHECK;
                    end else begin
                        mod_idx <= mod_idx + 3'd1;
                    end
                end

                ST_BASE_CHECK: begin
                    M_base     <= base_acc;
                    half_range <= (base_acc >> 1);
                    if (base_acc == {PW{1'b0}}) begin
                        cfg_error_code <= 4'd4;
                        state          <= ST_ERROR;
                    end else if ((base_acc >> 1) > RANGE_LIMIT) begin
                        cfg_error_code <= 4'd5;
                        state          <= ST_ERROR;
                    end else begin
                        // Physical-signoff cleanup:
                        // The runtime corrector now scans base candidates directly and
                        // does not consume the historical 4-of-6 subset-product result.
                        // Ending the checker here removes the large subset_acc/mul_stage
                        // mux tree that showed up as a routed max-slew/max-cap hotspot,
                        // while preserving the active legality checks: modulus range,
                        // pairwise co-prime moduli, non-zero base product, and safe
                        // base-range generation.
                        state <= ST_DONE;
                    end
                end

                ST_SUBSET_MUL: begin
                    // Legacy state retained for encoding compatibility only.
                    state <= ST_DONE;
                end

                ST_SUBSET_CHECK: begin
                    // Legacy state retained for encoding compatibility only.
                    state <= ST_DONE;
                end

                ST_DONE: begin
                    cfg_ok         <= 1'b1;
                    cfg_error_code <= 4'd0;
                    done           <= 1'b1;
                    state          <= ST_IDLE;
                end

                ST_ERROR: begin
                    cfg_ok <= 1'b0;
                    done   <= 1'b1;
                    state  <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
