module lutein_dense_idxbuf #(
    parameter integer DATA_W = 4
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              load_en,
    input  wire [DATA_W-1:0] load_data,
    input  wire              ready_in,
    output reg  [DATA_W-1:0] data_out,
    output reg               valid_out
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out  <= '0;
            valid_out <= 1'b0;
        end else begin
            case ({load_en, valid_out && ready_in})
                2'b10: begin
                    data_out  <= load_data;
                    valid_out <= 1'b1;
                end
                2'b01: begin
                    valid_out <= 1'b0;
                end
                2'b11: begin
                    data_out  <= load_data;
                    valid_out <= 1'b1;
                end
                default: begin
                    valid_out <= valid_out;
                end
            endcase
        end
    end
endmodule


module lutein_slice_tensor_pe_idx #(
    parameter integer IN_LANES = 4,
    parameter integer OUT_CH   = 8,
    parameter integer ACT_W    = 4,
    parameter integer WGT_W    = 4,
    parameter integer PROD_W   = 8,
    parameter integer ACC_W    = 24,
    parameter integer PSUM_W   = 24,
    parameter integer IDX_W    = 4
) (
    input  wire                              clk,
    input  wire                              rst_n,

    input  wire                              in_valid,
    input  wire                              clear_acc,
    input  wire                              accum_en,

    input  wire                              out_ready,
    input  wire                              in_slice_fwd_ready,

    input  wire signed [IN_LANES*ACT_W-1:0]  in_slice_flat,
    input  wire        [IDX_W-1:0]           in_idx,
    input  wire signed [IN_LANES*OUT_CH*WGT_W-1:0] wgt_slice_flat,

    output wire                              in_ready,
    output reg                               out_valid,
    output reg  signed [OUT_CH*PSUM_W-1:0]   out_psum_flat,

    output reg  signed [IN_LANES*ACT_W-1:0]  in_slice_fwd_flat,
    output reg         [IDX_W-1:0]           in_idx_fwd,
    output reg                               in_slice_fwd_valid
);

    integer i;
    integer j;

    reg                    s0_valid;
    reg                    s0_zero_q;
    reg                    s0_accum_en;
    reg [IDX_W-1:0]        s0_idx_q;

    reg signed [IN_LANES*ACT_W-1:0] in_slice_q_flat;
    reg signed [ACT_W-1:0]          in_q [0:IN_LANES-1];
    reg signed [WGT_W-1:0]          w_q  [0:IN_LANES-1][0:OUT_CH-1];

    reg signed [ACC_W-1:0] acc_reg [0:OUT_CH-1];
    reg signed [ACC_W-1:0] sum_per_oc [0:OUT_CH-1];

    wire signed [PROD_W-1:0] prod [0:IN_LANES-1][0:OUT_CH-1];

    wire can_send_fwd;
    wire can_send_out;
    wire retire_fire;
    wire accept_fire;

    assign can_send_fwd = (~in_slice_fwd_valid) || in_slice_fwd_ready;
    assign can_send_out = (~out_valid) || out_ready;

    assign retire_fire = s0_valid &&
                         can_send_fwd &&
                         ((~s0_accum_en) || can_send_out);

    assign in_ready    = (~s0_valid) || retire_fire;
    assign accept_fire = in_valid && in_ready;

    genvar gi;
    genvar gj;
    generate
        for (gi = 0; gi < IN_LANES; gi = gi + 1) begin : G_MULT_I
            for (gj = 0; gj < OUT_CH; gj = gj + 1) begin : G_MULT_J
                lutein_radix4_lut_mult_4b u_mult (
                    .a(in_q[gi]),
                    .b(w_q[gi][gj]),
                    .p(prod[gi][gj])
                );
            end
        end
    endgenerate

    always @(*) begin
        for (j = 0; j < OUT_CH; j = j + 1) begin
            sum_per_oc[j] = '0;
            for (i = 0; i < IN_LANES; i = i + 1) begin
                sum_per_oc[j] = $signed(sum_per_oc[j]) + $signed(prod[i][j]);
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        reg zero_detect;
        reg signed [ACC_W-1:0] acc_base;
        reg signed [ACC_W-1:0] acc_next;

        if (!rst_n) begin
            s0_valid           <= 1'b0;
            s0_zero_q          <= 1'b0;
            s0_accum_en        <= 1'b0;
            s0_idx_q           <= '0;

            out_valid          <= 1'b0;
            out_psum_flat      <= '0;

            in_slice_fwd_valid <= 1'b0;
            in_slice_fwd_flat  <= '0;
            in_idx_fwd         <= '0;

            in_slice_q_flat    <= '0;

            for (i = 0; i < IN_LANES; i = i + 1) begin
                in_q[i] <= '0;
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    w_q[i][j] <= '0;
                end
            end

            for (j = 0; j < OUT_CH; j = j + 1) begin
                acc_reg[j] <= '0;
            end
        end else begin
            in_slice_fwd_valid <= (in_slice_fwd_valid && !in_slice_fwd_ready) || retire_fire;
            out_valid          <= (out_valid && !out_ready) || (retire_fire && s0_accum_en);

            if (clear_acc && !retire_fire) begin
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    acc_reg[j] <= '0;
                end
            end

            if (retire_fire) begin
                in_slice_fwd_flat <= in_slice_q_flat;
                in_idx_fwd        <= s0_idx_q;

                if (s0_accum_en) begin
                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        acc_base = clear_acc ? '0 : acc_reg[j];

                        if (s0_zero_q) begin
                            acc_next = acc_base;
                        end else begin
                            acc_next = $signed(acc_base) + $signed(sum_per_oc[j]);
                        end

                        acc_reg[j] <= acc_next;
                        out_psum_flat[j*PSUM_W +: PSUM_W] <= acc_next;
                    end
                end
            end

            if (accept_fire) begin
                zero_detect = 1'b1;

                in_slice_q_flat <= in_slice_flat;
                s0_accum_en     <= accum_en;
                s0_idx_q        <= in_idx;

                for (i = 0; i < IN_LANES; i = i + 1) begin
                    in_q[i] <= $signed(in_slice_flat[i*ACT_W +: ACT_W]);

                    if ($signed(in_slice_flat[i*ACT_W +: ACT_W]) != 0)
                        zero_detect = 1'b0;

                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        w_q[i][j] <= $signed(wgt_slice_flat[(i*OUT_CH + j)*WGT_W +: WGT_W]);
                    end
                end

                s0_zero_q <= zero_detect;
            end

            s0_valid <= (s0_valid && !retire_fire) || accept_fire;
        end
    end

endmodule


module lutein_hybrid_sparse_dense_core_4x4 #(
    parameter integer ROWS        = 4,
    parameter integer COLS        = 4,
    parameter integer INDEX_DEPTH = 16,
    parameter integer IN_LANES    = 4,
    parameter integer OUT_CH      = 8,
    parameter integer ACT_W       = 4,
    parameter integer WGT_W       = 4,
    parameter integer PROD_W      = 8,
    parameter integer ACC_W       = 24,
    parameter integer PSUM_W      = 24
) (
    input  wire clk,
    input  wire rst_n,

    input  wire sparse_mode_en,
    input  wire clear_acc,
    input  wire accum_en,

    input  wire [ROWS-1:0] left_valid,
    input  wire [ROWS*IN_LANES*ACT_W-1:0] left_data,

    input  wire [COLS*IN_LANES*OUT_CH*WGT_W-1:0] dense_weight,

    input  wire [COLS-1:0] sparse_w_load_en,
    input  wire [COLS*$clog2(INDEX_DEPTH)-1:0] sparse_w_load_idx,
    input  wire [COLS*IN_LANES*OUT_CH*WGT_W-1:0] sparse_w_load_data,

    input  wire [ROWS*COLS-1:0] tile_ready,

    output wire [ROWS*COLS-1:0]               out_valid,
    output wire [ROWS*COLS*OUT_CH*PSUM_W-1:0] out_psum,

    output wire [ROWS*$clog2(INDEX_DEPTH)-1:0] packed_row_idx,
    output wire [ROWS-1:0]                     packed_valid
);

    localparam integer IN_W  = IN_LANES * ACT_W;
    localparam integer W_W   = IN_LANES * OUT_CH * WGT_W;
    localparam integer O_W   = OUT_CH * PSUM_W;
    localparam integer IDX_W = $clog2(INDEX_DEPTH);

    integer r, c, i, src, dst;

    // ------------------------------------------------------------------------
    // Weight storage
    // ------------------------------------------------------------------------
    reg [W_W-1:0] dense_wbuf [0:COLS-1];
    reg [W_W-1:0] sparse_weight_bank [0:COLS-1][0:INDEX_DEPTH-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (c = 0; c < COLS; c = c + 1)
                dense_wbuf[c] <= '0;
        end else begin
            for (c = 0; c < COLS; c = c + 1)
                dense_wbuf[c] <= dense_weight[c*W_W +: W_W];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (c = 0; c < COLS; c = c + 1)
                for (i = 0; i < INDEX_DEPTH; i = i + 1)
                    sparse_weight_bank[c][i] <= '0;
        end else begin
            for (c = 0; c < COLS; c = c + 1) begin
                if (sparse_w_load_en[c]) begin
                    sparse_weight_bank[c][sparse_w_load_idx[c*IDX_W +: IDX_W]]
                        <= sparse_w_load_data[c*W_W +: W_W];
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Row compaction (combinational)
    // ------------------------------------------------------------------------
    reg [IN_W-1:0]  compact_slot_data  [0:ROWS-1];
    reg [IDX_W-1:0] compact_slot_idx   [0:ROWS-1];
    reg             compact_slot_valid [0:ROWS-1];
    reg row_has_nz;

    always @(*) begin
        for (r = 0; r < ROWS; r = r + 1) begin
            compact_slot_data[r]  = '0;
            compact_slot_idx[r]   = '0;
            compact_slot_valid[r] = 1'b0;
        end

        dst = 0;
        for (src = 0; src < ROWS; src = src + 1) begin
            row_has_nz = 1'b0;

            if (left_valid[src]) begin
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    if ($signed(left_data[src*IN_W + i*ACT_W +: ACT_W]) != 0)
                        row_has_nz = 1'b1;
                end
            end

            if (sparse_mode_en) begin
                if (left_valid[src] && row_has_nz && (dst < ROWS)) begin
                    compact_slot_data[dst]  = left_data[src*IN_W +: IN_W];
                    compact_slot_idx[dst]   = src[IDX_W-1:0];
                    compact_slot_valid[dst] = 1'b1;
                    dst = dst + 1;
                end
            end else begin
                compact_slot_data[src]  = left_data[src*IN_W +: IN_W];
                compact_slot_idx[src]   = src[IDX_W-1:0];
                compact_slot_valid[src] = left_valid[src];
            end
        end
    end

    // ------------------------------------------------------------------------
    // Left-edge buffers: slice + row index
    // ------------------------------------------------------------------------
    wire [IN_W-1:0]  ibuf_data_out  [0:ROWS-1];
    wire             ibuf_valid_out [0:ROWS-1];
    wire [IDX_W-1:0] idxbuf_data_out[0:ROWS-1];
    wire             idxbuf_valid_out[0:ROWS-1];

    genvar gr;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : G_LEFT_BUF
            lutein_dense_ibuf #(
                .DATA_W(IN_W)
            ) u_ibuf (
                .clk(clk),
                .rst_n(rst_n),
                .load_en(compact_slot_valid[gr]),
                .load_data(compact_slot_data[gr]),
                .ready_in(pe_in_ready[gr][0]),
                .data_out(ibuf_data_out[gr]),
                .valid_out(ibuf_valid_out[gr])
            );

            lutein_dense_idxbuf #(
                .DATA_W(IDX_W)
            ) u_idxbuf (
                .clk(clk),
                .rst_n(rst_n),
                .load_en(compact_slot_valid[gr]),
                .load_data(compact_slot_idx[gr]),
                .ready_in(pe_in_ready[gr][0]),
                .data_out(idxbuf_data_out[gr]),
                .valid_out(idxbuf_valid_out[gr])
            );

            assign packed_row_idx[gr*IDX_W +: IDX_W] = idxbuf_data_out[gr];
            assign packed_valid[gr] = idxbuf_valid_out[gr];
        end
    endgenerate

    // ------------------------------------------------------------------------
    // PE array interconnect
    // ------------------------------------------------------------------------
    wire [IN_W-1:0]  pe_in_slice   [0:ROWS-1][0:COLS-1];
    wire [IDX_W-1:0] pe_in_idx     [0:ROWS-1][0:COLS-1];
    wire             pe_in_valid   [0:ROWS-1][0:COLS-1];
    wire             pe_in_ready   [0:ROWS-1][0:COLS-1];

    wire [IN_W-1:0]  pe_fwd_slice  [0:ROWS-1][0:COLS-1];
    wire [IDX_W-1:0] pe_fwd_idx    [0:ROWS-1][0:COLS-1];
    wire             pe_fwd_valid  [0:ROWS-1][0:COLS-1];

    wire [W_W-1:0]   pe_weight     [0:ROWS-1][0:COLS-1];
    wire [O_W-1:0]   pe_psum       [0:ROWS-1][0:COLS-1];
    wire             pe_out_valid  [0:ROWS-1][0:COLS-1];

    genvar gc;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : G_ROW
            for (gc = 0; gc < COLS; gc = gc + 1) begin : G_COL
                if (gc == 0) begin : G_LEFT_EDGE
                    assign pe_in_slice[gr][gc] = ibuf_data_out[gr];
                    assign pe_in_idx[gr][gc]   = idxbuf_data_out[gr];
                    assign pe_in_valid[gr][gc] = ibuf_valid_out[gr] & idxbuf_valid_out[gr];
                end else begin : G_INTERIOR
                    assign pe_in_slice[gr][gc] = pe_fwd_slice[gr][gc-1];
                    assign pe_in_idx[gr][gc]   = pe_fwd_idx[gr][gc-1];
                    assign pe_in_valid[gr][gc] = pe_fwd_valid[gr][gc-1];
                end

                assign pe_weight[gr][gc] =
                    sparse_mode_en ? sparse_weight_bank[gc][pe_in_idx[gr][gc]]
                                   : dense_weight[gc*W_W +: W_W];

                if (gc == COLS-1) begin : G_LAST_COL
                    lutein_slice_tensor_pe_idx #(
                        .IN_LANES(IN_LANES),
                        .OUT_CH(OUT_CH),
                        .ACT_W(ACT_W),
                        .WGT_W(WGT_W),
                        .PROD_W(PROD_W),
                        .ACC_W(ACC_W),
                        .PSUM_W(PSUM_W),
                        .IDX_W(IDX_W)
                    ) u_pe (
                        .clk(clk),
                        .rst_n(rst_n),
                        .in_valid(pe_in_valid[gr][gc]),
                        .clear_acc(clear_acc),
                        .accum_en(accum_en),
                        .out_ready(tile_ready[gr*COLS + gc]),
                        .in_slice_fwd_ready(1'b1),
                        .in_slice_flat(pe_in_slice[gr][gc]),
                        .in_idx(pe_in_idx[gr][gc]),
                        .wgt_slice_flat(pe_weight[gr][gc]),
                        .in_ready(pe_in_ready[gr][gc]),
                        .out_valid(pe_out_valid[gr][gc]),
                        .out_psum_flat(pe_psum[gr][gc]),
                        .in_slice_fwd_flat(pe_fwd_slice[gr][gc]),
                        .in_idx_fwd(pe_fwd_idx[gr][gc]),
                        .in_slice_fwd_valid(pe_fwd_valid[gr][gc])
                    );
                end else begin : G_NON_LAST_COL
                    lutein_slice_tensor_pe_idx #(
                        .IN_LANES(IN_LANES),
                        .OUT_CH(OUT_CH),
                        .ACT_W(ACT_W),
                        .WGT_W(WGT_W),
                        .PROD_W(PROD_W),
                        .ACC_W(ACC_W),
                        .PSUM_W(PSUM_W),
                        .IDX_W(IDX_W)
                    ) u_pe (
                        .clk(clk),
                        .rst_n(rst_n),
                        .in_valid(pe_in_valid[gr][gc]),
                        .clear_acc(clear_acc),
                        .accum_en(accum_en),
                        .out_ready(tile_ready[gr*COLS + gc]),
                        .in_slice_fwd_ready(pe_in_ready[gr][gc+1]),
                        .in_slice_flat(pe_in_slice[gr][gc]),
                        .in_idx(pe_in_idx[gr][gc]),
                        .wgt_slice_flat(pe_weight[gr][gc]),
                        .in_ready(pe_in_ready[gr][gc]),
                        .out_valid(pe_out_valid[gr][gc]),
                        .out_psum_flat(pe_psum[gr][gc]),
                        .in_slice_fwd_flat(pe_fwd_slice[gr][gc]),
                        .in_idx_fwd(pe_fwd_idx[gr][gc]),
                        .in_slice_fwd_valid(pe_fwd_valid[gr][gc])
                    );
                end

                assign out_valid[gr*COLS + gc] = pe_out_valid[gr][gc];
                assign out_psum[(gr*COLS + gc)*O_W +: O_W] = pe_psum[gr][gc];
            end
        end
    endgenerate

endmodule