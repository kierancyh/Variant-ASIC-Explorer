`timescale 1ns/1ps
`include "src/final_alu_cfg.svh"

module final_alu_encoder #(
    parameter WIDTH_IN = `FINAL_ALU_DATA_W,
    parameter M0 = `FINAL_ALU_BASE_MOD_0,
    parameter M1 = `FINAL_ALU_BASE_MOD_1,
    parameter M2 = `FINAL_ALU_BASE_MOD_2,
    parameter M3 = `FINAL_ALU_BASE_MOD_3,
    parameter M4 = `FINAL_ALU_RED_MOD_0,
    parameter M5 = `FINAL_ALU_RED_MOD_1,
    parameter CRNS_EN = 1
)(
    input  wire                               clk,
    input  wire                               rst_n,
    input  wire                               Encode_EN,
    input  wire signed [WIDTH_IN-1:0]         x,
    output reg                                Encode_Done,
    output reg signed [`FINAL_ALU_RES_W-1:0]  base_r0,
    output reg signed [`FINAL_ALU_RES_W-1:0]  base_r1,
    output reg signed [`FINAL_ALU_RES_W-1:0]  base_r2,
    output reg signed [`FINAL_ALU_RES_W-1:0]  base_r3,
    output reg signed [`FINAL_ALU_RES_W-1:0]  red_r0,
    output reg signed [`FINAL_ALU_RES_W-1:0]  red_r1
);

    function integer norm_std;
        input integer val;
        input integer m;
        begin
            norm_std = val % m;
            if (norm_std < 0)
                norm_std = norm_std + m;
        end
    endfunction

    function integer norm_bal;
        input integer val;
        input integer m;
        integer r;
        begin
            r = norm_std(val, m);
            if (r > (m / 2) || ((m % 2) == 0 && r == (m / 2)))
                r = r - m;
            norm_bal = r;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            Encode_Done <= 1'b0;
            base_r0 <= '0;
            base_r1 <= '0;
            base_r2 <= '0;
            base_r3 <= '0;
            red_r0  <= '0;
            red_r1  <= '0;
        end else begin
            Encode_Done <= 1'b0;
            if (Encode_EN) begin
                base_r0 <= (CRNS_EN ? norm_bal(x, M0) : norm_std(x, M0));
                base_r1 <= (CRNS_EN ? norm_bal(x, M1) : norm_std(x, M1));
                base_r2 <= (CRNS_EN ? norm_bal(x, M2) : norm_std(x, M2));
                base_r3 <= (CRNS_EN ? norm_bal(x, M3) : norm_std(x, M3));
                red_r0  <= (CRNS_EN ? norm_bal(x, M4) : norm_std(x, M4));
                red_r1  <= (CRNS_EN ? norm_bal(x, M5) : norm_std(x, M5));
                Encode_Done <= 1'b1;
            end
        end
    end

endmodule
