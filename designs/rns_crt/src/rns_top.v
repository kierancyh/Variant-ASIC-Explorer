// Top-Level RNS ALU (Option A: moduli 3,5,7,11)

// External Interface:
//   - clk, rst_n
//   - Start       : start operation
//   - Recon_Mode  : 0 = CRT, 1 = MRC
//   - Op_Sel[1:0] : 00=ADD, 01=SUB, 10=MUL
//   - A_in, B_in  : input operands (unsigned)
//   - Done        : operation complete
//   - X_out       : reconstructed integer result

// Internally instantiates:
//   - rns_cu          : Control Unit FSM
//   - input regs      : A_reg, B_reg, OpSel_reg
//   - 2x rns_encoder  : forward converters for A and B
//   - 4x rns_slice    : modular ALUs (mod 3,5,7,11)
//   - rns_crt_recon   : CRT-based reconstruction
//   - rns_mrc_recon   : MRC-based reconstruction

`timescale 1ns/1ps

module rns_top #(
    parameter WIDTH_IN  = 16,  // bit-width of A_in, B_in, X_out
    // Moduli and residue widths for Option A
    parameter M0 = 3,
    parameter M1 = 5,
    parameter M2 = 7,
    parameter M3 = 11,
    parameter W0 = 2,          // ceil(log2(3))
    parameter W1 = 3,          // ceil(log2(5))
    parameter W2 = 3,          // ceil(log2(7))
    parameter W3 = 4           // ceil(log2(11))
)(
    // Clock & Reset
    input  wire                 clk,
    input  wire                 rst_n,

    // External control
    input  wire                 Start,        // Start operation
    input  wire                 Recon_Mode,   // 0 = CRT, 1 = MRC

    // Operation selection & operands
    input  wire [1:0]           Op_Sel,       // 00=ADD, 01=SUB, 10=MUL
    input  wire [WIDTH_IN-1:0]  A_in,
    input  wire [WIDTH_IN-1:0]  B_in,

    // Outputs
    output wire                 Done,         // From CU
    output wire [WIDTH_IN-1:0]  X_out         // Final reconstructed result
);

    localparam [2:0] S_IDLE = 3'd0;

    // Control wires between Control Unit and Data Path
    wire Load_IN;
    wire Encode_EN;
    wire ALU_EN;
    wire CRT_Start;
    wire MRC_Start;
    wire Out_EN;

    wire Encode_Done_all;
    wire ALU_Done_all;
    wire CRT_Done;
    wire MRC_Done;

    // Debug: CU state
    wire [2:0] CU_state_dbg;

    // Two-stage external input capture:
    // 1) request regs sample external inputs once when Start is accepted in IDLE
    // 2) active datapath regs load from request regs on Load_IN
    reg [WIDTH_IN-1:0] A_req, B_req;
    reg [1:0]          OpSel_req;

    reg [WIDTH_IN-1:0] A_reg, B_reg;
    reg [1:0]          OpSel_reg;

    wire accept_start = Start && (CU_state_dbg == S_IDLE);

    always @(posedge clk) begin
        if (accept_start) begin
            A_req     <= A_in;
            B_req     <= B_in;
            OpSel_req <= Op_Sel;
        end

        if (Load_IN) begin
            A_reg     <= A_req;
            B_reg     <= B_req;
            OpSel_reg <= OpSel_req;
        end
    end

    // Control Unit
    rns_cu u_cu (
        .clk         (clk),
        .rst_n       (rst_n),
        .Start       (Start),
        .Recon_Mode  (Recon_Mode),
        .Done        (Done),
        .CU_state_dbg(CU_state_dbg),

        .Encode_Done (Encode_Done_all),
        .ALU_Done    (ALU_Done_all),
        .CRT_Done    (CRT_Done),
        .MRC_Done    (MRC_Done),

        .Load_IN     (Load_IN),
        .Encode_EN   (Encode_EN),
        .ALU_EN      (ALU_EN),
        .CRT_Start   (CRT_Start),
        .MRC_Start   (MRC_Start),
        .Out_EN      (Out_EN)
    );

    // Encoders: A_reg and B_reg -> residues
    // Residues for A
    wire [W0-1:0] a_r0;
    wire [W1-1:0] a_r1;
    wire [W2-1:0] a_r2;
    wire [W3-1:0] a_r3;
    wire          Encode_Done_A;

    // Residues for B
    wire [W0-1:0] b_r0;
    wire [W1-1:0] b_r1;
    wire [W2-1:0] b_r2;
    wire [W3-1:0] b_r3;
    wire          Encode_Done_B;

    // Encoder for A
    rns_encoder #(
        .WIDTH_IN (WIDTH_IN),
        .M0       (M0),
        .M1       (M1),
        .M2       (M2),
        .M3       (M3),
        .W0       (W0),
        .W1       (W1),
        .W2       (W2),
        .W3       (W3)
    ) u_enc_a (
        .clk        (clk),
        .rst_n      (rst_n),
        .Encode_EN  (Encode_EN),
        .x          (A_reg),
        .Encode_Done(Encode_Done_A),
        .r0         (a_r0),
        .r1         (a_r1),
        .r2         (a_r2),
        .r3         (a_r3)
    );

    // Encoder for B
    rns_encoder #(
        .WIDTH_IN (WIDTH_IN),
        .M0       (M0),
        .M1       (M1),
        .M2       (M2),
        .M3       (M3),
        .W0       (W0),
        .W1       (W1),
        .W2       (W2),
        .W3       (W3)
    ) u_enc_b (
        .clk        (clk),
        .rst_n      (rst_n),
        .Encode_EN  (Encode_EN),
        .x          (B_reg),
        .Encode_Done(Encode_Done_B),
        .r0         (b_r0),
        .r1         (b_r1),
        .r2         (b_r2),
        .r3         (b_r3)
    );

    // Both encoders must finish
    assign Encode_Done_all = Encode_Done_A & Encode_Done_B;

    // Modular ALU slices (per modulus)
    wire [W0-1:0] z_r0;
    wire [W1-1:0] z_r1;
    wire [W2-1:0] z_r2;
    wire [W3-1:0] z_r3;

    wire slice0_done;
    wire slice1_done;
    wire slice2_done;
    wire slice3_done;

    // Slice for modulus M0 = 3
    rns_slice #(
        .MODULUS (M0),
        .WIDTH   (W0)
    ) u_slice0 (
        .clk      (clk),
        .rst_n    (rst_n),
        .ALU_EN   (ALU_EN),
        .op_sel   (OpSel_reg),
        .a        (a_r0),
        .b        (b_r0),
        .y        (z_r0),
        .ALU_Done (slice0_done)
    );

    // Slice for modulus M1 = 5
    rns_slice #(
        .MODULUS (M1),
        .WIDTH   (W1)
    ) u_slice1 (
        .clk      (clk),
        .rst_n    (rst_n),
        .ALU_EN   (ALU_EN),
        .op_sel   (OpSel_reg),
        .a        (a_r1),
        .b        (b_r1),
        .y        (z_r1),
        .ALU_Done (slice1_done)
    );

    // Slice for modulus M2 = 7
    rns_slice #(
        .MODULUS (M2),
        .WIDTH   (W2)
    ) u_slice2 (
        .clk      (clk),
        .rst_n    (rst_n),
        .ALU_EN   (ALU_EN),
        .op_sel   (OpSel_reg),
        .a        (a_r2),
        .b        (b_r2),
        .y        (z_r2),
        .ALU_Done (slice2_done)
    );

    // Slice for modulus M3 = 11
    rns_slice #(
        .MODULUS (M3),
        .WIDTH   (W3)
    ) u_slice3 (
        .clk      (clk),
        .rst_n    (rst_n),
        .ALU_EN   (ALU_EN),
        .op_sel   (OpSel_reg),
        .a        (a_r3),
        .b        (b_r3),
        .y        (z_r3),
        .ALU_Done (slice3_done)
    );

    // All slices must finish
    assign ALU_Done_all = slice0_done & slice1_done & slice2_done & slice3_done;

    // Reconstruction Block (CRT and MRC)
    wire [WIDTH_IN-1:0] X_crt;
    wire [WIDTH_IN-1:0] X_mrc;

    // CRT reconstructor
    rns_crt_recon #(
        .W0        (W0),
        .W1        (W1),
        .W2        (W2),
        .W3        (W3),
        .OUT_WIDTH (WIDTH_IN)
    ) u_crt (
        .clk       (clk),
        .rst_n     (rst_n),
        .CRT_Start (CRT_Start),
        .r0        (z_r0),
        .r1        (z_r1),
        .r2        (z_r2),
        .r3        (z_r3),
        .X_out     (X_crt),
        .CRT_Done  (CRT_Done)
    );

    // MRC reconstructor
    rns_mrc_recon #(
        .W0        (W0),
        .W1        (W1),
        .W2        (W2),
        .W3        (W3),
        .OUT_WIDTH (WIDTH_IN)
    ) u_mrc (
        .clk       (clk),
        .rst_n     (rst_n),
        .MRC_Start (MRC_Start),
        .r0        (z_r0),
        .r1        (z_r1),
        .r2        (z_r2),
        .r3        (z_r3),
        .X_out     (X_mrc),
        .MRC_Done  (MRC_Done)
    );

    // Final output register (no async reset; control-only reset style)
    reg [WIDTH_IN-1:0] X_reg;

    always @(posedge clk) begin
        if (Out_EN) begin
            if (Recon_Mode == 1'b0)
                X_reg <= X_crt;
            else
                X_reg <= X_mrc;
        end
    end

    assign X_out = X_reg;

endmodule
