`timescale 1ns/1ps
module final_alu_range_check #(
    parameter integer XW = 24,
    parameter integer PW = 20
)(
    input  wire signed [(2*XW)-1:0] raw_true,
    input  wire [PW-1:0]            M_base,
    input  wire [PW-1:0]            half_range,
    input  wire [PW-1:0]            candidate_base,
    output reg                      range_error,
    output reg  signed [XW-1:0]     x_centered
);

    reg signed [(2*XW)-1:0] half_ext;
    reg signed [(2*XW)-1:0] neg_half_ext;
    reg signed [PW:0] centered_temp;
    reg signed [XW-1:0] centered_ext;

    always @* begin
        half_ext = $signed({{((2*XW)-PW){1'b0}}, half_range});
        neg_half_ext = -half_ext;
        range_error = (raw_true > half_ext) || (raw_true < neg_half_ext);

        if (candidate_base > half_range)
            centered_temp = $signed({1'b0, candidate_base}) - $signed({1'b0, M_base});
        else
            centered_temp = $signed({1'b0, candidate_base});

        centered_ext = {{(XW-(PW+1)){centered_temp[PW]}}, centered_temp};
        x_centered = centered_ext;
    end

endmodule
