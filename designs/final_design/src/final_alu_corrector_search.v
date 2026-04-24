`timescale 1ns/1ps
module final_alu_corrector_search #(
    parameter integer WM = 5,
    parameter integer PW = 32
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire                 enable_detection,
    input  wire                 enable_correction,
    input  wire [6*WM-1:0]      z_res_flat,
    input  wire [PW-1:0]        M_base,
    input  wire [14:0]          usable_subset_bitmap,
    input  wire [WM-1:0]        m0,
    input  wire [WM-1:0]        m1,
    input  wire [WM-1:0]        m2,
    input  wire [WM-1:0]        m3,
    input  wire [WM-1:0]        m4,
    input  wire [WM-1:0]        m5,
    output reg                  done,
    output reg                  residue_error,
    output reg                  corrected_success,
    output reg                  uncorrectable,
    output reg  [5:0]           corrected_lane_mask,
    output reg  [5:0]           mismatch_mask_out,
    output reg  [2:0]           mismatch_count_out,
    output reg  [PW-1:0]        corrected_candidate_base
);

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_SCAN = 3'd1;
    localparam [2:0] ST_DONE = 3'd2;

    wire [WM-1:0] z0 = z_res_flat[(0*WM)+:WM];
    wire [WM-1:0] z1 = z_res_flat[(1*WM)+:WM];
    wire [WM-1:0] z2 = z_res_flat[(2*WM)+:WM];
    wire [WM-1:0] z3 = z_res_flat[(3*WM)+:WM];
    wire [WM-1:0] z4 = z_res_flat[(4*WM)+:WM];
    wire [WM-1:0] z5 = z_res_flat[(5*WM)+:WM];

    reg          enable_detection_q;
    reg          enable_correction_q;
    reg [PW-1:0] M_base_q;
    reg [PW-1:0] half_base_q;
    reg [WM-1:0] lm0, lm1, lm2, lm3, lm4, lm5;
    reg [WM-1:0] lz0, lz1, lz2, lz3, lz4, lz5;

    reg [2:0]  state;
    reg [PW-1:0] cand;

    reg [WM-1:0] p0;
    reg [WM-1:0] p1;
    reg [WM-1:0] p2;
    reg [WM-1:0] p3;
    reg [WM-1:0] p4;
    reg [WM-1:0] p5;

    reg          clean_found;
    reg          clean_conflict;
    reg [PW-1:0] clean_candidate;
    reg [5:0]    clean_mask;

    reg          corr_found;
    reg          corr_conflict;
    reg [PW-1:0] corr_candidate;
    reg [5:0]    corr_mask;

    reg          base_found;
    reg [PW-1:0] base_candidate;
    reg [5:0]    base_mask;
    reg [2:0]    base_count;

    reg [5:0] cmp_mask;
    reg [2:0] cmp_count;

    always @(*) begin
        cmp_mask  = 6'd0;
        cmp_count = 3'd0;

        if (p0 != lz0) begin cmp_mask[0] = 1'b1; cmp_count = cmp_count + 3'd1; end
        if (p1 != lz1) begin cmp_mask[1] = 1'b1; cmp_count = cmp_count + 3'd1; end
        if (p2 != lz2) begin cmp_mask[2] = 1'b1; cmp_count = cmp_count + 3'd1; end
        if (p3 != lz3) begin cmp_mask[3] = 1'b1; cmp_count = cmp_count + 3'd1; end
        if (p4 != lz4) begin cmp_mask[4] = 1'b1; cmp_count = cmp_count + 3'd1; end
        if (p5 != lz5) begin cmp_mask[5] = 1'b1; cmp_count = cmp_count + 3'd1; end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        cand <= {PW{1'b0}};
                        p0 <= {WM{1'b0}}; p1 <= {WM{1'b0}}; p2 <= {WM{1'b0}};
                        p3 <= {WM{1'b0}}; p4 <= {WM{1'b0}}; p5 <= {WM{1'b0}};

                        clean_found <= 1'b0;
                        clean_conflict <= 1'b0;
                        clean_candidate <= {PW{1'b0}};
                        clean_mask <= 6'd0;
                        corr_found <= 1'b0;
                        corr_conflict <= 1'b0;
                        corr_candidate <= {PW{1'b0}};
                        corr_mask <= 6'd0;
                        base_found <= 1'b0;
                        base_candidate <= {PW{1'b0}};
                        base_mask <= 6'd0;
                        base_count <= 3'd0;

                        enable_detection_q <= enable_detection;
                        enable_correction_q <= enable_correction;
                        M_base_q            <= M_base;
                        half_base_q         <= (M_base >> 1);
                        lm0 <= m0; lm1 <= m1; lm2 <= m2;
                        lm3 <= m3; lm4 <= m4; lm5 <= m5;
                        lz0 <= z0; lz1 <= z1; lz2 <= z2;
                        lz3 <= z3; lz4 <= z4; lz5 <= z5;

                        if (M_base == 0) begin
                            residue_error            <= 1'b1;
                            corrected_success        <= 1'b0;
                            uncorrectable            <= 1'b1;
                            corrected_lane_mask      <= 6'd0;
                            mismatch_mask_out        <= 6'd0;
                            mismatch_count_out       <= 3'd0;
                            corrected_candidate_base <= {PW{1'b0}};
                            state                    <= ST_DONE;
                        end else begin
                            state <= ST_SCAN;
                        end
                    end
                end

                ST_SCAN: begin
                    if (!enable_detection_q) begin
                        residue_error            <= 1'b0;
                        corrected_success        <= 1'b0;
                        uncorrectable            <= 1'b0;
                        corrected_lane_mask      <= 6'd0;
                        mismatch_mask_out        <= 6'd0;
                        mismatch_count_out       <= 3'd0;
                        corrected_candidate_base <= cand;
                        state                    <= ST_DONE;
                    end else if (cmp_count == 3'd0) begin
                        // A unique clean candidate is enough. Stop early so large reconfigured bases do not timeout.
                        residue_error            <= 1'b0;
                        corrected_success        <= 1'b0;
                        uncorrectable            <= 1'b0;
                        corrected_lane_mask      <= 6'd0;
                        mismatch_mask_out        <= 6'd0;
                        mismatch_count_out       <= 3'd0;
                        corrected_candidate_base <= cand;
                        state                    <= ST_DONE;
                    end else begin
                        // Keep the unique base-domain candidate as a safe scalar fallback.
                        // This preserves range-error behaviour: base lanes may reconstruct a valid
                        // modulo-M_base scalar even when redundant lanes disagree because the true
                        // arithmetic result exceeded the signed RRNS range.
                        if (!base_found && (p0 == lz0) && (p1 == lz1) && (p2 == lz2) && (p3 == lz3)) begin
                            base_found     <= 1'b1;
                            base_candidate <= cand;
                            base_mask      <= cmp_mask;
                            base_count     <= cmp_count;
                        end

                        if (enable_correction_q && (cmp_count == 3'd1)) begin
                            if (!corr_found) begin
                                corr_found     <= 1'b1;
                                corr_candidate <= cand;
                                corr_mask      <= cmp_mask;
                            end else if (cand != corr_candidate) begin
                                corr_conflict <= 1'b1;
                            end
                        end

                        if ((cand + {{(PW-1){1'b0}},1'b1}) >= M_base_q) begin
                            if (enable_correction_q && corr_found && !corr_conflict) begin
                                residue_error            <= 1'b1;
                                corrected_success        <= 1'b1;
                                uncorrectable            <= 1'b0;
                                corrected_lane_mask      <= corr_mask;
                                mismatch_mask_out        <= corr_mask;
                                mismatch_count_out       <= 3'd1;
                                corrected_candidate_base <= corr_candidate;
                            end else if (base_found) begin
                                residue_error            <= (base_count != 3'd0);
                                corrected_success        <= 1'b0;
                                uncorrectable            <= enable_correction_q && (base_count > 3'd1);
                                corrected_lane_mask      <= 6'd0;
                                mismatch_mask_out        <= base_mask;
                                mismatch_count_out       <= base_count;
                                corrected_candidate_base <= base_candidate;
                            end else begin
                                residue_error            <= 1'b1;
                                corrected_success        <= 1'b0;
                                uncorrectable            <= enable_correction_q;
                                corrected_lane_mask      <= 6'd0;
                                mismatch_mask_out        <= cmp_mask;
                                mismatch_count_out       <= cmp_count;
                                corrected_candidate_base <= cand;
                            end
                            state <= ST_DONE;
                        end else begin
                            cand <= cand + {{(PW-1){1'b0}},1'b1};

                            if (cand == half_base_q) begin
                                if ((lm0 <= 1) || (p0 == {WM{1'b0}})) p0 <= {WM{1'b0}}; else p0 <= lm0 - p0;
                                if ((lm1 <= 1) || (p1 == {WM{1'b0}})) p1 <= {WM{1'b0}}; else p1 <= lm1 - p1;
                                if ((lm2 <= 1) || (p2 == {WM{1'b0}})) p2 <= {WM{1'b0}}; else p2 <= lm2 - p2;
                                if ((lm3 <= 1) || (p3 == {WM{1'b0}})) p3 <= {WM{1'b0}}; else p3 <= lm3 - p3;
                                if ((lm4 <= 1) || (p4 == {WM{1'b0}})) p4 <= {WM{1'b0}}; else p4 <= lm4 - p4;
                                if ((lm5 <= 1) || (p5 == {WM{1'b0}})) p5 <= {WM{1'b0}}; else p5 <= lm5 - p5;
                            end else begin
                                if ((lm0 <= 1) || ((p0 + {{(WM-1){1'b0}},1'b1}) >= lm0)) p0 <= {WM{1'b0}}; else p0 <= p0 + {{(WM-1){1'b0}},1'b1};
                                if ((lm1 <= 1) || ((p1 + {{(WM-1){1'b0}},1'b1}) >= lm1)) p1 <= {WM{1'b0}}; else p1 <= p1 + {{(WM-1){1'b0}},1'b1};
                                if ((lm2 <= 1) || ((p2 + {{(WM-1){1'b0}},1'b1}) >= lm2)) p2 <= {WM{1'b0}}; else p2 <= p2 + {{(WM-1){1'b0}},1'b1};
                                if ((lm3 <= 1) || ((p3 + {{(WM-1){1'b0}},1'b1}) >= lm3)) p3 <= {WM{1'b0}}; else p3 <= p3 + {{(WM-1){1'b0}},1'b1};
                                if ((lm4 <= 1) || ((p4 + {{(WM-1){1'b0}},1'b1}) >= lm4)) p4 <= {WM{1'b0}}; else p4 <= p4 + {{(WM-1){1'b0}},1'b1};
                                if ((lm5 <= 1) || ((p5 + {{(WM-1){1'b0}},1'b1}) >= lm5)) p5 <= {WM{1'b0}}; else p5 <= p5 + {{(WM-1){1'b0}},1'b1};
                            end
                        end
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
