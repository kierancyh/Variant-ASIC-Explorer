`timescale 1ns/1ps
`include "src/final_alu_cfg.svh"

module final_alu_top #(
    parameter WIDTH_IN  = `FINAL_ALU_DATA_W,
    parameter M0 = `FINAL_ALU_BASE_MOD_0,
    parameter M1 = `FINAL_ALU_BASE_MOD_1,
    parameter M2 = `FINAL_ALU_BASE_MOD_2,
    parameter M3 = `FINAL_ALU_BASE_MOD_3,
    parameter M4 = `FINAL_ALU_RED_MOD_0,
    parameter M5 = `FINAL_ALU_RED_MOD_1,
    parameter W0 = 2,
    parameter W1 = 3,
    parameter W2 = 3,
    parameter W3 = 4,
    parameter W4 = 4,
    parameter W5 = 5,
    parameter CRNS_EN         = 1,
    parameter CENTERED_OUT_EN = 1
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        Start,
    input  wire [1:0]                  Op_Sel,
    input  wire signed [WIDTH_IN-1:0]  A_in,
    input  wire signed [WIDTH_IN-1:0]  B_in,
    output wire                        Done,
    output wire signed [WIDTH_IN-1:0]  X_out,
    output wire                        Error_Detected,
    output wire                        Corrected,
    output wire                        Valid
);

    localparam integer N_BASE = `FINAL_ALU_N_BASE;
    localparam integer N_RED  = `FINAL_ALU_N_RED;
    localparam integer RES_W  = `FINAL_ALU_RES_W;


    wire Load_IN, Encode_EN, ALU_EN, Recon_Start, Correct_Start, Out_EN;
    wire Encode_Done_all, Recon_Done, Correct_Done;
    wire [3:0] CU_state_dbg;

    reg signed [WIDTH_IN-1:0] A_req, B_req;
    reg [1:0]                 OpSel_req;
    reg signed [WIDTH_IN-1:0] A_reg, B_reg;
    reg [1:0]                 OpSel_reg;
    wire signed [RES_W-1:0] a_r0, a_r1, a_r2, a_r3, a_r4, a_r5;
    wire signed [RES_W-1:0] b_r0, b_r1, b_r2, b_r3, b_r4, b_r5;
    wire signed [RES_W-1:0] recon_r0, recon_r1, recon_r2, recon_r3;
    wire [N_BASE+N_RED-1:0] slice_done_vec;
    wire Encode_Done_A, Encode_Done_B;
    wire ALU_Done_all;
    // Compatibility/debug aliases kept intentionally for the existing benches,
    // console trace, and Cocotb fault injection hooks.

    wire signed [RES_W-1:0] z_r0;
    wire signed [RES_W-1:0] z_r1;
    wire signed [RES_W-1:0] z_r2;
    wire signed [RES_W-1:0] z_r3;
    wire signed [RES_W-1:0] z_r4;
    wire signed [RES_W-1:0] z_r5;

    wire slice0_done, slice1_done, slice2_done, slice3_done, slice4_done, slice5_done;
    wire signed [RES_W-1:0] corr_r0;
    wire signed [RES_W-1:0] corr_r1;
    wire signed [RES_W-1:0] corr_r2;
    wire signed [RES_W-1:0] corr_r3;

    wire                 Error_now;
    wire                 Corrected_now;
    wire                 Valid_now;
    wire signed [WIDTH_IN-1:0] X_base_pre;
    wire signed [WIDTH_IN-1:0] X_final_post;
    wire recon_post_sel = (CU_state_dbg == 4'd6);


    always @(posedge clk) begin
        A_req     <= A_in;
        B_req     <= B_in;
        OpSel_req <= Op_Sel;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            A_reg     <= '0;
            B_reg     <= '0;
            OpSel_reg <= 2'b00;
        end else if (Load_IN) begin
            A_reg     <= A_req;
            B_reg     <= B_req;
            OpSel_reg <= OpSel_req;
        end
    end

    final_alu_cu u_cu (
        .clk         (clk),
        .rst_n       (rst_n),
        .Start       (Start),
        .Done        (Done),
        .CU_state_dbg(CU_state_dbg),
        .Encode_Done (Encode_Done_all),
        .ALU_Done    (ALU_Done_all),
        .Recon_Done  (Recon_Done),
        .Correct_Done(Correct_Done),
        .Load_IN     (Load_IN),
        .Encode_EN   (Encode_EN),
        .ALU_EN      (ALU_EN),
        .Recon_Start (Recon_Start),
        .Correct_Start(Correct_Start),
        .Out_EN      (Out_EN)
    );

    final_alu_encoder #(
        .WIDTH_IN (WIDTH_IN), .M0(M0), .M1(M1), .M2(M2), .M3(M3), .M4(M4), .M5(M5),
        .CRNS_EN(CRNS_EN)
    ) u_enc_a (
        .clk(clk), .rst_n(rst_n), .Encode_EN(Encode_EN), .x(A_reg),
        .Encode_Done(Encode_Done_A),
        .base_r0(a_r0), .base_r1(a_r1), .base_r2(a_r2), .base_r3(a_r3),
        .red_r0(a_r4), .red_r1(a_r5)
    );

    final_alu_encoder #(
        .WIDTH_IN (WIDTH_IN), .M0(M0), .M1(M1), .M2(M2), .M3(M3), .M4(M4), .M5(M5),
        .CRNS_EN(CRNS_EN)
    ) u_enc_b (
        .clk(clk), .rst_n(rst_n), .Encode_EN(Encode_EN), .x(B_reg),
        .Encode_Done(Encode_Done_B),
        .base_r0(b_r0), .base_r1(b_r1), .base_r2(b_r2), .base_r3(b_r3),
        .red_r0(b_r4), .red_r1(b_r5)
    );

    assign Encode_Done_all = Encode_Done_A & Encode_Done_B;

    // Explicit slice outputs are preserved as named nets so the current benches
    // and Cocotb tests can still inject faults using z_r0..z_r5.
    final_alu_slice #(.MODULUS(M0), .WIDTH(RES_W), .CRNS_EN(CRNS_EN)) u_slice0 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg), .a(a_r0), .b(b_r0), .y(z_r0), .ALU_Done(slice0_done)
    );
    final_alu_slice #(.MODULUS(M1), .WIDTH(RES_W), .CRNS_EN(CRNS_EN)) u_slice1 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg), .a(a_r1), .b(b_r1), .y(z_r1), .ALU_Done(slice1_done)
    );
    final_alu_slice #(.MODULUS(M2), .WIDTH(RES_W), .CRNS_EN(CRNS_EN)) u_slice2 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg), .a(a_r2), .b(b_r2), .y(z_r2), .ALU_Done(slice2_done)
    );
    final_alu_slice #(.MODULUS(M3), .WIDTH(RES_W), .CRNS_EN(CRNS_EN)) u_slice3 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg), .a(a_r3), .b(b_r3), .y(z_r3), .ALU_Done(slice3_done)
    );
    final_alu_slice #(.MODULUS(M4), .WIDTH(RES_W), .CRNS_EN(CRNS_EN)) u_slice4 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg), .a(a_r4), .b(b_r4), .y(z_r4), .ALU_Done(slice4_done)
    );
    final_alu_slice #(.MODULUS(M5), .WIDTH(RES_W), .CRNS_EN(CRNS_EN)) u_slice5 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg), .a(a_r5), .b(b_r5), .y(z_r5), .ALU_Done(slice5_done)
    );

    assign slice_done_vec[0] = slice0_done;
    assign slice_done_vec[1] = slice1_done;
    assign slice_done_vec[2] = slice2_done;
    assign slice_done_vec[3] = slice3_done;
    assign slice_done_vec[4] = slice4_done;
    assign slice_done_vec[5] = slice5_done;
    assign ALU_Done_all      = &slice_done_vec;
    assign recon_r0 = recon_post_sel ? corr_r0 : z_r0;
    assign recon_r1 = recon_post_sel ? corr_r1 : z_r1;
    assign recon_r2 = recon_post_sel ? corr_r2 : z_r2;
    assign recon_r3 = recon_post_sel ? corr_r3 : z_r3;

    final_alu_recon #(
        .OUT_WIDTH(WIDTH_IN)
    ) u_recon (
        .clk(clk),
        .rst_n(rst_n),
        .Recon_Start(Recon_Start),
        .base_r0(recon_r0),
        .base_r1(recon_r1),
        .base_r2(recon_r2),
        .base_r3(recon_r3),
        .X_out(X_final_post),
        .Recon_Done(Recon_Done)
    );

    assign X_base_pre = X_final_post;

    final_alu_corrector #(
        .OUT_WIDTH(WIDTH_IN)
    ) u_corrector (
        .clk(clk),
        .rst_n(rst_n),
        .Correct_Start(Correct_Start),
        .X_base(X_base_pre),
        .base_r0(z_r0),
        .base_r1(z_r1),
        .base_r2(z_r2),
        .base_r3(z_r3),
        .red_r0(z_r4),
        .red_r1(z_r5),
        .corr_base_r0(corr_r0),
        .corr_base_r1(corr_r1),
        .corr_base_r2(corr_r2),
        .corr_base_r3(corr_r3),
        .Error_Detected(Error_now),
        .Corrected(Corrected_now),
        .Valid(Valid_now),
        .Correct_Done(Correct_Done)
    );

    reg signed [WIDTH_IN-1:0] X_reg;
    reg                       Error_reg;
    reg                       Corrected_reg;
    reg                       Valid_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            X_reg         <= '0;
            Error_reg     <= 1'b0;
            Corrected_reg <= 1'b0;
            Valid_reg     <= 1'b0;
        end else if (Out_EN) begin
            X_reg         <= X_final_post;
            Error_reg     <= Error_now;
            Corrected_reg <= Corrected_now;
            Valid_reg     <= Valid_now;
        end
    end

    assign X_out          = X_reg;
    assign Error_Detected = Error_reg;
    assign Corrected      = Corrected_reg;
    assign Valid          = Valid_reg;

endmodule
