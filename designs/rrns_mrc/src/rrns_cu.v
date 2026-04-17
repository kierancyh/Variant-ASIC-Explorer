`timescale 1ns/1ps
module rrns_cu (
    input  wire clk,
    input  wire rst_n,
    input  wire Start,
    input  wire Recon_Mode,
    output reg  Done,
    output wire [2:0] CU_state_dbg,
    input  wire Encode_Done,
    input  wire ALU_Done,
    input  wire CRT_Done,
    input  wire MRC_Done,
    output reg  Load_IN,
    output reg  Encode_EN,
    output reg  ALU_EN,
    output reg  CRT_Start,
    output reg  MRC_Start,
    output reg  Corr_Cap,
    output reg  Out_EN
);

    localparam [2:0]
        S_IDLE   = 3'd0,
        S_LOAD   = 3'd1,
        S_ENCODE = 3'd2,
        S_ALU    = 3'd3,
        S_RECON  = 3'd4,
        S_OUT    = 3'd5,
        S_DONE   = 3'd6;

    reg [2:0] state, next_state;
    wire recon_done_sel;
    assign recon_done_sel = (Recon_Mode == 1'b0) ? CRT_Done : MRC_Done;

    always @(posedge clk) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    always @* begin
        next_state = state;
        case (state)
            S_IDLE:   if (Start)          next_state = S_LOAD;
            S_LOAD:                      next_state = S_ENCODE;
            S_ENCODE: if (Encode_Done)    next_state = S_ALU;
            S_ALU:    if (ALU_Done)       next_state = S_RECON;
            S_RECON:  if (recon_done_sel) next_state = S_OUT;
            S_OUT:                       next_state = S_DONE;
            S_DONE:   if (!Start)         next_state = S_IDLE;
            default:                     next_state = S_IDLE;
        endcase
    end

    always @* begin
        Load_IN   = 1'b0;
        Encode_EN = 1'b0;
        ALU_EN    = 1'b0;
        CRT_Start = 1'b0;
        MRC_Start = 1'b0;
        Corr_Cap  = 1'b0;
        Out_EN    = 1'b0;
        Done      = 1'b0;

        case (state)
            S_LOAD:   Load_IN   = 1'b1;
            S_ENCODE: Encode_EN = 1'b1;
            S_ALU:    ALU_EN    = 1'b1;
            S_RECON: begin
                if (Recon_Mode == 1'b0)
                    CRT_Start = 1'b1;
                else
                    MRC_Start = 1'b1;

                if (recon_done_sel)
                    Corr_Cap = 1'b1;
            end
            S_OUT:  Out_EN = 1'b1;
            S_DONE: Done   = 1'b1;
        endcase
    end

    assign CU_state_dbg = state;

endmodule
