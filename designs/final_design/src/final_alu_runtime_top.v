`timescale 1ns/1ps
// V19 source marker: lane operands are pre-captured and slice datapath is bit-serial/modular.
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
    output wire                     Corrected,
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
    localparam integer MAIN_STATE_W = 28;
    localparam [MAIN_STATE_W-1:0]
        MS_IDLE           = 28'h0000001,
        MS_CFG_WAIT_CHK   = 28'h0000002,
        MS_CFG_WAIT_PRE   = 28'h0000004,

        /* Byte-wide operation-capture states. */
        MS_OP_CAP_A0      = 28'h0000008,
        MS_OP_CAP_A1      = 28'h0000010,
        MS_OP_CAP_A2      = 28'h0000020,
        MS_OP_CAP_B0      = 28'h0000040,
        MS_OP_CAP_B1      = 28'h0000080,
        MS_OP_CAP_B2      = 28'h0000100,
        MS_OP_INIT_FLAGS  = 28'h0000200,
        MS_OP_INIT_RANGE  = 28'h0000400,
        MS_OP_INIT_MUL0   = 28'h0000800,
        MS_OP_INIT_MUL1   = 28'h0001000,
        MS_OP_INIT_MUL2   = 28'h0002000,

        /* Split saturated-MUL range tracker states. */
        MS_OP_MUL_ACC     = 28'h0004000,
        MS_OP_MUL_MCAND   = 28'h0008000,
        MS_OP_MUL_MULT    = 28'h0010000,
        MS_OP_START_ENC   = 28'h0020000,
        MS_OP_WAIT_ENC    = 28'h0040000,

        /* Lane input pre-capture: breaks the lane_idx decode net away from
         * the active slice datapath and z-register store cone. */
        MS_OP_PREP_LANE   = 28'h0080000,
        MS_OP_START_LANE  = 28'h0100000,
        MS_OP_WAIT_LANE   = 28'h0200000,
        MS_OP_START_CORR  = 28'h0400000,
        MS_OP_WAIT_CORR   = 28'h0800000,
        MS_OP_FINAL       = 28'h1000000,

        /* Legacy/unreachable config-commit fallbacks. */
        MS_CFG_COMMIT0    = 28'h2000000,
        MS_CFG_COMMIT1    = 28'h4000000,
        MS_CFG_COMMIT2    = 28'h8000000;

    /* Range multiplier side-path constants.
       For 5-bit moduli, the largest base product is below 2^PW.
       Saturating at 2^PW is therefore always above half_range, so it is
       sufficient for overflow/range detection without a 24-bit multiplier. */
    localparam [PW:0] MUL_SAT_MAX    = {1'b1, {PW{1'b0}}};
    localparam [5:0]  MUL_LAST_COUNT = PW;

    (* keep = "true", dont_touch = "true", fsm_encoding = "none" *) reg [MAIN_STATE_W-1:0] main_state;
    reg [2:0] cfg_state_dbg;
    reg [3:0] op_state_dbg;
    reg [2:0] lane_idx;


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
    wire detect_en_cfg;
    wire correct_en_cfg;
    wire cfg_lock_cfg;
    wire cfg_loaded_cfg;
    reg  cfg_clear_loaded;
    wire cfg_write_allow;

    reg        config_valid_reg;
    reg        config_busy_reg;
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
    reg  [WM-1:0] slice_a_reg;
    reg  [WM-1:0] slice_b_reg;
    reg  [WM-1:0] slice_m_reg;
    reg  [1:0] op_sel_reg;

    reg  signed [XW-1:0] A_reg;
    reg  signed [XW-1:0] B_reg;

    /* Saturated true-range tracker.
       The residue datapath still performs the actual RRNS operation, while this
       small side-path only decides whether the mathematical result is outside
       the signed base range. With 5-bit runtime moduli, the base product fits
       in PW=20, so a 48-bit range multiplier is unnecessary and physically
       expensive. */
    reg               raw_range_error_reg;
    reg  [PW:0]       mul_acc_sat_reg;
    reg  [PW:0]       mul_mcand_sat_reg;
    reg  [PW:0]       mul_mult_sat_reg;
    reg  [5:0]        mul_count_reg;
    wire [PW:0]       mul_addend_sat_wire;
    wire [PW+1:0]     mul_acc_sum_wire;
    wire [PW:0]       mul_acc_next_sat_wire;
    wire [PW+1:0]     mul_mcand_shift_wire;
    wire [PW:0]       mul_mcand_next_sat_wire;
    wire [XW-1:0]     a_abs_wire;
    wire [XW-1:0]     b_abs_wire;
    wire [XW:0]       a_abs_ext_wire;
    wire [XW:0]       b_abs_ext_wire;
    wire [XW:0]       mul_sat_max_ext_wire;
    wire [PW:0]       a_abs_sat_wire;
    wire [PW:0]       b_abs_sat_wire;
    wire signed [XW:0] add_true_wire;
    wire signed [XW:0] sub_true_wire;
    wire signed [XW:0] half_range_xw_wire;
    wire signed [XW:0] neg_half_range_xw_wire;
    wire              add_range_error_wire;
    wire              sub_range_error_wire;

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

    wire signed [XW-1:0] x_centered_wire;
    wire range_error_wire;
    wire [WM-1:0] slice_a_sel;
    wire [WM-1:0] slice_b_sel;
    wire [WM-1:0] slice_m_sel;

    wire [2:0] cfg_state_dbg_wire;
    wire [3:0] op_state_dbg_wire;

    assign z_res_flat = {z5_reg, z4_reg, z3_reg, z2_reg, z1_reg, z0_reg};

    assign M_base_live               = checker_M_base;
    assign half_range_live           = checker_half_range;
    assign usable_subset_bitmap_live = config_valid_reg ? precomp_bitmap : 15'd0;

    assign M_base_reg               = M_base_live;
    assign half_range_reg           = half_range_live;
    assign usable_subset_bitmap_reg = usable_subset_bitmap_live;

    assign mul_addend_sat_wire     = mul_mult_sat_reg[0] ? mul_mcand_sat_reg : {(PW+1){1'b0}};
    assign mul_acc_sum_wire        = {1'b0, mul_acc_sat_reg} + {1'b0, mul_addend_sat_wire};
    assign mul_acc_next_sat_wire   = (mul_acc_sum_wire > {1'b0, MUL_SAT_MAX}) ?
                                     MUL_SAT_MAX : mul_acc_sum_wire[PW:0];
    assign mul_mcand_shift_wire    = {1'b0, mul_mcand_sat_reg} << 1;
    assign mul_mcand_next_sat_wire = (mul_mcand_shift_wire > {1'b0, MUL_SAT_MAX}) ?
                                     MUL_SAT_MAX : mul_mcand_shift_wire[PW:0];

    assign a_abs_wire              = A_reg[XW-1] ? ((~A_reg) + {{(XW-1){1'b0}}, 1'b1}) : A_reg;
    assign b_abs_wire              = B_reg[XW-1] ? ((~B_reg) + {{(XW-1){1'b0}}, 1'b1}) : B_reg;
    assign a_abs_ext_wire          = {1'b0, a_abs_wire};
    assign b_abs_ext_wire          = {1'b0, b_abs_wire};
    assign mul_sat_max_ext_wire    = {{(XW-PW){1'b0}}, MUL_SAT_MAX};
    assign a_abs_sat_wire          = (a_abs_ext_wire > mul_sat_max_ext_wire) ? MUL_SAT_MAX : a_abs_ext_wire[PW:0];
    assign b_abs_sat_wire          = (b_abs_ext_wire > mul_sat_max_ext_wire) ? MUL_SAT_MAX : b_abs_ext_wire[PW:0];

    assign add_true_wire           = {A_reg[XW-1], A_reg} + {B_reg[XW-1], B_reg};
    assign sub_true_wire           = {A_reg[XW-1], A_reg} - {B_reg[XW-1], B_reg};
    assign half_range_xw_wire      = $signed({1'b0, {{(XW-PW){1'b0}}, half_range_live}});
    assign neg_half_range_xw_wire  = -half_range_xw_wire;
    assign add_range_error_wire    = (add_true_wire > half_range_xw_wire) ||
                                     (add_true_wire < neg_half_range_xw_wire);
    assign sub_range_error_wire    = (sub_true_wire > half_range_xw_wire) ||
                                     (sub_true_wire < neg_half_range_xw_wire);

    assign Busy              = config_busy_reg | op_busy_reg;
    assign Config_Valid      = config_valid_reg;
    assign Config_Busy       = config_busy_reg;
    assign Config_Error      = config_error_reg;
    assign Config_Error_Code = config_error_code_reg;
    assign Error_Detected    = error_detected_reg;
    assign Corrected         = corrected_reg;
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

    final_alu_encoder_runtime #(.WM(WM), .XW(XW)) u_encoder (
        .clk(clk),
        .rst_n(rst_encoder_n),
        .start(enc_start_reg),
        .x_in(enc_select_b_reg ? B_reg : A_reg),
        .m0(m0_cfg),
        .m1(m1_cfg),
        .m2(m2_cfg),
        .m3(m3_cfg),
        .m4(m4_cfg),
        .m5(m5_cfg),
        .done(enc_done),
        .res_flat(enc_res_flat)
    );

    final_alu_slice_runtime #(.WM(WM)) u_slice (
        .clk(clk),
        .rst_n(rst_slice_n),
        .start(slice_start_reg),
        .op_sel(op_sel_reg),
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
        .m0(m0_cfg),
        .m1(m1_cfg),
        .m2(m2_cfg),
        .m3(m3_cfg),
        .m4(m4_cfg),
        .m5(m5_cfg),
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
        .M_base(M_base_live),
        .half_range(half_range_live),
        .candidate_base(corrector_candidate_base),
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

    assign slice_a_sel = slice_a_reg;
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
            cfg_clear_loaded             <= 1'b0;
            checker_start_reg            <= 1'b0;
            precomp_start_reg            <= 1'b0;
            enc_start_reg                <= 1'b0;
            enc_select_b_reg             <= 1'b0;
            slice_start_reg              <= 1'b0;
            corrector_start_reg          <= 1'b0;
            config_valid_reg             <= 1'b0;
            config_busy_reg              <= 1'b0;
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
            Done                <= 1'b0;

            case (main_state)
                MS_IDLE: begin
                    cfg_state_dbg <= 3'd0;
                    op_state_dbg  <= 4'd0;
                    lane_idx      <= 3'd0;
                    if (cfg_apply && !Busy) begin
                        config_busy_reg       <= 1'b1;
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
                        config_valid_reg      <= precomp_ok;
                        config_error_reg      <= !precomp_ok;
                        config_error_code_reg <= precomp_ok ? 4'd0 : 4'd6;
                        config_busy_reg       <= 1'b0;
                        cfg_state_dbg         <= 3'd4;
                        main_state            <= MS_IDLE;
                    end
                end

                /*
                 * Legacy/unreachable encodings. V12 no longer uses the wide
                 * config-commit register bank; removing it deletes the routed
                 * _2124-style max-slew/max-cap mux-select cluster.
                 */
                MS_CFG_COMMIT0,
                MS_CFG_COMMIT1,
                MS_CFG_COMMIT2: begin
                    config_busy_reg <= 1'b0;
                    main_state      <= MS_IDLE;
                end

                MS_OP_CAP_A0: begin
                    op_state_dbg <= 4'd1;
                    A_reg[7:0]  <= A_in[7:0];
                    main_state   <= MS_OP_CAP_A1;
                end

                MS_OP_CAP_A1: begin
                    op_state_dbg <= 4'd1;
                    A_reg[15:8] <= A_in[15:8];
                    main_state   <= MS_OP_CAP_A2;
                end

                MS_OP_CAP_A2: begin
                    op_state_dbg  <= 4'd1;
                    A_reg[23:16] <= A_in[23:16];
                    main_state    <= MS_OP_CAP_B0;
                end

                MS_OP_CAP_B0: begin
                    op_state_dbg <= 4'd1;
                    B_reg[7:0]  <= B_in[7:0];
                    main_state   <= MS_OP_CAP_B1;
                end

                MS_OP_CAP_B1: begin
                    op_state_dbg <= 4'd1;
                    B_reg[15:8] <= B_in[15:8];
                    main_state   <= MS_OP_CAP_B2;
                end

                MS_OP_CAP_B2: begin
                    op_state_dbg  <= 4'd1;
                    B_reg[23:16] <= B_in[23:16];
                    main_state    <= MS_OP_INIT_FLAGS;
                end

                MS_OP_INIT_FLAGS: begin
                    op_state_dbg                 <= 4'd1;
                    error_detected_reg           <= 1'b0;
                    corrected_reg                <= 1'b0;
                    valid_reg                    <= 1'b0;
                    uncorrectable_reg            <= 1'b0;
                    last_mismatch_mask_reg       <= 6'd0;
                    last_mismatch_count_reg      <= 3'd0;
                    last_corrected_lane_mask_reg <= 6'd0;
                    residue_error_reg            <= 1'b0;
                    range_error_reg              <= 1'b0;
                    main_state                   <= (op_sel_reg == 2'b10) ? MS_OP_INIT_MUL0 : MS_OP_INIT_RANGE;
                end

                MS_OP_INIT_RANGE: begin
                    op_state_dbg <= 4'd1;
                    case (op_sel_reg)
                        2'b00: raw_range_error_reg <= add_range_error_wire;
                        2'b01: raw_range_error_reg <= sub_range_error_wire;
                        default: raw_range_error_reg <= 1'b0;
                    endcase
                    main_state <= MS_OP_START_ENC;
                end

                MS_OP_INIT_MUL0: begin
                    op_state_dbg        <= 4'd1;
                    raw_range_error_reg <= 1'b0;
                    mul_acc_sat_reg     <= {(PW+1){1'b0}};
                    mul_count_reg       <= 6'd0;
                    main_state          <= MS_OP_INIT_MUL1;
                end

                MS_OP_INIT_MUL1: begin
                    op_state_dbg      <= 4'd1;
                    mul_mcand_sat_reg <= a_abs_sat_wire;
                    main_state        <= MS_OP_INIT_MUL2;
                end

                MS_OP_INIT_MUL2: begin
                    op_state_dbg     <= 4'd1;
                    mul_mult_sat_reg <= b_abs_sat_wire;
                    main_state       <= MS_OP_MUL_ACC;
                end

                MS_OP_MUL_ACC: begin
                    op_state_dbg    <= 4'd1;
                    mul_acc_sat_reg <= mul_acc_next_sat_wire;
                    main_state      <= MS_OP_MUL_MCAND;
                end

                MS_OP_MUL_MCAND: begin
                    op_state_dbg      <= 4'd1;
                    mul_mcand_sat_reg <= mul_mcand_next_sat_wire;
                    main_state        <= MS_OP_MUL_MULT;
                end

                MS_OP_MUL_MULT: begin
                    op_state_dbg     <= 4'd1;
                    mul_mult_sat_reg <= {1'b0, mul_mult_sat_reg[PW:1]};
                    if (mul_count_reg == MUL_LAST_COUNT) begin
                        /*
                         * mul_acc_sat_reg already contains the accumulator
                         * produced by the preceding MS_OP_MUL_ACC state.
                         */
                        raw_range_error_reg <= (mul_acc_sat_reg > {1'b0, half_range_live});
                        main_state          <= MS_OP_START_ENC;
                    end else begin
                        mul_count_reg <= mul_count_reg + 6'd1;
                        main_state    <= MS_OP_MUL_ACC;
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
                            a_res_flat_reg   <= enc_res_flat;
                            enc_select_b_reg <= 1'b1;
                            main_state       <= MS_OP_START_ENC;
                        end else begin
                            b_res_flat_reg <= enc_res_flat;
                            lane_idx       <= 3'd0;
                            main_state     <= MS_OP_PREP_LANE;
                        end
                    end
                end

                MS_OP_PREP_LANE: begin
                    op_state_dbg <= 4'd3;
                    case (lane_idx)
                        3'd0: begin
                            slice_a_reg <= a_res_flat_reg[(0*WM)+:WM];
                            slice_b_reg <= b_res_flat_reg[(0*WM)+:WM];
                            slice_m_reg <= m0_cfg;
                        end
                        3'd1: begin
                            slice_a_reg <= a_res_flat_reg[(1*WM)+:WM];
                            slice_b_reg <= b_res_flat_reg[(1*WM)+:WM];
                            slice_m_reg <= m1_cfg;
                        end
                        3'd2: begin
                            slice_a_reg <= a_res_flat_reg[(2*WM)+:WM];
                            slice_b_reg <= b_res_flat_reg[(2*WM)+:WM];
                            slice_m_reg <= m2_cfg;
                        end
                        3'd3: begin
                            slice_a_reg <= a_res_flat_reg[(3*WM)+:WM];
                            slice_b_reg <= b_res_flat_reg[(3*WM)+:WM];
                            slice_m_reg <= m3_cfg;
                        end
                        3'd4: begin
                            slice_a_reg <= a_res_flat_reg[(4*WM)+:WM];
                            slice_b_reg <= b_res_flat_reg[(4*WM)+:WM];
                            slice_m_reg <= m4_cfg;
                        end
                        3'd5: begin
                            slice_a_reg <= a_res_flat_reg[(5*WM)+:WM];
                            slice_b_reg <= b_res_flat_reg[(5*WM)+:WM];
                            slice_m_reg <= m5_cfg;
                        end
                        default: begin
                            slice_a_reg <= {WM{1'b0}};
                            slice_b_reg <= {WM{1'b0}};
                            slice_m_reg <= {WM{1'b0}};
                        end
                    endcase
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
                        case (lane_idx)
                            3'd0: z0_reg <= slice_z_res;
                            3'd1: z1_reg <= slice_z_res;
                            3'd2: z2_reg <= slice_z_res;
                            3'd3: z3_reg <= slice_z_res;
                            3'd4: z4_reg <= slice_z_res;
                            3'd5: z5_reg <= slice_z_res;
                            default: begin end
                        endcase
                        if (lane_idx == 3'd5) begin
                            main_state <= MS_OP_START_CORR;
                        end else begin
                            lane_idx   <= lane_idx + 3'd1;
                            main_state <= MS_OP_PREP_LANE;
                        end
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
                        main_state <= MS_OP_FINAL;
                    end
                end

                MS_OP_FINAL: begin
                    op_state_dbg                 <= 4'd7;
                    residue_error_reg            <= corrector_residue_error;
                    range_error_reg              <= range_error_wire;
                    error_detected_reg           <= corrector_residue_error |
                                                    range_error_wire |
                                                    (corrector_uncorrectable & ~range_error_wire);
                    corrected_reg                <= corrector_corrected_success & ~range_error_wire;
                    valid_reg                    <= config_valid_reg &
                                                    ~range_error_wire &
                                                    ~(corrector_uncorrectable & ~range_error_wire);
                    uncorrectable_reg            <= corrector_uncorrectable & ~range_error_wire;
                    last_mismatch_mask_reg       <= corrector_mismatch_mask;
                    last_mismatch_count_reg      <= corrector_mismatch_count;
                    last_corrected_lane_mask_reg <= corrector_lane_mask;
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
