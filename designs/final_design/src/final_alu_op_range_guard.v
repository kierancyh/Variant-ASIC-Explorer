`timescale 1ns/1ps
// V50A: sequential ADD/SUB/MUL mathematical range guard.
// This module only determines whether the true scalar result is outside
// [-half_range, +half_range]. The RRNS residue datapath still computes the
// actual operation result.
module final_alu_op_range_guard #(
    parameter integer XW = 24,
    parameter integer PW = 20
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     start,
    input  wire [1:0]               op_sel,
    input  wire signed [XW-1:0]     A_in,
    input  wire signed [XW-1:0]     B_in,
    input  wire [PW-1:0]            half_range,
    output reg                      done,
    output reg                      raw_range_error
);

    localparam [2:0]
        ST_IDLE      = 3'd0,
        ST_MUL_INIT1 = 3'd1,
        ST_MUL_INIT2 = 3'd2,
        ST_MUL_ACC   = 3'd3,
        ST_MUL_MCAND = 3'd4,
        ST_MUL_MULT  = 3'd5;

    localparam [PW:0] MUL_SAT_MAX    = {1'b1, {PW{1'b0}}};
    localparam [5:0]  MUL_LAST_COUNT = PW;

    reg [2:0]  state;
    reg [PW:0] mul_acc_sat_reg;
    reg [PW:0] mul_mcand_sat_reg;
    reg [PW:0] mul_mult_sat_reg;
    reg [5:0]  mul_count_reg;

    wire signed [XW:0] add_true_wire = {A_in[XW-1], A_in} + {B_in[XW-1], B_in};
    wire signed [XW:0] sub_true_wire = {A_in[XW-1], A_in} - {B_in[XW-1], B_in};
    wire signed [XW:0] half_range_xw_wire = $signed({1'b0, {{(XW-PW){1'b0}}, half_range}});
    wire signed [XW:0] neg_half_range_xw_wire = -half_range_xw_wire;
    wire add_range_error_wire = (add_true_wire > half_range_xw_wire) ||
                                (add_true_wire < neg_half_range_xw_wire);
    wire sub_range_error_wire = (sub_true_wire > half_range_xw_wire) ||
                                (sub_true_wire < neg_half_range_xw_wire);

    wire [XW-1:0] a_abs_wire = A_in[XW-1] ? ((~A_in) + {{(XW-1){1'b0}}, 1'b1}) : A_in;
    wire [XW-1:0] b_abs_wire = B_in[XW-1] ? ((~B_in) + {{(XW-1){1'b0}}, 1'b1}) : B_in;
    wire [XW:0]   a_abs_ext_wire = {1'b0, a_abs_wire};
    wire [XW:0]   b_abs_ext_wire = {1'b0, b_abs_wire};
    wire [XW:0]   mul_sat_max_ext_wire = {{(XW-PW){1'b0}}, MUL_SAT_MAX};
    wire [PW:0]   a_abs_sat_wire = (a_abs_ext_wire > mul_sat_max_ext_wire) ? MUL_SAT_MAX : a_abs_ext_wire[PW:0];
    wire [PW:0]   b_abs_sat_wire = (b_abs_ext_wire > mul_sat_max_ext_wire) ? MUL_SAT_MAX : b_abs_ext_wire[PW:0];

    wire [PW:0]   mul_addend_sat_wire = mul_mult_sat_reg[0] ? mul_mcand_sat_reg : {(PW+1){1'b0}};
    wire [PW+1:0] mul_acc_sum_wire = {1'b0, mul_acc_sat_reg} + {1'b0, mul_addend_sat_wire};
    wire [PW:0]   mul_acc_next_sat_wire = (mul_acc_sum_wire > {1'b0, MUL_SAT_MAX}) ?
                                          MUL_SAT_MAX : mul_acc_sum_wire[PW:0];
    wire [PW+1:0] mul_mcand_shift_wire = {1'b0, mul_mcand_sat_reg} << 1;
    wire [PW:0]   mul_mcand_next_sat_wire = (mul_mcand_shift_wire > {1'b0, MUL_SAT_MAX}) ?
                                            MUL_SAT_MAX : mul_mcand_shift_wire[PW:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            done            <= 1'b0;
            raw_range_error <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        if (op_sel == 2'b00) begin
                            raw_range_error <= add_range_error_wire;
                            done            <= 1'b1;
                        end else if (op_sel == 2'b01) begin
                            raw_range_error <= sub_range_error_wire;
                            done            <= 1'b1;
                        end else if (op_sel == 2'b10) begin
                            raw_range_error <= 1'b0;
                            mul_acc_sat_reg <= {(PW+1){1'b0}};
                            mul_count_reg   <= 6'd0;
                            state           <= ST_MUL_INIT1;
                        end else begin
                            raw_range_error <= 1'b0;
                            done            <= 1'b1;
                        end
                    end
                end

                ST_MUL_INIT1: begin
                    mul_mcand_sat_reg <= a_abs_sat_wire;
                    state             <= ST_MUL_INIT2;
                end

                ST_MUL_INIT2: begin
                    mul_mult_sat_reg <= b_abs_sat_wire;
                    state            <= ST_MUL_ACC;
                end

                ST_MUL_ACC: begin
                    mul_acc_sat_reg <= mul_acc_next_sat_wire;
                    state           <= ST_MUL_MCAND;
                end

                ST_MUL_MCAND: begin
                    mul_mcand_sat_reg <= mul_mcand_next_sat_wire;
                    state             <= ST_MUL_MULT;
                end

                ST_MUL_MULT: begin
                    mul_mult_sat_reg <= {1'b0, mul_mult_sat_reg[PW:1]};
                    if (mul_count_reg == MUL_LAST_COUNT) begin
                        raw_range_error <= (mul_acc_sat_reg > {1'b0, half_range});
                        done            <= 1'b1;
                        state           <= ST_IDLE;
                    end else begin
                        mul_count_reg <= mul_count_reg + 6'd1;
                        state         <= ST_MUL_ACC;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
