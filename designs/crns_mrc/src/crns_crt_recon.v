`timescale 1ns/1ps
module crns_crt_recon #(
    parameter W0        = 2,
    parameter W1        = 3,
    parameter W2        = 3,
    parameter W3        = 4,
    parameter OUT_WIDTH = 16
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          CRT_Start,
    input  wire signed [W0-1:0]          r0,
    input  wire signed [W1-1:0]          r1,
    input  wire signed [W2-1:0]          r2,
    input  wire signed [W3-1:0]          r3,
    output reg  signed [OUT_WIDTH-1:0]   X_out,
    output reg                           CRT_Done
);

    localparam integer M      = 1155;
    localparam integer HALF_M = M / 2;

    localparam integer MOD0   = 3;
    localparam integer MOD1   = 5;
    localparam integer MOD2   = 7;
    localparam integer MOD3   = 11;

    localparam integer M0     = 385;
    localparam integer M1     = 231;
    localparam integer M2     = 165;
    localparam integer M3     = 105;

    localparam integer INV0   = 1;
    localparam integer INV1   = 1;
    localparam integer INV2   = 2;
    localparam integer INV3   = 2;

    integer x0_mod, x1_mod, x2_mod, x3_mod;
    integer term0, term1, term2, term3;
    integer total;
    integer total_mod;
    integer total_centered;
    reg signed [OUT_WIDTH-1:0] X_next;
    reg start_d;

    always @* begin
        x0_mod         = 0;
        x1_mod         = 0;
        x2_mod         = 0;
        x3_mod         = 0;
        term0          = 0;
        term1          = 0;
        term2          = 0;
        term3          = 0;
        total          = 0;
        total_mod      = 0;
        total_centered = 0;
        X_next         = {OUT_WIDTH{1'b0}};

        x0_mod = r0;
        if (x0_mod < 0) x0_mod = x0_mod + MOD0;
        if (x0_mod >= MOD0) x0_mod = x0_mod % MOD0;

        x1_mod = r1;
        if (x1_mod < 0) x1_mod = x1_mod + MOD1;
        if (x1_mod >= MOD1) x1_mod = x1_mod % MOD1;

        x2_mod = r2;
        if (x2_mod < 0) x2_mod = x2_mod + MOD2;
        if (x2_mod >= MOD2) x2_mod = x2_mod % MOD2;

        x3_mod = r3;
        if (x3_mod < 0) x3_mod = x3_mod + MOD3;
        if (x3_mod >= MOD3) x3_mod = x3_mod % MOD3;

        term0 = x0_mod * M0 * INV0;
        term1 = x1_mod * M1 * INV1;
        term2 = x2_mod * M2 * INV2;
        term3 = x3_mod * M3 * INV3;

        total = term0 + term1 + term2 + term3;
        total_mod = total % M;
        if (total_mod < 0)
            total_mod = total_mod + M;

        if (total_mod > HALF_M)
            total_centered = total_mod - M;
        else
            total_centered = total_mod;

        X_next = total_centered;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            CRT_Done <= 1'b0;
            start_d  <= 1'b0;
        end else begin
            CRT_Done <= start_d;
            start_d  <= CRT_Start;

            if (CRT_Start)
                X_out <= X_next;
        end
    end

endmodule