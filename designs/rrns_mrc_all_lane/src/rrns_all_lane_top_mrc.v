`timescale 1ns/1ps
module rrns_all_lane_top_mrc #(
    parameter WIDTH_IN  = 16,
    parameter M0 = 3,
    parameter M1 = 5,
    parameter M2 = 7,
    parameter M3 = 11,
    parameter M4 = 13,
    parameter M5 = 17,
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

    wire Load_IN;
    wire Encode_EN;
    wire ALU_EN;
    wire CRT_Start;
    wire MRC_Start;
    wire Correct_Start;
    wire Out_EN;

    wire Encode_Done_all;
    wire ALU_Done_all;
    wire CRT_Done;
    wire MRC_Done;
    wire Correct_Done;
    assign CRT_Done = 1'b0;

    wire [3:0] CU_state_dbg;

    reg signed [WIDTH_IN-1:0] A_req, B_req;
    reg [1:0]                 OpSel_req;

    reg signed [WIDTH_IN-1:0] A_reg, B_reg;
    reg [1:0]                 OpSel_reg;

    always @(posedge clk) begin
        A_req     <= A_in;
        B_req     <= B_in;
        OpSel_req <= Op_Sel;
    end

    always @(posedge clk) begin
        if (Load_IN) begin
            A_reg     <= A_req;
            B_reg     <= B_req;
            OpSel_reg <= OpSel_req;
        end
    end

    rrns_all_lane_cu u_cu (
        .clk          (clk),
        .rst_n        (rst_n),
        .Start        (Start),
        .Recon_Mode   (1'b1),
        .Done         (Done),
        .CU_state_dbg (CU_state_dbg),
        .Encode_Done  (Encode_Done_all),
        .ALU_Done     (ALU_Done_all),
        .CRT_Done     (CRT_Done),
        .MRC_Done     (MRC_Done),
        .Correct_Done (Correct_Done),
        .Load_IN      (Load_IN),
        .Encode_EN    (Encode_EN),
        .ALU_EN       (ALU_EN),
        .CRT_Start    (CRT_Start),
        .MRC_Start    (MRC_Start),
        .Correct_Start(Correct_Start),
        .Out_EN       (Out_EN)
    );

    wire signed [W0-1:0] a_r0;
    wire signed [W1-1:0] a_r1;
    wire signed [W2-1:0] a_r2;
    wire signed [W3-1:0] a_r3;
    wire signed [W4-1:0] a_r4;
    wire signed [W5-1:0] a_r5;
    wire                 Encode_Done_A;

    wire signed [W0-1:0] b_r0;
    wire signed [W1-1:0] b_r1;
    wire signed [W2-1:0] b_r2;
    wire signed [W3-1:0] b_r3;
    wire signed [W4-1:0] b_r4;
    wire signed [W5-1:0] b_r5;
    wire                 Encode_Done_B;

    rrns_all_lane_encoder #(
        .WIDTH_IN (WIDTH_IN),
        .M0       (M0), .M1(M1), .M2(M2), .M3(M3), .M4(M4), .M5(M5),
        .W0       (W0), .W1(W1), .W2(W2), .W3(W3), .W4(W4), .W5(W5),
        .CRNS_EN  (CRNS_EN)
    ) u_enc_a (
        .clk(clk), .rst_n(rst_n), .Encode_EN(Encode_EN), .x(A_reg),
        .Encode_Done(Encode_Done_A),
        .r0(a_r0), .r1(a_r1), .r2(a_r2), .r3(a_r3), .r4(a_r4), .r5(a_r5)
    );

    rrns_all_lane_encoder #(
        .WIDTH_IN (WIDTH_IN),
        .M0       (M0), .M1(M1), .M2(M2), .M3(M3), .M4(M4), .M5(M5),
        .W0       (W0), .W1(W1), .W2(W2), .W3(W3), .W4(W4), .W5(W5),
        .CRNS_EN  (CRNS_EN)
    ) u_enc_b (
        .clk(clk), .rst_n(rst_n), .Encode_EN(Encode_EN), .x(B_reg),
        .Encode_Done(Encode_Done_B),
        .r0(b_r0), .r1(b_r1), .r2(b_r2), .r3(b_r3), .r4(b_r4), .r5(b_r5)
    );

    assign Encode_Done_all = Encode_Done_A & Encode_Done_B;

    wire signed [W0-1:0] z_r0;
    wire signed [W1-1:0] z_r1;
    wire signed [W2-1:0] z_r2;
    wire signed [W3-1:0] z_r3;
    wire signed [W4-1:0] z_r4;
    wire signed [W5-1:0] z_r5;

    wire slice0_done, slice1_done, slice2_done, slice3_done, slice4_done, slice5_done;

    rrns_all_lane_slice #(.MODULUS(M0), .WIDTH(W0), .CRNS_EN(CRNS_EN)) u_slice0 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg),
        .a(a_r0), .b(b_r0), .y(z_r0), .ALU_Done(slice0_done)
    );
    rrns_all_lane_slice #(.MODULUS(M1), .WIDTH(W1), .CRNS_EN(CRNS_EN)) u_slice1 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg),
        .a(a_r1), .b(b_r1), .y(z_r1), .ALU_Done(slice1_done)
    );
    rrns_all_lane_slice #(.MODULUS(M2), .WIDTH(W2), .CRNS_EN(CRNS_EN)) u_slice2 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg),
        .a(a_r2), .b(b_r2), .y(z_r2), .ALU_Done(slice2_done)
    );
    rrns_all_lane_slice #(.MODULUS(M3), .WIDTH(W3), .CRNS_EN(CRNS_EN)) u_slice3 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg),
        .a(a_r3), .b(b_r3), .y(z_r3), .ALU_Done(slice3_done)
    );
    rrns_all_lane_slice #(.MODULUS(M4), .WIDTH(W4), .CRNS_EN(CRNS_EN)) u_slice4 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg),
        .a(a_r4), .b(b_r4), .y(z_r4), .ALU_Done(slice4_done)
    );
    rrns_all_lane_slice #(.MODULUS(M5), .WIDTH(W5), .CRNS_EN(CRNS_EN)) u_slice5 (
        .clk(clk), .rst_n(rst_n), .ALU_EN(ALU_EN), .op_sel(OpSel_reg),
        .a(a_r5), .b(b_r5), .y(z_r5), .ALU_Done(slice5_done)
    );

    assign ALU_Done_all =
        slice0_done & slice1_done & slice2_done &
        slice3_done & slice4_done & slice5_done;

    wire signed [W0-1:0] corr_r0_w;
    wire signed [W1-1:0] corr_r1_w;
    wire signed [W2-1:0] corr_r2_w;
    wire signed [W3-1:0] corr_r3_w;
    wire                 base_fault_found_w;
    wire                 Error_now;
    wire                 Corrected_now;
    wire                 Valid_now;

    reg                  use_repaired_base_r;
    reg                  Error_pending_r;
    reg                  Corrected_pending_r;
    reg                  Valid_pending_r;

    wire signed [W0-1:0] recon_r0_w = use_repaired_base_r ? corr_r0_w : z_r0;
    wire signed [W1-1:0] recon_r1_w = use_repaired_base_r ? corr_r1_w : z_r1;
    wire signed [W2-1:0] recon_r2_w = use_repaired_base_r ? corr_r2_w : z_r2;
    wire signed [W3-1:0] recon_r3_w = use_repaired_base_r ? corr_r3_w : z_r3;

    wire signed [WIDTH_IN-1:0] X_recon;

    rrns_all_lane_mrc_recon #(
        .W0(W0), .W1(W1), .W2(W2), .W3(W3), .OUT_WIDTH(WIDTH_IN)
    ) u_mrc (
        .clk(clk),
        .rst_n(rst_n),
        .MRC_Start(MRC_Start),
        .r0(recon_r0_w),
        .r1(recon_r1_w),
        .r2(recon_r2_w),
        .r3(recon_r3_w),
        .X_out(X_recon),
        .MRC_Done(MRC_Done)
    );

    rrns_all_lane_corrector_mrc #(
        .W0(W0), .W1(W1), .W2(W2), .W3(W3), .W4(W4), .W5(W5),
        .OUT_WIDTH(WIDTH_IN)
    ) u_corrector (
        .clk(clk),
        .rst_n(rst_n),
        .Correct_Start(Correct_Start),
        .X_base(X_recon),
        .r0(z_r0), .r1(z_r1), .r2(z_r2), .r3(z_r3), .r4(z_r4), .r5(z_r5),
        .corr_r0(corr_r0_w),
        .corr_r1(corr_r1_w),
        .corr_r2(corr_r2_w),
        .corr_r3(corr_r3_w),
        .Base_Fault_Found(base_fault_found_w),
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
            use_repaired_base_r <= 1'b0;
            Error_pending_r     <= 1'b0;
            Corrected_pending_r <= 1'b0;
            Valid_pending_r     <= 1'b0;
            X_reg               <= '0;
            Error_reg           <= 1'b0;
            Corrected_reg       <= 1'b0;
            Valid_reg           <= 1'b0;
        end else begin
            if (Load_IN) begin
                use_repaired_base_r <= 1'b0;
                Error_pending_r     <= 1'b0;
                Corrected_pending_r <= 1'b0;
                Valid_pending_r     <= 1'b0;
            end

            if (Correct_Done) begin
                use_repaired_base_r <= base_fault_found_w;
                Error_pending_r     <= Error_now;
                Corrected_pending_r <= Corrected_now;
                Valid_pending_r     <= Valid_now;
            end

            if (Out_EN) begin
                X_reg         <= X_recon;
                Error_reg     <= Error_pending_r;
                Corrected_reg <= Corrected_pending_r;
                Valid_reg     <= Valid_pending_r;
            end
        end
    end

    assign X_out          = X_reg;
    assign Error_Detected = Error_reg;
    assign Corrected      = Corrected_reg;
    assign Valid          = Valid_reg;

endmodule
