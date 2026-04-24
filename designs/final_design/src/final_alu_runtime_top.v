`timescale 1ns/1ps
module final_alu_runtime_top #(
    parameter integer WM = 5,
    parameter integer XW = 24,
    parameter integer PW = 32
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

    localparam [3:0]
        MS_IDLE          = 4'd0,
        MS_CFG_WAIT_CHK  = 4'd1,
        MS_CFG_WAIT_PRE  = 4'd2,
        MS_OP_MUL_STEP   = 4'd3,
        MS_OP_START_ENC  = 4'd4,
        MS_OP_WAIT_ENC   = 4'd5,
        MS_OP_START_LANE = 4'd6,
        MS_OP_WAIT_LANE  = 4'd7,
        MS_OP_START_CORR = 4'd8,
        MS_OP_WAIT_CORR  = 4'd9,
        MS_OP_FINAL      = 4'd10;

    reg [3:0] main_state;
    reg [2:0] cfg_state_dbg;
    reg [3:0] op_state_dbg;
    reg [2:0] lane_idx;

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
    reg [PW-1:0] M_base_reg;
    reg [PW-1:0] half_range_reg;
    reg [14:0] usable_subset_bitmap_reg;

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
    reg  [1:0] op_sel_reg;

    reg  signed [XW-1:0] A_reg;
    reg  signed [XW-1:0] B_reg;
    reg  signed [(2*XW)-1:0] raw_true_reg;

    /* Sequential multiplier used only for range checking.
       This removes the large 24x24 combinational multiplier from the top. */
    reg  [(2*XW)-1:0] mul_acc_reg;
    reg  [(2*XW)-1:0] mul_mcand_reg;
    reg  [XW-1:0]     mul_mult_reg;
    reg               mul_neg_reg;
    reg  [5:0]        mul_count_reg;
    wire [(2*XW)-1:0] mul_addend_wire;
    wire [(2*XW)-1:0] mul_acc_next_wire;

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
    assign mul_addend_wire   = mul_mult_reg[0] ? mul_mcand_reg : {(2*XW){1'b0}};
    assign mul_acc_next_wire = mul_acc_reg + mul_addend_wire;

    assign Busy              = config_busy_reg | op_busy_reg;
    assign Config_Valid      = config_valid_reg;
    assign Config_Busy       = config_busy_reg;
    assign Config_Error      = config_error_reg;
    assign Config_Error_Code = config_error_code_reg;
    assign Error_Detected    = error_detected_reg;
    assign Corrected         = corrected_reg;
    assign Valid             = valid_reg;
    assign Uncorrectable     = uncorrectable_reg;

    assign cfg_write_allow = !Busy && !(cfg_lock_cfg && config_valid_reg);

    final_alu_cfg_regs #(.WM(WM)) u_cfg_regs (
        .clk(clk),
        .rst_n(rst_n),
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
        .rst_n(rst_n),
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
        .rst_n(rst_n),
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
        .rst_n(rst_n),
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
        .rst_n(rst_n),
        .start(slice_start_reg),
        .op_sel(op_sel_reg),
        .a_res(slice_a_sel),
        .b_res(slice_b_sel),
        .modulus(slice_m_sel),
        .done(slice_done),
        .z_res(slice_z_res)
    );

    final_alu_corrector_search #(.WM(WM), .PW(PW)) u_corrector (
        .clk(clk),
        .rst_n(rst_n),
        .start(corrector_start_reg),
        .enable_detection(detect_en_cfg),
        .enable_correction(correct_en_cfg),
        .z_res_flat(z_res_flat),
        .M_base(M_base_reg),
        .usable_subset_bitmap(usable_subset_bitmap_reg),
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
        .raw_true(raw_true_reg),
        .M_base(M_base_reg),
        .half_range(half_range_reg),
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

    assign slice_a_sel = get_lane_res(a_res_flat_reg, lane_idx);
    assign slice_b_sel = get_lane_res(b_res_flat_reg, lane_idx);
    assign slice_m_sel = (lane_idx == 3'd0) ? m0_cfg :
                         (lane_idx == 3'd1) ? m1_cfg :
                         (lane_idx == 3'd2) ? m2_cfg :
                         (lane_idx == 3'd3) ? m3_cfg :
                         (lane_idx == 3'd4) ? m4_cfg :
                         (lane_idx == 3'd5) ? m5_cfg : {WM{1'b0}};

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
                4'h9: cfg_rdata = M_base_reg;
                4'hA: cfg_rdata = half_range_reg;
                4'hB: cfg_rdata = {17'd0, usable_subset_bitmap_reg};
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
                        A_reg  <= A_in;
                        B_reg  <= B_in;
                        op_sel_reg <= Op_Sel;
                        enc_select_b_reg <= 1'b0;
                        case (Op_Sel)
                            2'b00: raw_true_reg <= {{XW{A_in[XW-1]}}, A_in} + {{XW{B_in[XW-1]}}, B_in};
                            2'b01: raw_true_reg <= {{XW{A_in[XW-1]}}, A_in} - {{XW{B_in[XW-1]}}, B_in};
                            default: raw_true_reg <= {(2*XW){1'b0}};
                        endcase
                        mul_acc_reg   <= {(2*XW){1'b0}};
                        mul_mcand_reg <= A_in[XW-1] ? {{XW{1'b0}}, ((~A_in) + {{(XW-1){1'b0}},1'b1})}
                                                   : {{XW{1'b0}}, A_in};
                        mul_mult_reg  <= B_in[XW-1] ? ((~B_in) + {{(XW-1){1'b0}},1'b1}) : B_in;
                        mul_neg_reg   <= A_in[XW-1] ^ B_in[XW-1];
                        mul_count_reg <= 6'd0;
                        z0_reg                       <= {WM{1'b0}};
                        z1_reg                       <= {WM{1'b0}};
                        z2_reg                       <= {WM{1'b0}};
                        z3_reg                       <= {WM{1'b0}};
                        z4_reg                       <= {WM{1'b0}};
                        z5_reg                       <= {WM{1'b0}};
                        op_busy_reg                  <= 1'b1;
                        error_detected_reg           <= 1'b0;
                        corrected_reg                <= 1'b0;
                        valid_reg                    <= 1'b0;
                        uncorrectable_reg            <= 1'b0;
                        last_mismatch_mask_reg       <= 6'd0;
                        last_mismatch_count_reg      <= 3'd0;
                        last_corrected_lane_mask_reg <= 6'd0;
                        residue_error_reg            <= 1'b0;
                        range_error_reg              <= 1'b0;
                        main_state                   <= (Op_Sel == 2'b10) ? MS_OP_MUL_STEP : MS_OP_START_ENC;
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
                            M_base_reg               <= checker_M_base;
                            half_range_reg           <= checker_half_range;
                            usable_subset_bitmap_reg <= 15'd0;
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
                        config_busy_reg          <= 1'b0;
                        config_valid_reg         <= precomp_ok;
                        config_error_reg         <= !precomp_ok;
                        config_error_code_reg    <= precomp_ok ? 4'd0 : 4'd6;
                        M_base_reg               <= checker_M_base;
                        half_range_reg           <= checker_half_range;
                        usable_subset_bitmap_reg <= precomp_bitmap;
                        main_state               <= MS_IDLE;
                    end
                end


                MS_OP_MUL_STEP: begin
                    op_state_dbg <= 4'd1;
                    mul_acc_reg   <= mul_acc_next_wire;
                    mul_mcand_reg <= mul_mcand_reg << 1;
                    mul_mult_reg  <= {1'b0, mul_mult_reg[XW-1:1]};
                    if (mul_count_reg == (XW-1)) begin
                        raw_true_reg  <= mul_neg_reg ? -$signed(mul_acc_next_wire) : $signed(mul_acc_next_wire);
                        main_state    <= MS_OP_START_ENC;
                    end else begin
                        mul_count_reg <= mul_count_reg + 6'd1;
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
                            main_state     <= MS_OP_START_LANE;
                        end
                    end
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
                            main_state <= MS_OP_START_LANE;
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
