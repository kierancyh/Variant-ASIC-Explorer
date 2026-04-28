`timescale 1ns/1ps
// V51A source marker: split post-corrector finalisation to remove shared max-slew hold-enable net.
// V50A source marker: design-simplification patch based on V44A.
// The ADD/SUB/MUL mathematical range guard is now a separate sequential module,
// the corrector-to-range/output boundary is registered, and final range/centering
// is a one-cycle registered stage. No LibreLane/variant flow changes.
module final_alu_runtime_top #(
    parameter integer WM = 5,
    parameter integer XW = 24,
    parameter integer PW = 20
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     cfg_we,
    input  wire                     cfg_re,
    input  wire [3:0]               cfg_addr,
    input  wire [31:0]              cfg_wdata,
    input  wire                     cfg_apply,
    output reg  [31:0]              cfg_rdata,
    input  wire                     Load_IN,
    input  wire [1:0]               Op_Sel,
    input  wire signed [XW-1:0]     A_in,
    input  wire signed [XW-1:0]     B_in,
    output reg  signed [XW-1:0]     X_out,
    output reg                      Done,
    output wire                     Busy,
    output wire                     Config_Valid,
    output wire                     Config_Busy,
    output wire                     Config_Error,
    output wire [3:0]               Config_Error_Code,
    output wire                     Error_Detected,
    output reg                      Corrected,
    output wire                     Valid,
    output wire                     Uncorrectable
);

    /*
     * V18 physical-signoff cleanup: keep the top controller explicitly
     * one-hot.  V17 still let Yosys use binary main_state bits; the
     * routed report showed main_state[0] driving the mux select for the
     * A_reg/B_reg operand-capture banks.  A one-hot state vector gives
     * each capture/init/update state its own local select bit instead of
     * one shared high-load binary decode net.
     */
    localparam integer MAIN_STATE_W = 44;
    localparam [MAIN_STATE_W-1:0]
        MS_IDLE           = 44'h000000001,
        MS_CFG_WAIT_CHK   = 44'h000000002,
        MS_CFG_WAIT_PRE   = 44'h000000004,

        /* Byte-wide operation-capture states. */
        MS_OP_CAP_A0      = 44'h000000008,
        MS_OP_CAP_A1      = 44'h000000010,
        MS_OP_CAP_A2      = 44'h000000020,
        MS_OP_CAP_B0      = 44'h000000040,
        MS_OP_CAP_B1      = 44'h000000080,
        MS_OP_CAP_B2      = 44'h000000100,
        MS_OP_INIT_FLAGS  = 44'h000000200,
        MS_OP_START_RANGE = 44'h000000400,
        MS_OP_WAIT_RANGE  = 44'h000000800,
        MS_OP_START_FINAL_RANGE = 44'h000001000,
        MS_OP_WAIT_FINAL_RANGE  = 44'h000002000,

        /* Legacy/unreachable helper encodings kept as spare one-hot states. */
        MS_OP_UNUSED0     = 44'h000004000,
        MS_OP_UNUSED1     = 44'h000008000,
        MS_OP_UNUSED2     = 44'h000010000,
        MS_OP_START_ENC   = 44'h000020000,
        MS_OP_WAIT_ENC    = 44'h000040000,

        /* V20: copy encoder residues into the A/B holding banks in
         * 10-bit chunks.  V19 copied all 30 residue bits in one cycle and
         * the post-PnR report showed that mux select as a new max-slew net. */
        MS_OP_STORE_A0    = 44'h000080000,
        MS_OP_STORE_A1    = 44'h000100000,
        MS_OP_STORE_A2    = 44'h000200000,
        MS_OP_STORE_B0    = 44'h000400000,
        MS_OP_STORE_B1    = 44'h000800000,
        MS_OP_STORE_B2    = 44'h001000000,

        /*
         * V33A physical-signoff cleanup: V31A split PREP into M/A/B states,
         * but V32A was optimized back into lane_idx decode logic. Keep the
         * slice-prep sequence, but make the active operation lane a self-
         * advancing one-hot state so the M/A/B mux banks no longer depend on
         * shared binary lane_idx==N decoder cells.
         */
        MS_OP_PREP_M      = 44'h002000000,
        MS_OP_PREP_A      = 44'h004000000,
        MS_OP_PREP_B      = 44'h008000000,
        MS_OP_START_LANE  = 44'h010000000,
        MS_OP_WAIT_LANE   = 44'h020000000,
        MS_OP_START_CORR  = 44'h040000000,
        MS_OP_WAIT_CORR   = 44'h080000000,
        MS_OP_FINAL       = 44'h100000000,

        /* V36A: store the slice result from a local holding register rather
         * than routing the slice output directly into the z0..z5 bank. */
        MS_OP_STORE_Z     = 44'h200000000,

        /* Legacy/unreachable config-commit fallbacks. */
        MS_CFG_COMMIT1    = 44'h400000000,
        MS_CFG_COMMIT2    = 44'h800000000,

        /* V51A: post-corrector finalisation split into small capture states.
         * V50B captured candidate, status, M_base, and half_range in one
         * corrector_done-gated cycle.  The routed reports showed the resulting
         * shared enable net feeding many hold muxes as the dominant max-slew
         * source.  These states keep the same semantics but limit each state
         * bit to a small physical register bank. */
        MS_OP_LATCH_CAND0 = 44'h1000000000,
        MS_OP_LATCH_CAND1 = 44'h2000000000,
        MS_OP_LATCH_CAND2 = 44'h4000000000,
        MS_OP_LATCH_FLAGS = 44'h8000000000,
        MS_OP_LATCH_M0    = 44'h10000000000,
        MS_OP_LATCH_M1    = 44'h20000000000,
        MS_OP_LATCH_H0    = 44'h40000000000,
        MS_OP_LATCH_H1    = 44'h80000000000;

    /* V50A: true-result range checking moved to final_alu_op_range_guard.v. */

    (* keep = "true", dont_touch = "true", fsm_encoding = "none" *) reg [MAIN_STATE_W-1:0] main_state;
    reg [2:0] cfg_state_dbg;
    reg [3:0] op_state_dbg;
    reg [2:0] lane_idx;

    /* V33A: operation-lane one-hot scanner.  V32A still synthesized back
       into lane_idx decoder cells because the one-hot copies were generated
       directly from lane_idx.  This scanner advances from its own previous
       value and is used for the slice-prep muxes.  lane_idx is retained
       for debug plus the low-fanout result-store/loop-control path; this
       avoids the V33A lane-0 store/prep alignment failure while still
       removing lane_idx from the heavy M/A/B prep mux banks. */
    (* keep = "true", dont_touch = "true" *) reg [5:0] op_lane_oh;
    (* keep = "true", dont_touch = "true" *) reg [5:0] slice_m_lane_oh;
    (* keep = "true", dont_touch = "true" *) reg [5:0] slice_a_lane_oh;
    (* keep = "true", dont_touch = "true" *) reg [5:0] slice_b_lane_oh;


    /* Physical-design reset fanout isolation.
       External rst_n is first captured into a few local reset copies.  The
       child modules and the top FSM use those local copies rather than the
       package/top reset net directly.  This is intended to stop rst_n becoming
       one huge high-slew distribution net after synthesis/PnR.  The testbench
       and console already hold rst_n low for multiple clocks, so the one-cycle
       synchronous release is safe for this design. */
    (* keep = "true", dont_touch = "true" *) reg rst_main_n;
    (* keep = "true", dont_touch = "true" *) reg rst_cfgregs_n;
    (* keep = "true", dont_touch = "true" *) reg rst_cfgchk_n;
    (* keep = "true", dont_touch = "true" *) reg rst_precomp_n;
    (* keep = "true", dont_touch = "true" *) reg rst_encoder_n;
    (* keep = "true", dont_touch = "true" *) reg rst_slice_n;
    (* keep = "true", dont_touch = "true" *) reg rst_corrector_n;

    wire [WM-1:0] m0_cfg, m1_cfg, m2_cfg, m3_cfg, m4_cfg, m5_cfg;

    /* V36A antenna-isolation copies.
       The config register outputs remain the authoritative CSR values, but the
       operation engines use local copies captured after a successful
       cfg_apply/precompute sequence.  This reduces the long routed fanout of
       m*_cfg during normal ALU operation; repeated final antenna reports
       included m4_cfg[4] and encoder/slice modulus-select logic. */
    (* keep = "true", dont_touch = "true" *) reg [WM-1:0] enc_m0_cfg, enc_m1_cfg, enc_m2_cfg, enc_m3_cfg, enc_m4_cfg, enc_m5_cfg;
    (* keep = "true", dont_touch = "true" *) reg [WM-1:0] slice_m0_cfg, slice_m1_cfg, slice_m2_cfg, slice_m3_cfg, slice_m4_cfg, slice_m5_cfg;
    (* keep = "true", dont_touch = "true" *) reg [WM-1:0] corr_m0_cfg, corr_m1_cfg, corr_m2_cfg, corr_m3_cfg, corr_m4_cfg, corr_m5_cfg;

    wire detect_en_cfg;
    wire correct_en_cfg;
    wire cfg_lock_cfg;
    wire cfg_loaded_cfg;
    reg  cfg_clear_loaded;
    wire cfg_write_allow;

    reg        config_valid_reg;
    reg        config_busy_reg;
    (* keep = "true", dont_touch = "true" *) reg config_busy_pad_reg;
    reg        config_error_reg;
    reg [3:0]  config_error_code_reg;

    /*
     * V12 physical-signoff cleanup:
     * V11A still produced a very slow config-commit mux-select net for the
     * duplicated M_base/half-range/bitmap top-level register bank.
     * The cfg_checker/precompute blocks already hold stable registered outputs
     * after Config_Valid, and the ALU will not accept operations until then.
     * Use those checked values directly instead of committing them through a
     * second wide register bank.
     */
    wire [PW-1:0] M_base_live;
    wire [PW-1:0] half_range_live;
    wire [14:0]   usable_subset_bitmap_live;

    // Backwards-compatible debug aliases for the existing RTL/GLS testbench.
    // V12 deliberately removed the physical commit register bank, but the
    // testbench still probes these historical hierarchical names.  Keep these
    // as simple wires so they do not recreate the old high-load commit muxes.
    wire [PW-1:0] M_base_reg;
    wire [PW-1:0] half_range_reg;
    wire [14:0]   usable_subset_bitmap_reg;

    reg        op_busy_reg;
    reg        error_detected_reg;
    reg        corrected_reg;
    reg        valid_reg;
    reg        uncorrectable_reg;
    reg [5:0]  last_mismatch_mask_reg;
    reg [2:0]  last_mismatch_count_reg;
    reg [5:0]  last_corrected_lane_mask_reg;
    reg        residue_error_reg;
    reg        range_error_reg;

    reg        checker_start_reg;
    wire       checker_done;
    wire       checker_cfg_ok;
    wire [3:0] checker_error_code;
    wire [PW-1:0] checker_M_base;
    wire [PW-1:0] checker_half_range;

    reg        precomp_start_reg;
    wire       precomp_done;
    wire       precomp_ok;
    wire [14:0] precomp_bitmap;

    reg        enc_start_reg;
    reg        enc_select_b_reg;
    wire       enc_done;
    wire [6*WM-1:0] enc_res_flat;
    reg  [6*WM-1:0] a_res_flat_reg;
    reg  [6*WM-1:0] b_res_flat_reg;

    reg        slice_start_reg;
    wire       slice_done;
    wire [WM-1:0] slice_z_res;
    /* V36A: one-cycle local capture of the slice output before the z-bank
       store mux.  This targets recurring final antenna on slice_z_res[3]. */
    (* keep = "true", dont_touch = "true" *) reg [WM-1:0] slice_z_res_hold;
    (* keep = "true", dont_touch = "true" *) reg slice_z_res_bit0_store_reg;
    (* keep = "true", dont_touch = "true" *) reg slice_z_res_bit2_store_reg;
    (* keep = "true", dont_touch = "true" *) reg slice_z_res_bit3_store_reg;
    reg  [WM-1:0] slice_a_reg;
    (* keep = "true", dont_touch = "true" *) reg slice_a_bit0_launch_reg;
    reg  [WM-1:0] slice_b_reg;
    reg  [WM-1:0] slice_m_reg;
    reg  [1:0] op_sel_reg;
    (* keep = "true", dont_touch = "true" *) reg [1:0] op_sel_slice_reg;
    (* keep = "true", dont_touch = "true" *) reg op_is_add_reg;
    (* keep = "true", dont_touch = "true" *) reg op_is_sub_reg;
    (* keep = "true", dont_touch = "true" *) reg op_is_mul_reg;

    reg  signed [XW-1:0] A_reg;
    reg  signed [XW-1:0] B_reg;

    /* V36B: top-level input shadow registers.
       V36A reduced antenna on internal result/candidate paths, but final
       antenna still showed a small violation on the B_in[2] input route.
       Capture A_in/B_in once when Load_IN is accepted, then feed the existing
       byte-wide A_reg/B_reg capture sequence from these local shadows. */
    (* keep = "true", dont_touch = "true" *) reg signed [XW-1:0] A_in_shadow_reg;
    (* keep = "true", dont_touch = "true" *) reg signed [XW-1:0] B_in_shadow_reg;

    /* V50A: keep only the proven encoder-side operand isolation.
       Calculation-side copies are removed because ADD/SUB/MUL mathematical
       range checking now lives in final_alu_op_range_guard.v. */
    (* keep = "true", dont_touch = "true" *) reg A_bit5_enc_reg;
    (* keep = "true", dont_touch = "true" *) reg B_bit5_enc_reg;
    (* keep = "true", dont_touch = "true" *) reg A_bit4_enc_reg;
    (* keep = "true", dont_touch = "true" *) reg B_bit4_enc_reg;
    wire signed [XW-1:0] A_enc_iso_wire;
    wire signed [XW-1:0] B_enc_iso_wire;

    reg               raw_range_error_reg;
    reg               op_range_start_reg;
    wire              op_range_done;
    wire              op_range_error;

    reg  [WM-1:0] z0_reg, z1_reg, z2_reg, z3_reg, z4_reg, z5_reg;
    wire [6*WM-1:0] z_res_flat;

    reg  corrector_start_reg;
    wire corrector_done;
    wire corrector_residue_error;
    wire corrector_corrected_success;
    wire corrector_uncorrectable;
    wire [5:0] corrector_lane_mask;
    wire [5:0] corrector_mismatch_mask;
    wire [2:0] corrector_mismatch_count;
    wire [PW-1:0] corrector_candidate_base;
    /* V36A: isolate the corrector candidate output before range/final output
       logic. Repeated final antenna reports included corrector_candidate_base
       bits, especially [10] and [11]. */
    (* keep = "true", dont_touch = "true" *) reg [PW-1:0] corrector_candidate_base_hold;
    (* keep = "true", dont_touch = "true" *) reg corrector_residue_error_hold;
    (* keep = "true", dont_touch = "true" *) reg corrector_corrected_success_hold;
    (* keep = "true", dont_touch = "true" *) reg corrector_uncorrectable_hold;
    (* keep = "true", dont_touch = "true" *) reg [5:0] corrector_lane_mask_hold;
    (* keep = "true", dont_touch = "true" *) reg [5:0] corrector_mismatch_mask_hold;
    (* keep = "true", dont_touch = "true" *) reg [2:0] corrector_mismatch_count_hold;
    reg final_range_start_reg;
    wire final_range_done;
    /* V41A: local range-check operands.  V40A still showed final antenna on
       M_base_live[14] and a downstream range/centering net.  Capture the
       range operands when the corrector completes, then let the final state
       consume these local holds instead of the shared config/precompute nets. */
    (* keep = "true", dont_touch = "true" *) reg [PW-1:0] range_M_base_hold;
    (* keep = "true", dont_touch = "true" *) reg [PW-1:0] range_half_range_hold;
    (* keep = "true", dont_touch = "true" *) reg corr_m0_bit3_corrector_reg;
    (* keep = "true", dont_touch = "true" *) reg corr_m0_bit4_corrector_reg;
    /* V41A: separate the external X_out flop from the internal retained
       output value.  The V40A 40 ns artifact showed antenna on net87, the
       X_out[19] output path, because the output flop Q also fed internal
       hold/update logic. */
    (* keep = "true", dont_touch = "true" *) reg signed [XW-1:0] x_out_core_reg;

    wire signed [XW-1:0] x_centered_wire;
    wire range_error_wire;
    wire [WM-1:0] slice_a_sel;
    wire [WM-1:0] slice_b_sel;
    wire [WM-1:0] slice_m_sel;

    wire [2:0] cfg_state_dbg_wire;
    wire [3:0] op_state_dbg_wire;

    assign z_res_flat = {z5_reg, z4_reg, z3_reg, z2_reg, z1_reg, z0_reg};

    // V50B: keep one FSM bubble after corrector capture while retaining the
    // original combinational range_check module interface.
    assign final_range_done = final_range_start_reg;

    assign M_base_live               = checker_M_base;
    assign half_range_live           = checker_half_range;
    assign usable_subset_bitmap_live = config_valid_reg ? precomp_bitmap : 15'd0;

    assign M_base_reg               = M_base_live;
    assign half_range_reg           = half_range_live;
    assign usable_subset_bitmap_reg = usable_subset_bitmap_live;

    assign A_enc_iso_wire  = {A_reg[XW-1:6], A_bit5_enc_reg,  A_bit4_enc_reg,  A_reg[3:0]};
    assign B_enc_iso_wire  = {B_reg[XW-1:6], B_bit5_enc_reg,  B_bit4_enc_reg,  B_reg[3:0]};

    /* V42A proven small stores retained; no additional one-bit antenna chasing. */
    wire [WM-1:0] slice_z_store_wire     = {slice_z_res_hold[WM-1:4], slice_z_res_bit3_store_reg, slice_z_res_bit2_store_reg, slice_z_res_hold[1], slice_z_res_bit0_store_reg};
    wire [WM-1:0] corr_m0_corrector_wire = {corr_m0_bit4_corrector_reg, corr_m0_bit3_corrector_reg, corr_m0_cfg[2:0]};

    assign Busy              = config_busy_reg | op_busy_reg;
    assign Config_Valid      = config_valid_reg;
    assign Config_Busy       = config_busy_pad_reg;
    assign Config_Error      = config_error_reg;
    assign Config_Error_Code = config_error_code_reg;
    assign Error_Detected    = error_detected_reg;
    /* V36B: Corrected is now a registered output, not a direct wire from
       corrected_reg. This isolates the external status-output route that
       appeared as net72 in the V36A final antenna report. */
    assign Valid             = valid_reg;
    assign Uncorrectable     = uncorrectable_reg;

    /* Allow configuration writes as soon as the config-register reset domain is released.
       The local-reset stagger releases rst_main_n last for physical reset fanout
       isolation. Gating writes with rst_main_n can drop early modulus writes,
       causing checker error code 1 (modulus <= 1). */
    assign cfg_write_allow = rst_cfgregs_n && !Busy && !(cfg_lock_cfg && config_valid_reg);

    final_alu_cfg_regs #(.WM(WM)) u_cfg_regs (
        .clk(clk),
        .rst_n(rst_cfgregs_n),
        .cfg_we(cfg_we),
        .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata),
        .allow_write(cfg_write_allow),
        .clear_loaded(cfg_clear_loaded),
        .m0_reg(m0_cfg),
        .m1_reg(m1_cfg),
        .m2_reg(m2_cfg),
        .m3_reg(m3_cfg),
        .m4_reg(m4_cfg),
        .m5_reg(m5_cfg),
        .detect_en_reg(detect_en_cfg),
        .correct_en_reg(correct_en_cfg),
        .cfg_lock_reg(cfg_lock_cfg),
        .cfg_loaded_reg(cfg_loaded_cfg)
    );

    final_alu_cfg_checker #(.WM(WM), .XW(XW), .PW(PW)) u_cfg_checker (
        .clk(clk),
        .rst_n(rst_cfgchk_n),
        .start(checker_start_reg),
        .m0(m0_cfg),
        .m1(m1_cfg),
        .m2(m2_cfg),
        .m3(m3_cfg),
        .m4(m4_cfg),
        .m5(m5_cfg),
        .done(checker_done),
        .cfg_ok(checker_cfg_ok),
        .cfg_error_code(checker_error_code),
        .M_base(checker_M_base),
        .half_range(checker_half_range)
    );

    final_alu_cfg_precompute #(.WM(WM), .PW(PW)) u_cfg_precompute (
        .clk(clk),
        .rst_n(rst_precomp_n),
        .start(precomp_start_reg),
        .m0(m0_cfg),
        .m1(m1_cfg),
        .m2(m2_cfg),
        .m3(m3_cfg),
        .m4(m4_cfg),
        .m5(m5_cfg),
        .M_base(checker_M_base),
        .done(precomp_done),
        .precomp_ok(precomp_ok),
        .usable_subset_bitmap(precomp_bitmap)
    );

    final_alu_op_range_guard #(.XW(XW), .PW(PW)) u_op_range_guard (
        .clk(clk),
        .rst_n(rst_main_n),
        .start(op_range_start_reg),
        .op_sel(op_sel_reg),
        .A_in(A_reg),
        .B_in(B_reg),
        .half_range(half_range_live),
        .done(op_range_done),
        .raw_range_error(op_range_error)
    );

    final_alu_encoder_runtime #(.WM(WM), .XW(XW)) u_encoder (
        .clk(clk),
        .rst_n(rst_encoder_n),
        .start(enc_start_reg),
        .x_in(enc_select_b_reg ? B_enc_iso_wire : A_enc_iso_wire),
        .m0(enc_m0_cfg),
        .m1(enc_m1_cfg),
        .m2(enc_m2_cfg),
        .m3(enc_m3_cfg),
        .m4(enc_m4_cfg),
        .m5(enc_m5_cfg),
        .done(enc_done),
        .res_flat(enc_res_flat)
    );

    final_alu_slice_runtime #(.WM(WM)) u_slice (
        .clk(clk),
        .rst_n(rst_slice_n),
        .start(slice_start_reg),
        .op_sel(op_sel_slice_reg),
        .a_res(slice_a_sel),
        .b_res(slice_b_sel),
        .modulus(slice_m_sel),
        .done(slice_done),
        .z_res(slice_z_res)
    );

    final_alu_corrector_search_v18 #(.WM(WM), .PW(PW)) u_corrector (
        .clk(clk),
        .rst_n(rst_corrector_n),
        .start(corrector_start_reg),
        .enable_detection(detect_en_cfg),
        .enable_correction(correct_en_cfg),
        .z_res_flat(z_res_flat),
        .M_base(M_base_live),
        .usable_subset_bitmap(usable_subset_bitmap_live),
        .m0(corr_m0_corrector_wire),
        .m1(corr_m1_cfg),
        .m2(corr_m2_cfg),
        .m3(corr_m3_cfg),
        .m4(corr_m4_cfg),
        .m5(corr_m5_cfg),
        .done(corrector_done),
        .residue_error(corrector_residue_error),
        .corrected_success(corrector_corrected_success),
        .uncorrectable(corrector_uncorrectable),
        .corrected_lane_mask(corrector_lane_mask),
        .mismatch_mask_out(corrector_mismatch_mask),
        .mismatch_count_out(corrector_mismatch_count),
        .corrected_candidate_base(corrector_candidate_base)
    );

    final_alu_range_check #(.XW(XW), .PW(PW)) u_range (
        .raw_range_error(raw_range_error_reg),
        .M_base(range_M_base_hold),
        .half_range(range_half_range_hold),
        .candidate_base(corrector_candidate_base_hold),
        .range_error(range_error_wire),
        .x_centered(x_centered_wire)
    );

    final_alu_runtime_cu #(.CFG_W(3), .OP_W(4)) u_cu_dbg (
        .cfg_state_in(cfg_state_dbg),
        .op_state_in(op_state_dbg),
        .cfg_state_dbg(cfg_state_dbg_wire),
        .op_state_dbg(op_state_dbg_wire)
    );

    function [WM-1:0] get_lane_res;
        input [6*WM-1:0] flat;
        input integer idx;
        begin
            case (idx)
                0: get_lane_res = flat[(0*WM)+:WM];
                1: get_lane_res = flat[(1*WM)+:WM];
                2: get_lane_res = flat[(2*WM)+:WM];
                3: get_lane_res = flat[(3*WM)+:WM];
                4: get_lane_res = flat[(4*WM)+:WM];
                5: get_lane_res = flat[(5*WM)+:WM];
                default: get_lane_res = {WM{1'b0}};
            endcase
        end
    endfunction

    function [5:0] lane_oh_next;
        input [5:0] oh;
        begin
            case (oh)
                6'b000001: lane_oh_next = 6'b000010;
                6'b000010: lane_oh_next = 6'b000100;
                6'b000100: lane_oh_next = 6'b001000;
                6'b001000: lane_oh_next = 6'b010000;
                6'b010000: lane_oh_next = 6'b100000;
                default:   lane_oh_next = 6'b000001;
            endcase
        end
    endfunction

    function [WM-1:0] get_mod_oh;
        input [5:0] oh;
        begin
            case (1'b1)
                oh[0]: get_mod_oh = slice_m0_cfg;
                oh[1]: get_mod_oh = slice_m1_cfg;
                oh[2]: get_mod_oh = slice_m2_cfg;
                oh[3]: get_mod_oh = slice_m3_cfg;
                oh[4]: get_mod_oh = slice_m4_cfg;
                oh[5]: get_mod_oh = slice_m5_cfg;
                default: get_mod_oh = {WM{1'b0}};
            endcase
        end
    endfunction

    function [WM-1:0] get_flat_oh;
        input [6*WM-1:0] flat;
        input [5:0] oh;
        begin
            case (1'b1)
                oh[0]: get_flat_oh = flat[(0*WM)+:WM];
                oh[1]: get_flat_oh = flat[(1*WM)+:WM];
                oh[2]: get_flat_oh = flat[(2*WM)+:WM];
                oh[3]: get_flat_oh = flat[(3*WM)+:WM];
                oh[4]: get_flat_oh = flat[(4*WM)+:WM];
                oh[5]: get_flat_oh = flat[(5*WM)+:WM];
                default: get_flat_oh = {WM{1'b0}};
            endcase
        end
    endfunction

    wire [5:0] op_lane_oh_next = lane_oh_next(op_lane_oh);
    wire [WM-1:0] slice_m_next = get_mod_oh(slice_m_lane_oh);
    wire [WM-1:0] slice_a_next = get_flat_oh(a_res_flat_reg, slice_a_lane_oh);
    wire [WM-1:0] slice_b_next = get_flat_oh(b_res_flat_reg, slice_b_lane_oh);

    assign slice_a_sel = {slice_a_reg[WM-1:1], slice_a_bit0_launch_reg};
    assign slice_b_sel = slice_b_reg;
    assign slice_m_sel = slice_m_reg;

    always @* begin
        if (!cfg_re) begin
            cfg_rdata = 32'd0;
        end else begin
            case (cfg_addr)
                4'h0: cfg_rdata = {29'd0, cfg_lock_cfg, correct_en_cfg, detect_en_cfg};
                4'h1: cfg_rdata = {{(32-WM){1'b0}}, m0_cfg};
                4'h2: cfg_rdata = {{(32-WM){1'b0}}, m1_cfg};
                4'h3: cfg_rdata = {{(32-WM){1'b0}}, m2_cfg};
                4'h4: cfg_rdata = {{(32-WM){1'b0}}, m3_cfg};
                4'h5: cfg_rdata = {{(32-WM){1'b0}}, m4_cfg};
                4'h6: cfg_rdata = {{(32-WM){1'b0}}, m5_cfg};
                4'h7: cfg_rdata = {26'd0, Done, op_busy_reg, config_error_reg, config_busy_reg, config_valid_reg, cfg_loaded_cfg};
                4'h8: cfg_rdata = {28'd0, config_error_code_reg};
                4'h9: cfg_rdata = {{(32-PW){1'b0}}, M_base_live};
                4'hA: cfg_rdata = {{(32-PW){1'b0}}, half_range_live};
                4'hB: cfg_rdata = {17'd0, usable_subset_bitmap_live};
                4'hC: cfg_rdata = {23'd0, last_mismatch_count_reg, last_mismatch_mask_reg};
                4'hD: cfg_rdata = {26'd0, last_corrected_lane_mask_reg};
                4'hE: cfg_rdata = {22'd0, cfg_state_dbg_wire, op_state_dbg_wire, lane_idx};
                4'hF: cfg_rdata = 32'h0001_0000;
                default: cfg_rdata = 32'd0;
            endcase
        end
    end


    always @(posedge clk) begin
        if (!rst_n) begin
            rst_main_n      <= 1'b0;
            rst_cfgregs_n   <= 1'b0;
            rst_cfgchk_n    <= 1'b0;
            rst_precomp_n   <= 1'b0;
            rst_encoder_n   <= 1'b0;
            rst_slice_n     <= 1'b0;
            rst_corrector_n <= 1'b0;
        end else begin
            /*
             * Do not drive every local reset copy with the same expression.
             * V10 used identical reset-copy flops; Yosys/OpenROAD legally
             * merged their loads back onto one huge rst_cfgchk_n-style net.
             * This staggered release makes each reset domain logically unique,
             * so synthesis keeps the load partitioning.  The top FSM releases
             * last, after its child engines are already out of reset.
             */
            rst_cfgregs_n   <= 1'b1;
            rst_cfgchk_n    <= rst_cfgregs_n;
            rst_precomp_n   <= rst_cfgchk_n;
            rst_encoder_n   <= rst_precomp_n;
            rst_slice_n     <= rst_encoder_n;
            rst_corrector_n <= rst_slice_n;
            rst_main_n      <= rst_corrector_n;
        end
    end

    always @(posedge clk) begin
        if (!rst_main_n) begin
            main_state                   <= MS_IDLE;
            cfg_state_dbg                <= 3'd0;
            op_state_dbg                 <= 4'd0;
            lane_idx                     <= 3'd0;
            op_lane_oh                   <= 6'b000001;
            slice_m_lane_oh              <= 6'b000001;
            slice_a_lane_oh              <= 6'b000001;
            slice_b_lane_oh              <= 6'b000001;
            enc_m0_cfg                   <= {WM{1'b0}};
            enc_m1_cfg                   <= {WM{1'b0}};
            enc_m2_cfg                   <= {WM{1'b0}};
            enc_m3_cfg                   <= {WM{1'b0}};
            enc_m4_cfg                   <= {WM{1'b0}};
            enc_m5_cfg                   <= {WM{1'b0}};
            slice_m0_cfg                 <= {WM{1'b0}};
            slice_m1_cfg                 <= {WM{1'b0}};
            slice_m2_cfg                 <= {WM{1'b0}};
            slice_m3_cfg                 <= {WM{1'b0}};
            slice_m4_cfg                 <= {WM{1'b0}};
            slice_m5_cfg                 <= {WM{1'b0}};
            corr_m0_cfg                  <= {WM{1'b0}};
            corr_m1_cfg                  <= {WM{1'b0}};
            corr_m2_cfg                  <= {WM{1'b0}};
            corr_m3_cfg                  <= {WM{1'b0}};
            corr_m4_cfg                  <= {WM{1'b0}};
            corr_m5_cfg                  <= {WM{1'b0}};
            slice_z_res_hold             <= {WM{1'b0}};
            slice_z_res_bit0_store_reg    <= 1'b0;
            slice_z_res_bit2_store_reg    <= 1'b0;
            slice_z_res_bit3_store_reg    <= 1'b0;
            slice_a_bit0_launch_reg       <= 1'b0;
            corrector_candidate_base_hold <= {PW{1'b0}};
            A_in_shadow_reg              <= {XW{1'b0}};
            B_in_shadow_reg              <= {XW{1'b0}};
            A_bit5_enc_reg               <= 1'b0;
            B_bit5_enc_reg               <= 1'b0;
            A_bit4_enc_reg               <= 1'b0;
            B_bit4_enc_reg               <= 1'b0;
            op_range_start_reg           <= 1'b0;
            final_range_start_reg        <= 1'b0;
            corrector_residue_error_hold <= 1'b0;
            corrector_corrected_success_hold <= 1'b0;
            corrector_uncorrectable_hold <= 1'b0;
            corrector_lane_mask_hold     <= 6'd0;
            corrector_mismatch_mask_hold <= 6'd0;
            corrector_mismatch_count_hold <= 3'd0;
            range_M_base_hold            <= {PW{1'b0}};
            range_half_range_hold        <= {PW{1'b0}};
            corr_m0_bit3_corrector_reg   <= 1'b0;
            corr_m0_bit4_corrector_reg   <= 1'b0;
            x_out_core_reg               <= {XW{1'b0}};
            Corrected                    <= 1'b0;
            cfg_clear_loaded             <= 1'b0;
            checker_start_reg            <= 1'b0;
            precomp_start_reg            <= 1'b0;
            enc_start_reg                <= 1'b0;
            op_sel_reg                   <= 2'b00;
            op_sel_slice_reg             <= 2'b00;
            op_is_add_reg                <= 1'b0;
            op_is_sub_reg                <= 1'b0;
            op_is_mul_reg                <= 1'b0;
            enc_select_b_reg             <= 1'b0;
            slice_start_reg              <= 1'b0;
            corrector_start_reg          <= 1'b0;
            config_valid_reg             <= 1'b0;
            config_busy_reg              <= 1'b0;
            config_busy_pad_reg          <= 1'b0;
            config_error_reg             <= 1'b0;
            config_error_code_reg        <= 4'd0;
            op_busy_reg                  <= 1'b0;
            error_detected_reg           <= 1'b0;
            corrected_reg                <= 1'b0;
            valid_reg                    <= 1'b0;
            uncorrectable_reg            <= 1'b0;
            last_mismatch_mask_reg       <= 6'd0;
            last_mismatch_count_reg      <= 3'd0;
            last_corrected_lane_mask_reg <= 6'd0;
            residue_error_reg            <= 1'b0;
            range_error_reg              <= 1'b0;
            Done                         <= 1'b0;
        end else begin
            cfg_clear_loaded    <= 1'b0;
            checker_start_reg   <= 1'b0;
            precomp_start_reg   <= 1'b0;
            enc_start_reg       <= 1'b0;
            slice_start_reg     <= 1'b0;
            corrector_start_reg <= 1'b0;
            op_range_start_reg  <= 1'b0;
            final_range_start_reg <= 1'b0;
            Done                <= 1'b0;
            Corrected           <= corrected_reg;
            X_out               <= x_out_core_reg;

            case (main_state)
                MS_IDLE: begin
                    cfg_state_dbg <= 3'd0;
                    op_state_dbg     <= 4'd0;
                    lane_idx         <= 3'd0;
                    op_lane_oh       <= 6'b000001;
                    slice_m_lane_oh  <= 6'b000001;
                    slice_a_lane_oh  <= 6'b000001;
                    slice_b_lane_oh  <= 6'b000001;
                    if (cfg_apply && !Busy) begin
                        config_busy_reg       <= 1'b1;
                        config_busy_pad_reg   <= 1'b1;
                        config_valid_reg      <= 1'b0;
                        config_error_reg      <= 1'b0;
                        config_error_code_reg <= 4'd0;
                        checker_start_reg     <= 1'b1;
                        cfg_state_dbg         <= 3'd1;
                        main_state            <= MS_CFG_WAIT_CHK;
                    end else if (Load_IN && config_valid_reg && !Busy) begin
                        /* Keep the Load_IN cycle light: only latch the opcode
                         * and claim Busy. A/B are captured in byte-wide states
                         * below, which breaks the former high-slew _0983_ mux
                         * select that drove the full 48-bit operand bank. */
                        op_sel_reg       <= Op_Sel;
                        op_sel_slice_reg <= Op_Sel;
                        op_is_add_reg    <= (Op_Sel == 2'b00);
                        op_is_sub_reg    <= (Op_Sel == 2'b01);
                        op_is_mul_reg    <= (Op_Sel == 2'b10);
                        A_in_shadow_reg <= A_in;
                        B_in_shadow_reg <= B_in;
                        op_busy_reg      <= 1'b1;
                        enc_select_b_reg <= 1'b0;
                        main_state       <= MS_OP_CAP_A0;
                    end
                end

                MS_CFG_WAIT_CHK: begin
                    cfg_state_dbg <= 3'd2;
                    if (checker_done) begin
                        if (!checker_cfg_ok) begin
                            config_busy_reg          <= 1'b0;
                            config_busy_pad_reg      <= 1'b0;
                            config_valid_reg         <= 1'b0;
                            config_error_reg         <= 1'b1;
                            config_error_code_reg    <= checker_error_code;
                            main_state               <= MS_IDLE;
                        end else begin
                            precomp_start_reg <= 1'b1;
                            cfg_state_dbg     <= 3'd3;
                            main_state        <= MS_CFG_WAIT_PRE;
                        end
                    end
                end

                MS_CFG_WAIT_PRE: begin
                    if (precomp_done) begin
                        if (precomp_ok) begin
                            enc_m0_cfg   <= m0_cfg;
                            enc_m1_cfg   <= m1_cfg;
                            enc_m2_cfg   <= m2_cfg;
                            enc_m3_cfg   <= m3_cfg;
                            enc_m4_cfg   <= m4_cfg;
                            enc_m5_cfg   <= m5_cfg;
                            slice_m0_cfg <= m0_cfg;
                            slice_m1_cfg <= m1_cfg;
                            slice_m2_cfg <= m2_cfg;
                            slice_m3_cfg <= m3_cfg;
                            slice_m4_cfg <= m4_cfg;
                            slice_m5_cfg <= m5_cfg;
                            corr_m0_cfg  <= m0_cfg;
                            corr_m0_bit3_corrector_reg <= m0_cfg[3];
                            corr_m0_bit4_corrector_reg <= m0_cfg[4];
                            corr_m1_cfg  <= m1_cfg;
                            corr_m2_cfg  <= m2_cfg;
                            corr_m3_cfg  <= m3_cfg;
                            corr_m4_cfg  <= m4_cfg;
                            corr_m5_cfg  <= m5_cfg;
                        end
                        config_valid_reg      <= precomp_ok;
                        config_error_reg      <= !precomp_ok;
                        config_error_code_reg <= precomp_ok ? 4'd0 : 4'd6;
                        config_busy_reg       <= 1'b0;
                        config_busy_pad_reg   <= 1'b0;
                        cfg_state_dbg         <= 3'd4;
                        main_state            <= MS_IDLE;
                    end
                end

                /*
                 * Legacy/unreachable encodings. V12 no longer uses the wide
                 * config-commit register bank; removing it deletes the routed
                 * _2124-style max-slew/max-cap mux-select cluster.
                 */
                MS_CFG_COMMIT1,
                MS_CFG_COMMIT2: begin
                    config_busy_reg      <= 1'b0;
                    config_busy_pad_reg  <= 1'b0;
                    main_state           <= MS_IDLE;
                end

                MS_OP_CAP_A0: begin
                    op_state_dbg <= 4'd1;
                    A_reg[7:0]      <= A_in_shadow_reg[7:0];
                    A_bit5_enc_reg  <= A_in_shadow_reg[5];
                    A_bit4_enc_reg  <= A_in_shadow_reg[4];
                    main_state      <= MS_OP_CAP_A1;
                end

                MS_OP_CAP_A1: begin
                    op_state_dbg <= 4'd1;
                    A_reg[15:8] <= A_in_shadow_reg[15:8];
                    main_state   <= MS_OP_CAP_A2;
                end

                MS_OP_CAP_A2: begin
                    op_state_dbg  <= 4'd1;
                    A_reg[23:16] <= A_in_shadow_reg[23:16];
                    main_state    <= MS_OP_CAP_B0;
                end

                MS_OP_CAP_B0: begin
                    op_state_dbg <= 4'd1;
                    B_reg[7:0]      <= B_in_shadow_reg[7:0];
                    B_bit5_enc_reg  <= B_in_shadow_reg[5];
                    B_bit4_enc_reg  <= B_in_shadow_reg[4];
                    main_state      <= MS_OP_CAP_B1;
                end

                MS_OP_CAP_B1: begin
                    op_state_dbg <= 4'd1;
                    B_reg[15:8] <= B_in_shadow_reg[15:8];
                    main_state   <= MS_OP_CAP_B2;
                end

                MS_OP_CAP_B2: begin
                    op_state_dbg  <= 4'd1;
                    B_reg[23:16] <= B_in_shadow_reg[23:16];
                    main_state    <= MS_OP_INIT_FLAGS;
                end

                MS_OP_INIT_FLAGS: begin
                    op_state_dbg                 <= 4'd1;
                    error_detected_reg           <= 1'b0;
                    corrected_reg                <= 1'b0;
                    Corrected                    <= 1'b0;
                    valid_reg                    <= 1'b0;
                    uncorrectable_reg            <= 1'b0;
                    last_mismatch_mask_reg       <= 6'd0;
                    last_mismatch_count_reg      <= 3'd0;
                    last_corrected_lane_mask_reg <= 6'd0;
                    residue_error_reg            <= 1'b0;
                    range_error_reg              <= 1'b0;
                    main_state                   <= MS_OP_START_RANGE;
                end

                MS_OP_START_RANGE: begin
                    op_state_dbg       <= 4'd1;
                    op_range_start_reg <= 1'b1;
                    main_state         <= MS_OP_WAIT_RANGE;
                end

                MS_OP_WAIT_RANGE: begin
                    op_state_dbg <= 4'd1;
                    if (op_range_done) begin
                        raw_range_error_reg <= op_range_error;
                        main_state          <= MS_OP_START_ENC;
                    end
                end

                MS_OP_START_ENC: begin
                    op_state_dbg   <= 4'd1;
                    enc_start_reg  <= 1'b1;
                    main_state     <= MS_OP_WAIT_ENC;
                end

                MS_OP_WAIT_ENC: begin
                    op_state_dbg <= 4'd2;
                    if (enc_done) begin
                        if (!enc_select_b_reg) begin
                            main_state <= MS_OP_STORE_A0;
                        end else begin
                            main_state <= MS_OP_STORE_B0;
                        end
                    end
                end

                MS_OP_STORE_A0: begin
                    op_state_dbg <= 4'd2;
                    a_res_flat_reg[(0*WM)+:(2*WM)] <= enc_res_flat[(0*WM)+:(2*WM)];
                    main_state <= MS_OP_STORE_A1;
                end

                MS_OP_STORE_A1: begin
                    op_state_dbg <= 4'd2;
                    a_res_flat_reg[(2*WM)+:(2*WM)] <= enc_res_flat[(2*WM)+:(2*WM)];
                    main_state <= MS_OP_STORE_A2;
                end

                MS_OP_STORE_A2: begin
                    op_state_dbg <= 4'd2;
                    a_res_flat_reg[(4*WM)+:(2*WM)] <= enc_res_flat[(4*WM)+:(2*WM)];
                    enc_select_b_reg <= 1'b1;
                    main_state <= MS_OP_START_ENC;
                end

                MS_OP_STORE_B0: begin
                    op_state_dbg <= 4'd2;
                    b_res_flat_reg[(0*WM)+:(2*WM)] <= enc_res_flat[(0*WM)+:(2*WM)];
                    main_state <= MS_OP_STORE_B1;
                end

                MS_OP_STORE_B1: begin
                    op_state_dbg <= 4'd2;
                    b_res_flat_reg[(2*WM)+:(2*WM)] <= enc_res_flat[(2*WM)+:(2*WM)];
                    main_state <= MS_OP_STORE_B2;
                end

                MS_OP_STORE_B2: begin
                    op_state_dbg <= 4'd2;
                    b_res_flat_reg[(4*WM)+:(2*WM)] <= enc_res_flat[(4*WM)+:(2*WM)];
                    lane_idx        <= 3'd0;
                    op_lane_oh      <= 6'b000001;
                    slice_m_lane_oh <= 6'b000001;
                    slice_a_lane_oh <= 6'b000001;
                    slice_b_lane_oh <= 6'b000001;

                    /* V33B functional alignment fix.
                       V33A made lane selection self-shifting, but the first
                       clean ADD showed lane 0 left as zero and then corrected
                       as a false residue fault.  Seed the lane-0 slice inputs
                       directly here, after A/B residue capture is complete,
                       then start the slice.  Later lanes still use the
                       self-shifting one-hot PREP_M/A/B sequence. */
                    slice_m_reg <= slice_m0_cfg;
                    slice_a_reg             <= a_res_flat_reg[(0*WM)+:WM];
                    slice_a_bit0_launch_reg <= a_res_flat_reg[(0*WM)+0];
                    slice_b_reg             <= b_res_flat_reg[(0*WM)+:WM];
                    main_state  <= MS_OP_START_LANE;
                end

                MS_OP_PREP_M: begin
                    op_state_dbg <= 4'd3;
                    slice_m_reg <= slice_m_next;
                    /* Phase-stagger the selector copies.  Each selector bank
                       is loaded in the state before its mux is used, so the
                       three physical mux banks do not need to share one binary
                       lane_idx decoder. */
                    slice_a_lane_oh <= op_lane_oh;
                    main_state <= MS_OP_PREP_A;
                end

                MS_OP_PREP_A: begin
                    op_state_dbg <= 4'd3;
                    slice_a_reg             <= slice_a_next;
                    slice_a_bit0_launch_reg <= slice_a_next[0];
                    slice_b_lane_oh         <= op_lane_oh;
                    main_state <= MS_OP_PREP_B;
                end

                MS_OP_PREP_B: begin
                    op_state_dbg <= 4'd3;
                    slice_b_reg <= slice_b_next;
                    main_state <= MS_OP_START_LANE;
                end

                MS_OP_START_LANE: begin
                    op_state_dbg    <= 4'd3;
                    slice_start_reg <= 1'b1;
                    main_state      <= MS_OP_WAIT_LANE;
                end

                MS_OP_WAIT_LANE: begin
                    op_state_dbg <= 4'd4;
                    if (slice_done) begin
                        slice_z_res_hold           <= slice_z_res;
                        slice_z_res_bit0_store_reg <= slice_z_res[0];
                        slice_z_res_bit2_store_reg <= slice_z_res[2];
                        slice_z_res_bit3_store_reg <= slice_z_res[3];
                        main_state                 <= MS_OP_STORE_Z;
                    end
                end

                MS_OP_STORE_Z: begin
                    op_state_dbg <= 4'd4;
                    /* V36A: store from a local holding register, not directly
                       from the slice module output. This shortens the exposed
                       slice_z_res route that repeatedly showed final antenna. */
                    case (lane_idx)
                        3'd0: z0_reg <= slice_z_store_wire;
                        3'd1: z1_reg <= slice_z_store_wire;
                        3'd2: z2_reg <= slice_z_store_wire;
                        3'd3: z3_reg <= slice_z_store_wire;
                        3'd4: z4_reg <= slice_z_store_wire;
                        3'd5: z5_reg <= slice_z_store_wire;
                        default: begin end
                    endcase

                    if (lane_idx == 3'd5) begin
                        main_state <= MS_OP_START_CORR;
                    end else begin
                        op_lane_oh      <= op_lane_oh_next;
                        slice_m_lane_oh <= op_lane_oh_next;
                        lane_idx        <= lane_idx + 3'd1;
                        main_state      <= MS_OP_PREP_M;
                    end
                end

                MS_OP_START_CORR: begin
                    op_state_dbg        <= 4'd5;
                    corrector_start_reg <= 1'b1;
                    main_state          <= MS_OP_WAIT_CORR;
                end

                MS_OP_WAIT_CORR: begin
                    op_state_dbg <= 4'd6;
                    if (corrector_done) begin
                        main_state <= MS_OP_LATCH_CAND0;
                    end
                end

                MS_OP_LATCH_CAND0: begin
                    op_state_dbg <= 4'd6;
                    corrector_candidate_base_hold[6:0] <= corrector_candidate_base[6:0];
                    main_state <= MS_OP_LATCH_CAND1;
                end

                MS_OP_LATCH_CAND1: begin
                    op_state_dbg <= 4'd6;
                    corrector_candidate_base_hold[13:7] <= corrector_candidate_base[13:7];
                    main_state <= MS_OP_LATCH_CAND2;
                end

                MS_OP_LATCH_CAND2: begin
                    op_state_dbg <= 4'd6;
                    corrector_candidate_base_hold[PW-1:14] <= corrector_candidate_base[PW-1:14];
                    main_state <= MS_OP_LATCH_FLAGS;
                end

                MS_OP_LATCH_FLAGS: begin
                    op_state_dbg <= 4'd6;
                    corrector_residue_error_hold     <= corrector_residue_error;
                    corrector_corrected_success_hold <= corrector_corrected_success;
                    corrector_uncorrectable_hold     <= corrector_uncorrectable;
                    corrector_lane_mask_hold         <= corrector_lane_mask;
                    corrector_mismatch_mask_hold     <= corrector_mismatch_mask;
                    corrector_mismatch_count_hold    <= corrector_mismatch_count;
                    main_state <= MS_OP_LATCH_M0;
                end

                MS_OP_LATCH_M0: begin
                    op_state_dbg <= 4'd6;
                    range_M_base_hold[9:0] <= M_base_live[9:0];
                    main_state <= MS_OP_LATCH_M1;
                end

                MS_OP_LATCH_M1: begin
                    op_state_dbg <= 4'd6;
                    range_M_base_hold[PW-1:10] <= M_base_live[PW-1:10];
                    main_state <= MS_OP_LATCH_H0;
                end

                MS_OP_LATCH_H0: begin
                    op_state_dbg <= 4'd6;
                    range_half_range_hold[9:0] <= half_range_live[9:0];
                    main_state <= MS_OP_LATCH_H1;
                end

                MS_OP_LATCH_H1: begin
                    op_state_dbg <= 4'd6;
                    range_half_range_hold[PW-1:10] <= half_range_live[PW-1:10];
                    main_state <= MS_OP_START_FINAL_RANGE;
                end

                MS_OP_START_FINAL_RANGE: begin
                    op_state_dbg          <= 4'd7;
                    final_range_start_reg <= 1'b1;
                    main_state            <= MS_OP_WAIT_FINAL_RANGE;
                end

                MS_OP_WAIT_FINAL_RANGE: begin
                    op_state_dbg <= 4'd7;
                    if (final_range_done) begin
                        main_state <= MS_OP_FINAL;
                    end
                end

                MS_OP_FINAL: begin
                    op_state_dbg                 <= 4'd7;
                    residue_error_reg            <= corrector_residue_error_hold;
                    range_error_reg              <= range_error_wire;
                    error_detected_reg           <= corrector_residue_error_hold |
                                                    range_error_wire |
                                                    (corrector_uncorrectable_hold & ~range_error_wire);
                    corrected_reg                <= corrector_corrected_success_hold & ~range_error_wire;
                    Corrected                    <= corrector_corrected_success_hold & ~range_error_wire;
                    valid_reg                    <= config_valid_reg &
                                                    ~range_error_wire &
                                                    ~(corrector_uncorrectable_hold & ~range_error_wire);
                    uncorrectable_reg            <= corrector_uncorrectable_hold & ~range_error_wire;
                    last_mismatch_mask_reg       <= corrector_mismatch_mask_hold;
                    last_mismatch_count_reg      <= corrector_mismatch_count_hold;
                    last_corrected_lane_mask_reg <= corrector_lane_mask_hold;
                    x_out_core_reg               <= x_centered_wire;
                    X_out                        <= x_centered_wire;
                    Done                         <= 1'b1;
                    op_busy_reg                  <= 1'b0;
                    enc_select_b_reg             <= 1'b0;
                    main_state                   <= MS_IDLE;
                end

                default: begin
                    main_state <= MS_IDLE;
                end
            endcase
        end
    end

endmodule
