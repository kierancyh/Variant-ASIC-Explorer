`timescale 1ns/1ps
module final_alu_corrector_search #(
    parameter integer WM = 5,
    parameter integer PW = 20
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

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_SCAN = 2'd1;
    localparam [1:0] ST_DONE = 2'd2;

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

    reg [1:0]    state;
    reg [PW-1:0] cand;

    reg [WM-1:0] p0;
    reg [WM-1:0] p1;
    reg [WM-1:0] p2;
    reg [WM-1:0] p3;
    reg [WM-1:0] p4;
    reg [WM-1:0] p5;

    /*
     * Physical-signoff patch:
     * The old RTL used one shared (cand == half_base_q) comparator result to
     * steer all six lane-residue update muxes.  In the routed netlist this
     * became the worst max-slew/max-cap net.  These six kept one-bit registers
     * duplicate that control locally.  They all carry the same value, but each
     * bit is consumed by only one lane update cone, so OpenROAD no longer has
     * to route one long high-load half-hit net across the whole corrector.
     */
    (* keep = "true", dont_touch = "true" *) reg half_hit0_q;
    (* keep = "true", dont_touch = "true" *) reg half_hit1_q;
    (* keep = "true", dont_touch = "true" *) reg half_hit2_q;
    (* keep = "true", dont_touch = "true" *) reg half_hit3_q;
    (* keep = "true", dont_touch = "true" *) reg half_hit4_q;
    (* keep = "true", dont_touch = "true" *) reg half_hit5_q;

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

    wire [PW-1:0] one_pw = {{(PW-1){1'b0}}, 1'b1};
    wire [PW-1:0] cand_plus_one = cand + one_pw;
    wire          last_candidate = (cand_plus_one >= M_base_q);
    wire          next_half_hit = (cand_plus_one == half_base_q);
    wire          base_match = (p0 == lz0) && (p1 == lz1) && (p2 == lz2) && (p3 == lz3);
    wire          corr_this = enable_correction_q && (cmp_count == 3'd1);
    wire          corr_conflict_final = corr_conflict || (corr_found && corr_this && (cand != corr_candidate));
    wire          corr_valid_final = enable_correction_q && (corr_found || corr_this) && !corr_conflict_final;
    wire [PW-1:0] corr_candidate_final = corr_found ? corr_candidate : cand;
    wire [5:0]    corr_mask_final = corr_found ? corr_mask : cmp_mask;
    wire          base_found_final = base_found || base_match;
    wire [PW-1:0] base_candidate_final = base_found ? base_candidate : cand;
    wire [5:0]    base_mask_final = base_found ? base_mask : cmp_mask;
    wire [2:0]    base_count_final = base_found ? base_count : cmp_count;

    // usable_subset_bitmap is intentionally retained in the interface for
    // compatibility with older wrappers. The current sequential corrector scans
    // candidates directly and does not need the precomputed subset mask.

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

    /*
     * Reset-minimal control block.
     * Only state/done are reset here.  Work registers live in the separate
     * no-reset block below.  This avoids the previous synthesis pattern where
     * rst_n was folded into the self-hold mux for almost every corrector flop,
     * creating high-load reset/state mux-select nets in signoff.
     */
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        if (M_base == {PW{1'b0}})
                            state <= ST_DONE;
                        else
                            state <= ST_SCAN;
                    end
                end

                ST_SCAN: begin
                    if (!enable_detection_q) begin
                        state <= ST_DONE;
                    end else if (cmp_count == 3'd0) begin
                        state <= ST_DONE;
                    end else if (last_candidate) begin
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

    /* Datapath/status block: deliberately no reset gating. */
    always @(posedge clk) begin
        case (state)
            ST_IDLE: begin
                if (start) begin
                    cand <= {PW{1'b0}};
                    p0 <= {WM{1'b0}}; p1 <= {WM{1'b0}}; p2 <= {WM{1'b0}};
                    p3 <= {WM{1'b0}}; p4 <= {WM{1'b0}}; p5 <= {WM{1'b0}};

                    half_hit0_q <= ({PW{1'b0}} == (M_base >> 1));
                    half_hit1_q <= ({PW{1'b0}} == (M_base >> 1));
                    half_hit2_q <= ({PW{1'b0}} == (M_base >> 1));
                    half_hit3_q <= ({PW{1'b0}} == (M_base >> 1));
                    half_hit4_q <= ({PW{1'b0}} == (M_base >> 1));
                    half_hit5_q <= ({PW{1'b0}} == (M_base >> 1));

                    corr_found     <= 1'b0;
                    corr_conflict  <= 1'b0;
                    corr_candidate <= {PW{1'b0}};
                    corr_mask      <= 6'd0;
                    base_found     <= 1'b0;
                    base_candidate <= {PW{1'b0}};
                    base_mask      <= 6'd0;
                    base_count     <= 3'd0;

                    enable_detection_q  <= enable_detection;
                    enable_correction_q <= enable_correction;
                    M_base_q            <= M_base;
                    half_base_q         <= (M_base >> 1);
                    lm0 <= m0; lm1 <= m1; lm2 <= m2;
                    lm3 <= m3; lm4 <= m4; lm5 <= m5;
                    lz0 <= z0; lz1 <= z1; lz2 <= z2;
                    lz3 <= z3; lz4 <= z4; lz5 <= z5;

                    if (M_base == {PW{1'b0}}) begin
                        residue_error            <= 1'b1;
                        corrected_success        <= 1'b0;
                        uncorrectable            <= 1'b1;
                        corrected_lane_mask      <= 6'd0;
                        mismatch_mask_out        <= 6'd0;
                        mismatch_count_out       <= 3'd0;
                        corrected_candidate_base <= {PW{1'b0}};
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
                end else if (cmp_count == 3'd0) begin
                    // A clean all-lane match is unique enough to stop early.
                    residue_error            <= 1'b0;
                    corrected_success        <= 1'b0;
                    uncorrectable            <= 1'b0;
                    corrected_lane_mask      <= 6'd0;
                    mismatch_mask_out        <= 6'd0;
                    mismatch_count_out       <= 3'd0;
                    corrected_candidate_base <= cand;
                end else begin
                    if (!base_found && base_match) begin
                        base_found     <= 1'b1;
                        base_candidate <= cand;
                        base_mask      <= cmp_mask;
                        base_count     <= cmp_count;
                    end

                    if (corr_this) begin
                        if (!corr_found) begin
                            corr_found     <= 1'b1;
                            corr_candidate <= cand;
                            corr_mask      <= cmp_mask;
                        end else if (cand != corr_candidate) begin
                            corr_conflict <= 1'b1;
                        end
                    end

                    if (last_candidate) begin
                        if (corr_valid_final) begin
                            residue_error            <= 1'b1;
                            corrected_success        <= 1'b1;
                            uncorrectable            <= 1'b0;
                            corrected_lane_mask      <= corr_mask_final;
                            mismatch_mask_out        <= corr_mask_final;
                            mismatch_count_out       <= 3'd1;
                            corrected_candidate_base <= corr_candidate_final;
                        end else if (base_found_final) begin
                            residue_error            <= (base_count_final != 3'd0);
                            corrected_success        <= 1'b0;
                            uncorrectable            <= enable_correction_q && (base_count_final > 3'd1);
                            corrected_lane_mask      <= 6'd0;
                            mismatch_mask_out        <= base_mask_final;
                            mismatch_count_out       <= base_count_final;
                            corrected_candidate_base <= base_candidate_final;
                        end else begin
                            residue_error            <= 1'b1;
                            corrected_success        <= 1'b0;
                            uncorrectable            <= enable_correction_q;
                            corrected_lane_mask      <= 6'd0;
                            mismatch_mask_out        <= cmp_mask;
                            mismatch_count_out       <= cmp_count;
                            corrected_candidate_base <= cand;
                        end
                    end else begin
                        cand <= cand_plus_one;
                        half_hit0_q <= next_half_hit;
                        half_hit1_q <= next_half_hit;
                        half_hit2_q <= next_half_hit;
                        half_hit3_q <= next_half_hit;
                        half_hit4_q <= next_half_hit;
                        half_hit5_q <= next_half_hit;

                        if (half_hit0_q) begin
                            if ((lm0 <= 1) || (p0 == {WM{1'b0}})) p0 <= {WM{1'b0}}; else p0 <= lm0 - p0;
                        end else begin
                            if ((lm0 <= 1) || ((p0 + {{(WM-1){1'b0}},1'b1}) >= lm0)) p0 <= {WM{1'b0}}; else p0 <= p0 + {{(WM-1){1'b0}},1'b1};
                        end

                        if (half_hit1_q) begin
                            if ((lm1 <= 1) || (p1 == {WM{1'b0}})) p1 <= {WM{1'b0}}; else p1 <= lm1 - p1;
                        end else begin
                            if ((lm1 <= 1) || ((p1 + {{(WM-1){1'b0}},1'b1}) >= lm1)) p1 <= {WM{1'b0}}; else p1 <= p1 + {{(WM-1){1'b0}},1'b1};
                        end

                        if (half_hit2_q) begin
                            if ((lm2 <= 1) || (p2 == {WM{1'b0}})) p2 <= {WM{1'b0}}; else p2 <= lm2 - p2;
                        end else begin
                            if ((lm2 <= 1) || ((p2 + {{(WM-1){1'b0}},1'b1}) >= lm2)) p2 <= {WM{1'b0}}; else p2 <= p2 + {{(WM-1){1'b0}},1'b1};
                        end

                        if (half_hit3_q) begin
                            if ((lm3 <= 1) || (p3 == {WM{1'b0}})) p3 <= {WM{1'b0}}; else p3 <= lm3 - p3;
                        end else begin
                            if ((lm3 <= 1) || ((p3 + {{(WM-1){1'b0}},1'b1}) >= lm3)) p3 <= {WM{1'b0}}; else p3 <= p3 + {{(WM-1){1'b0}},1'b1};
                        end

                        if (half_hit4_q) begin
                            if ((lm4 <= 1) || (p4 == {WM{1'b0}})) p4 <= {WM{1'b0}}; else p4 <= lm4 - p4;
                        end else begin
                            if ((lm4 <= 1) || ((p4 + {{(WM-1){1'b0}},1'b1}) >= lm4)) p4 <= {WM{1'b0}}; else p4 <= p4 + {{(WM-1){1'b0}},1'b1};
                        end

                        if (half_hit5_q) begin
                            if ((lm5 <= 1) || (p5 == {WM{1'b0}})) p5 <= {WM{1'b0}}; else p5 <= lm5 - p5;
                        end else begin
                            if ((lm5 <= 1) || ((p5 + {{(WM-1){1'b0}},1'b1}) >= lm5)) p5 <= {WM{1'b0}}; else p5 <= p5 + {{(WM-1){1'b0}},1'b1};
                        end
                    end
                end
            end

            default: begin
            end
        endcase
    end

endmodule
