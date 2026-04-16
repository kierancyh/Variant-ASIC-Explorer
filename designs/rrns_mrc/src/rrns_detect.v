`timescale 1ns/1ps
module rrns_detect #(
    parameter RED_MOD   = 13,
    parameter RED_WIDTH = 4,
    parameter X_WIDTH   = 16
)(
    input  wire signed [X_WIDTH-1:0]   X_hat,
    input  wire signed [RED_WIDTH-1:0] r_red,
    output wire                        Error_Detected
);

    integer expected_red;
    integer actual_red;

    function integer norm_mod;
        input integer x;
        input integer m;
        integer t;
        begin
            t = x % m;
            if (t < 0)
                t = t + m;
            norm_mod = t;
        end
    endfunction

    always @* begin
        // Expected redundant residue from reconstructed base-domain result
        expected_red = norm_mod(X_hat, RED_MOD);

        // Actual redundant arithmetic residue, normalized back to standard form
        // so centered residues like -1 are treated as 12 mod 13
        actual_red   = norm_mod(r_red, RED_MOD);
    end

    assign Error_Detected = (expected_red != actual_red);

endmodule