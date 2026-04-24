`timescale 1ns/1ps
module final_alu_slice_runtime #(
    parameter integer WM = 6
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire [1:0]           op_sel,
    input  wire [WM-1:0]        a_res,
    input  wire [WM-1:0]        b_res,
    input  wire [WM-1:0]        modulus,
    output reg                  done,
    output reg  [WM-1:0]        z_res
);

    /*
     * Small sequential lane ALU.
     *
     * The older implementation used a runtime % operator.  Yosys lowered that
     * into a large divider/remainder network, making this block the dominant
     * area after the encoder was slimmed.  This version keeps the same external
     * handshake but reduces by repeated add/subtract over multiple cycles.
     * Latency increases, area drops substantially.
     */

    localparam integer IW = (2*WM) + 4;

    localparam [1:0]
        ST_IDLE = 2'd0,
        ST_FIXN = 2'd1,
        ST_REDU = 2'd2,
        ST_DONE = 2'd3;

    reg [1:0] state;
    reg signed [IW-1:0] work_s;
    reg        [IW-1:0] work_u;
    reg        [IW-1:0] mod_u;

    always @(posedge clk) begin
        if (!rst_n) begin
            state  <= ST_IDLE;
            done   <= 1'b0;
            z_res  <= {WM{1'b0}};
            work_s <= {IW{1'b0}};
            work_u <= {IW{1'b0}};
            mod_u  <= {IW{1'b0}};
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        mod_u <= {{(IW-WM){1'b0}}, modulus};

                        if (modulus == {WM{1'b0}}) begin
                            z_res <= {WM{1'b0}};
                            state <= ST_DONE;
                        end else begin
                            case (op_sel)
                                2'b00: begin
                                    work_s <= $signed({{(IW-WM){1'b0}}, a_res}) +
                                              $signed({{(IW-WM){1'b0}}, b_res});
                                end
                                2'b01: begin
                                    work_s <= $signed({{(IW-WM){1'b0}}, a_res}) -
                                              $signed({{(IW-WM){1'b0}}, b_res});
                                end
                                2'b10: begin
                                    work_s <= $signed({{(IW-WM){1'b0}}, a_res}) *
                                              $signed({{(IW-WM){1'b0}}, b_res});
                                end
                                default: begin
                                    work_s <= {IW{1'b0}};
                                end
                            endcase
                            state <= ST_FIXN;
                        end
                    end
                end

                ST_FIXN: begin
                    if (work_s < 0) begin
                        work_s <= work_s + $signed(mod_u);
                    end else begin
                        work_u <= work_s[IW-1:0];
                        state  <= ST_REDU;
                    end
                end

                ST_REDU: begin
                    if (work_u >= mod_u) begin
                        work_u <= work_u - mod_u;
                    end else begin
                        z_res <= work_u[WM-1:0];
                        state <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
