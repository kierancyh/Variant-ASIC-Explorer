`timescale 1ns/1ps
`include "final_alu_cfg.svh"

(* keep_hierarchy = "yes" *)
module final_alu_residue_lane_encoder #(
    parameter WIDTH_IN = `FINAL_ALU_DATA_W,
    parameter RES_W    = `FINAL_ALU_RES_W,
    parameter MODULUS  = 3,
    parameter CRNS_EN  = 1
)(
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              Encode_EN,
    input  wire signed [WIDTH_IN-1:0]        x,
    output reg  signed [RES_W-1:0]           r_out
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

    integer lane_tmp;
    always @(posedge clk) begin
        if (!rst_n) begin
            r_out <= '0;
        end else if (Encode_EN) begin
            lane_tmp = CRNS_EN ? norm_bal(x, MODULUS) : norm_std(x, MODULUS);
            r_out <= lane_tmp[RES_W-1:0];
        end
    end

endmodule

(* keep_hierarchy = "yes" *)
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
    output wire signed [`FINAL_ALU_RES_W-1:0] base_r0,
    output wire signed [`FINAL_ALU_RES_W-1:0] base_r1,
    output wire signed [`FINAL_ALU_RES_W-1:0] base_r2,
    output wire signed [`FINAL_ALU_RES_W-1:0] base_r3,
    output wire signed [`FINAL_ALU_RES_W-1:0] red_r0,
    output wire signed [`FINAL_ALU_RES_W-1:0] red_r1
);

    // Lane-local residue encoders reduce global shared boolean logic.
    // This encourages synthesis/P&R to keep each modulus path physically local
    // instead of building one large shared combinational encoder cone.
    (* keep_hierarchy = "yes" *) final_alu_residue_lane_encoder #(
        .WIDTH_IN(WIDTH_IN), .RES_W(`FINAL_ALU_RES_W), .MODULUS(M0), .CRNS_EN(CRNS_EN)
    ) u_lane_enc_0 (
        .clk(clk), .rst_n(rst_n), .Encode_EN(Encode_EN), .x(x), .r_out(base_r0)
    );

    (* keep_hierarchy = "yes" *) final_alu_residue_lane_encoder #(
        .WIDTH_IN(WIDTH_IN), .RES_W(`FINAL_ALU_RES_W), .MODULUS(M1), .CRNS_EN(CRNS_EN)
    ) u_lane_enc_1 (
        .clk(clk), .rst_n(rst_n), .Encode_EN(Encode_EN), .x(x), .r_out(base_r1)
    );

    (* keep_hierarchy = "yes" *) final_alu_residue_lane_encoder #(
        .WIDTH_IN(WIDTH_IN), .RES_W(`FINAL_ALU_RES_W), .MODULUS(M2), .CRNS_EN(CRNS_EN)
    ) u_lane_enc_2 (
        .clk(clk), .rst_n(rst_n), .Encode_EN(Encode_EN), .x(x), .r_out(base_r2)
    );

    (* keep_hierarchy = "yes" *) final_alu_residue_lane_encoder #(
        .WIDTH_IN(WIDTH_IN), .RES_W(`FINAL_ALU_RES_W), .MODULUS(M3), .CRNS_EN(CRNS_EN)
    ) u_lane_enc_3 (
        .clk(clk), .rst_n(rst_n), .Encode_EN(Encode_EN), .x(x), .r_out(base_r3)
    );

    (* keep_hierarchy = "yes" *) final_alu_residue_lane_encoder #(
        .WIDTH_IN(WIDTH_IN), .RES_W(`FINAL_ALU_RES_W), .MODULUS(M4), .CRNS_EN(CRNS_EN)
    ) u_lane_enc_4 (
        .clk(clk), .rst_n(rst_n), .Encode_EN(Encode_EN), .x(x), .r_out(red_r0)
    );

    (* keep_hierarchy = "yes" *) final_alu_residue_lane_encoder #(
        .WIDTH_IN(WIDTH_IN), .RES_W(`FINAL_ALU_RES_W), .MODULUS(M5), .CRNS_EN(CRNS_EN)
    ) u_lane_enc_5 (
        .clk(clk), .rst_n(rst_n), .Encode_EN(Encode_EN), .x(x), .r_out(red_r1)
    );

    always @(posedge clk) begin
        if (!rst_n)
            Encode_Done <= 1'b0;
        else
            Encode_Done <= Encode_EN;
    end

endmodule
