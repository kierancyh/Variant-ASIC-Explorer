`timescale 1ns/1ps
// V18 source marker: module renamed to prevent stale corrector source from silently compiling.
// V18 source marker: corrector has no wide input-capture register bank.
module final_alu_corrector_search_v18 #(
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

    /*
     * V15 physical-signoff patch:
     *   - Keep the one-hot sequential candidate scan.
     *   - Remove the large corrector input-capture bank from V14.
     *
     * The top-level wrapper locks configuration writes while Busy is high, so
     * M_base, m0..m5, enable_detection/enable_correction, and z_res_flat are
     * stable for the whole correction operation.  Therefore the corrector uses
     * those stable inputs directly instead of copying them into a wide local
     * input-register bank.
     *
     * Removing that capture bank directly attacks the old wide input-capture
     * mux-select slew cluster.  The datapath also advances its residue counters without
     * using last_candidate as the hold/update select, which attacks the V14
     * _01641_ comparator fanout cluster.
     */
    localparam [6:0] ST_IDLE      = 7'b0000001;
    localparam [6:0] ST_INIT_CTRL = 7'b0000010;
    localparam [6:0] ST_INIT_L01  = 7'b0000100;
    localparam [6:0] ST_INIT_L23  = 7'b0001000;
    localparam [6:0] ST_INIT_L45  = 7'b0010000;
    localparam [6:0] ST_SCAN      = 7'b0100000;
    localparam [6:0] ST_DONE      = 7'b1000000;

    wire [WM-1:0] z0 = z_res_flat[(0*WM)+:WM];
    wire [WM-1:0] z1 = z_res_flat[(1*WM)+:WM];
    wire [WM-1:0] z2 = z_res_flat[(2*WM)+:WM];
    wire [WM-1:0] z3 = z_res_flat[(3*WM)+:WM];
    wire [WM-1:0] z4 = z_res_flat[(4*WM)+:WM];
    wire [WM-1:0] z5 = z_res_flat[(5*WM)+:WM];

    (* keep = "true" *) reg [6:0] state;
    reg [PW-1:0] cand;

    reg [WM-1:0] p0;
    reg [WM-1:0] p1;
    reg [WM-1:0] p2;
    reg [WM-1:0] p3;
    reg [WM-1:0] p4;
    reg [WM-1:0] p5;

    /* V36C: local modulus copies for the scanner.  V36B final antenna
       showed corr_m0_cfg[2] at the top/corrector boundary.  Capture the
       six stable moduli at corrector start so the scan-update comparison
       network is driven by local flops instead of the wrapper copy net. */
    (* keep = "true", dont_touch = "true" *) reg [WM-1:0] m0_q;
    (* keep = "true", dont_touch = "true" *) reg [WM-1:0] m1_q;
    (* keep = "true", dont_touch = "true" *) reg [WM-1:0] m2_q;
    (* keep = "true", dont_touch = "true" *) reg [WM-1:0] m3_q;
    (* keep = "true", dont_touch = "true" *) reg [WM-1:0] m4_q;
    (* keep = "true", dont_touch = "true" *) reg [WM-1:0] m5_q;

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

    wire [PW-1:0] zero_pw = {PW{1'b0}};
    wire [PW-1:0] one_pw  = {{(PW-1){1'b0}}, 1'b1};
    wire [PW-1:0] cand_plus_one = cand + one_pw;
    wire [PW-1:0] half_base_wire = (M_base >> 1);
    wire          last_candidate = (cand_plus_one >= M_base);
    wire          next_half_hit  = (cand_plus_one == half_base_wire);

    wire          base_match = (p0 == z0) && (p1 == z1) && (p2 == z2) && (p3 == z3);
    wire          corr_this = enable_correction && (cmp_count == 3'd1);
    wire          corr_conflict_final = corr_conflict || (corr_found && corr_this && (cand != corr_candidate));
    wire          corr_valid_final = enable_correction && (corr_found || corr_this) && !corr_conflict_final;
    wire [PW-1:0] corr_candidate_final = corr_found ? corr_candidate : cand;
    wire [5:0]    corr_mask_final = corr_found ? corr_mask : cmp_mask;
    wire          base_found_final = base_found || base_match;
    wire [PW-1:0] base_candidate_final = base_found ? base_candidate : cand;
    wire [5:0]    base_mask_final = base_found ? base_mask : cmp_mask;
    wire [2:0]    base_count_final = base_found ? base_count : cmp_count;

    // Retained for wrapper compatibility.  The current scan engine does not
    // need the precomputed subset bitmap.
    wire unused_subset_bitmap = |usable_subset_bitmap;

    always @(*) begin
        cmp_mask  = 6'd0;
        cmp_count = 3'd0;

        if (p0 != z0) begin cmp_mask[0] = 1'b1; cmp_count = cmp_count + 3'd1; end
        if (p1 != z1) begin cmp_mask[1] = 1'b1; cmp_count = cmp_count + 3'd1; end
        if (p2 != z2) begin cmp_mask[2] = 1'b1; cmp_count = cmp_count + 3'd1; end
        if (p3 != z3) begin cmp_mask[3] = 1'b1; cmp_count = cmp_count + 3'd1; end
        if (p4 != z4) begin cmp_mask[4] = 1'b1; cmp_count = cmp_count + 3'd1; end
        if (p5 != z5) begin cmp_mask[5] = 1'b1; cmp_count = cmp_count + 3'd1; end
    end

    /* Reset-minimal control block.  Only state/done reset. */
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        state <= ST_INIT_CTRL;
                    end
                end

                ST_INIT_CTRL: begin
                    if (M_base == zero_pw)
                        state <= ST_DONE;
                    else
                        state <= ST_INIT_L01;
                end

                ST_INIT_L01: begin
                    state <= ST_INIT_L23;
                end

                ST_INIT_L23: begin
                    state <= ST_INIT_L45;
                end

                ST_INIT_L45: begin
                    state <= ST_SCAN;
                end

                ST_SCAN: begin
                    if (!enable_detection) begin
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
                    m0_q <= m0;
                    m1_q <= m1;
                    m2_q <= m2;
                    m3_q <= m3;
                    m4_q <= m4;
                    m5_q <= m5;
                end
            end

            ST_INIT_CTRL: begin
                cand <= zero_pw;

                corr_found     <= 1'b0;
                corr_conflict  <= 1'b0;
                corr_candidate <= zero_pw;
                corr_mask      <= 6'd0;
                base_found     <= 1'b0;
                base_candidate <= zero_pw;
                base_mask      <= 6'd0;
                base_count     <= 3'd0;

                if (M_base == zero_pw) begin
                    residue_error            <= 1'b1;
                    corrected_success        <= 1'b0;
                    uncorrectable            <= 1'b1;
                    corrected_lane_mask      <= 6'd0;
                    mismatch_mask_out        <= 6'd0;
                    mismatch_count_out       <= 3'd0;
                    corrected_candidate_base <= zero_pw;
                end
            end

            ST_INIT_L01: begin
                p0 <= {WM{1'b0}};
                p1 <= {WM{1'b0}};
                half_hit0_q <= (zero_pw == half_base_wire);
                half_hit1_q <= (zero_pw == half_base_wire);
            end

            ST_INIT_L23: begin
                p2 <= {WM{1'b0}};
                p3 <= {WM{1'b0}};
                half_hit2_q <= (zero_pw == half_base_wire);
                half_hit3_q <= (zero_pw == half_base_wire);
            end

            ST_INIT_L45: begin
                p4 <= {WM{1'b0}};
                p5 <= {WM{1'b0}};
                half_hit4_q <= (zero_pw == half_base_wire);
                half_hit5_q <= (zero_pw == half_base_wire);
            end

            ST_SCAN: begin
                if (!enable_detection) begin
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
                            uncorrectable            <= enable_correction && (base_count_final > 3'd1);
                            corrected_lane_mask      <= 6'd0;
                            mismatch_mask_out        <= base_mask_final;
                            mismatch_count_out       <= base_count_final;
                            corrected_candidate_base <= base_candidate_final;
                        end else begin
                            residue_error            <= 1'b1;
                            corrected_success        <= 1'b0;
                            uncorrectable            <= enable_correction;
                            corrected_lane_mask      <= 6'd0;
                            mismatch_mask_out        <= cmp_mask;
                            mismatch_count_out       <= cmp_count;
                            corrected_candidate_base <= cand;
                        end
                    end

                    /*
                     * Advance the residue scan every active scan cycle, even
                     * on the terminal candidate.  On the terminal cycle these
                     * next residue/candidate values are unused because the FSM moves to
                     * ST_DONE, but avoiding a last_candidate-controlled hold
                     * mux removes that comparator from the lane-update cones.
                     */
                    cand <= cand_plus_one;
                    half_hit0_q <= next_half_hit;
                    half_hit1_q <= next_half_hit;
                    half_hit2_q <= next_half_hit;
                    half_hit3_q <= next_half_hit;
                    half_hit4_q <= next_half_hit;
                    half_hit5_q <= next_half_hit;

                    if (half_hit0_q) begin
                        if ((m0_q <= 1) || (p0 == {WM{1'b0}})) p0 <= {WM{1'b0}}; else p0 <= m0_q - p0;
                    end else begin
                        if ((m0_q <= 1) || ((p0 + {{(WM-1){1'b0}},1'b1}) >= m0_q)) p0 <= {WM{1'b0}}; else p0 <= p0 + {{(WM-1){1'b0}},1'b1};
                    end

                    if (half_hit1_q) begin
                        if ((m1_q <= 1) || (p1 == {WM{1'b0}})) p1 <= {WM{1'b0}}; else p1 <= m1_q - p1;
                    end else begin
                        if ((m1_q <= 1) || ((p1 + {{(WM-1){1'b0}},1'b1}) >= m1_q)) p1 <= {WM{1'b0}}; else p1 <= p1 + {{(WM-1){1'b0}},1'b1};
                    end

                    if (half_hit2_q) begin
                        if ((m2_q <= 1) || (p2 == {WM{1'b0}})) p2 <= {WM{1'b0}}; else p2 <= m2_q - p2;
                    end else begin
                        if ((m2_q <= 1) || ((p2 + {{(WM-1){1'b0}},1'b1}) >= m2_q)) p2 <= {WM{1'b0}}; else p2 <= p2 + {{(WM-1){1'b0}},1'b1};
                    end

                    if (half_hit3_q) begin
                        if ((m3_q <= 1) || (p3 == {WM{1'b0}})) p3 <= {WM{1'b0}}; else p3 <= m3_q - p3;
                    end else begin
                        if ((m3_q <= 1) || ((p3 + {{(WM-1){1'b0}},1'b1}) >= m3_q)) p3 <= {WM{1'b0}}; else p3 <= p3 + {{(WM-1){1'b0}},1'b1};
                    end

                    if (half_hit4_q) begin
                        if ((m4_q <= 1) || (p4 == {WM{1'b0}})) p4 <= {WM{1'b0}}; else p4 <= m4_q - p4;
                    end else begin
                        if ((m4_q <= 1) || ((p4 + {{(WM-1){1'b0}},1'b1}) >= m4_q)) p4 <= {WM{1'b0}}; else p4 <= p4 + {{(WM-1){1'b0}},1'b1};
                    end

                    if (half_hit5_q) begin
                        if ((m5_q <= 1) || (p5 == {WM{1'b0}})) p5 <= {WM{1'b0}}; else p5 <= m5_q - p5;
                    end else begin
                        if ((m5_q <= 1) || ((p5 + {{(WM-1){1'b0}},1'b1}) >= m5_q)) p5 <= {WM{1'b0}}; else p5 <= p5 + {{(WM-1){1'b0}},1'b1};
                    end
                end
            end

            default: begin
            end
        endcase
    end

endmodule
