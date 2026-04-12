`timescale 1ns/1ps

module lutein_sparse_rle_core_4x4 #(
    parameter integer ROWS        = 4,
    parameter integer COLS        = 4,
    parameter integer INDEX_DEPTH = 16,
    parameter integer IN_LANES    = 4,
    parameter integer OUT_CH      = 8,
    parameter integer ACT_W       = 4,
    parameter integer WGT_W       = 4,
    parameter integer PSUM_W      = 24
)(
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

    output wire [ROWS*COLS-1:0] out_valid,
    output wire [ROWS*COLS*OUT_CH*PSUM_W-1:0] out_psum,
    output wire [ROWS*$clog2(INDEX_DEPTH)-1:0] packed_row_idx,
    output wire [ROWS-1:0] packed_valid
);
    localparam integer IN_W  = IN_LANES * ACT_W;
    localparam integer W_W   = IN_LANES * OUT_CH * WGT_W;
    localparam integer O_W   = OUT_CH * PSUM_W;
    localparam integer IDX_W = $clog2(INDEX_DEPTH);

    integer r, c, i, src, dst;

    // -----------------------------------------
    // Dense weights per column
    // -----------------------------------------
    reg [W_W-1:0] dense_wbuf [0:COLS-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (c = 0; c < COLS; c = c + 1)
                dense_wbuf[c] <= '0;
        end else begin
            for (c = 0; c < COLS; c = c + 1)
                dense_wbuf[c] <= dense_weight[c*W_W +: W_W];
        end
    end

    // -----------------------------------------
    // Sparse indexed weight bank: [col][orig_row_idx]
    // -----------------------------------------
    reg [W_W-1:0] sparse_weight_bank [0:COLS-1][0:INDEX_DEPTH-1];

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

    // -----------------------------------------
    // Dense slots (preserve order)
    // -----------------------------------------
    reg [IN_W-1:0]  dense_slot_data  [0:ROWS-1];
    reg [IDX_W-1:0] dense_slot_idx   [0:ROWS-1];
    reg             dense_slot_valid [0:ROWS-1];

    // -----------------------------------------
    // Sparse RLE-compacted slots
    // -----------------------------------------
    reg [IN_W-1:0]  sparse_slot_data  [0:ROWS-1];
    reg [IDX_W-1:0] sparse_slot_idx   [0:ROWS-1];
    reg             sparse_slot_valid [0:ROWS-1];
    reg row_has_nz;

    always @(*) begin
        for (r = 0; r < ROWS; r = r + 1) begin
            dense_slot_data[r]  = left_data[r*IN_W +: IN_W];
            dense_slot_idx[r]   = r[IDX_W-1:0];
            dense_slot_valid[r] = left_valid[r];
        end

        for (r = 0; r < ROWS; r = r + 1) begin
            sparse_slot_data[r]  = '0;
            sparse_slot_idx[r]   = '0;
            sparse_slot_valid[r] = 1'b0;
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

            if (left_valid[src] && row_has_nz && (dst < ROWS)) begin
                sparse_slot_data[dst]  = left_data[src*IN_W +: IN_W];
                sparse_slot_idx[dst]   = src[IDX_W-1:0];
                sparse_slot_valid[dst] = 1'b1;
                dst = dst + 1;
            end
        end
    end

    // -----------------------------------------
    // Pipeline across columns
    // -----------------------------------------
    reg [IN_W-1:0]  pipe_data  [0:ROWS-1][0:COLS-1];
    reg [IDX_W-1:0] pipe_idx   [0:ROWS-1][0:COLS-1];
    reg             pipe_valid [0:ROWS-1][0:COLS-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    pipe_data[r][c]  <= '0;
                    pipe_idx[r][c]   <= '0;
                    pipe_valid[r][c] <= 1'b0;
                end
            end
        end else begin
            for (r = 0; r < ROWS; r = r + 1) begin
                if (sparse_mode_en) begin
                    pipe_data[r][0]  <= sparse_slot_data[r];
                    pipe_idx[r][0]   <= sparse_slot_idx[r];
                    pipe_valid[r][0] <= sparse_slot_valid[r];
                end else begin
                    pipe_data[r][0]  <= dense_slot_data[r];
                    pipe_idx[r][0]   <= dense_slot_idx[r];
                    pipe_valid[r][0] <= dense_slot_valid[r];
                end
            end

            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 1; c < COLS; c = c + 1) begin
                    pipe_data[r][c]  <= pipe_data[r][c-1];
                    pipe_idx[r][c]   <= pipe_idx[r][c-1];
                    pipe_valid[r][c] <= pipe_valid[r][c-1];
                end
            end
        end
    end

    genvar gp;
    generate
        for (gp = 0; gp < ROWS; gp = gp + 1) begin : G_META
            assign packed_row_idx[gp*IDX_W +: IDX_W] = pipe_idx[gp][0];
            assign packed_valid[gp] = pipe_valid[gp][0];
        end
    endgenerate

    // -----------------------------------------
    // PE array
    // -----------------------------------------
    wire [W_W-1:0] pe_weight [0:ROWS-1][0:COLS-1];
    wire [O_W-1:0] pe_psum   [0:ROWS-1][0:COLS-1];
    wire           pe_valid  [0:ROWS-1][0:COLS-1];

    genvar gr, gc;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : G_ROW
            for (gc = 0; gc < COLS; gc = gc + 1) begin : G_COL
                assign pe_weight[gr][gc] =
                    sparse_mode_en ? sparse_weight_bank[gc][pipe_idx[gr][gc]]
                                   : dense_wbuf[gc];

                lutein_slice_tensor_pe #(
                    .IN_LANES(IN_LANES),
                    .OUT_CH(OUT_CH),
                    .ACT_W(ACT_W),
                    .WGT_W(WGT_W),
                    .PSUM_W(PSUM_W)
                ) u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .in_valid(pipe_valid[gr][gc]),
                    .clear_acc(clear_acc),
                    .accum_en(accum_en),
                    .out_ready(1'b1),
                    .in_slice_flat(pipe_data[gr][gc]),
                    .wgt_slice_flat(pe_weight[gr][gc]),
                    .in_ready(),
                    .out_valid(pe_valid[gr][gc]),
                    .out_psum_flat(pe_psum[gr][gc]),
                    .in_slice_fwd_flat(),
                    .in_slice_fwd_valid(),
                    .in_slice_fwd_ready(1'b1)
                );

                assign out_valid[gr*COLS + gc] = pe_valid[gr][gc];
                assign out_psum[(gr*COLS + gc)*O_W +: O_W] = pe_psum[gr][gc];
            end
        end
    endgenerate

endmodule


module tb_lutein_sparse_rle_core_4x4;
    localparam integer ROWS        = 4;
    localparam integer COLS        = 4;
    localparam integer INDEX_DEPTH = 16;
    localparam integer IN_LANES    = 4;
    localparam integer OUT_CH      = 8;
    localparam integer ACT_W       = 4;
    localparam integer WGT_W       = 4;
    localparam integer PSUM_W      = 24;
    localparam integer IN_W        = IN_LANES * ACT_W;
    localparam integer W_W         = IN_LANES * OUT_CH * WGT_W;
    localparam integer O_W         = OUT_CH * PSUM_W;
    localparam integer IDX_W       = $clog2(INDEX_DEPTH);

    reg clk;
    reg rst_n;
    reg sparse_mode_en;
    reg clear_acc;
    reg accum_en;
    reg [ROWS-1:0] left_valid;
    reg [ROWS*IN_W-1:0] left_data;
    reg [COLS*W_W-1:0] dense_weight;
    reg [COLS-1:0] sparse_w_load_en;
    reg [COLS*IDX_W-1:0] sparse_w_load_idx;
    reg [COLS*W_W-1:0] sparse_w_load_data;

    wire [ROWS*COLS-1:0] out_valid;
    wire [ROWS*COLS*O_W-1:0] out_psum;
    wire [ROWS*IDX_W-1:0] packed_row_idx;
    wire [ROWS-1:0] packed_valid;

    integer r, c, i, j, idx;
    reg signed [ACT_W-1:0] in_vec [0:ROWS-1][0:IN_LANES-1];
    reg signed [WGT_W-1:0] dense_w [0:COLS-1][0:IN_LANES-1][0:OUT_CH-1];
    reg signed [WGT_W-1:0] sparse_w [0:COLS-1][0:INDEX_DEPTH-1][0:IN_LANES-1][0:OUT_CH-1];
    reg signed [PSUM_W-1:0] expected [0:ROWS-1][0:COLS-1][0:OUT_CH-1];
    reg signed [PSUM_W-1:0] sum;
    reg mismatch;
    integer packed_map [0:ROWS-1];
    integer dst;
    reg row_has_nz;
    reg [ROWS-1:0] expected_slot_valid;

    lutein_sparse_rle_core_4x4 #(
        .ROWS(ROWS),
        .COLS(COLS),
        .INDEX_DEPTH(INDEX_DEPTH),
        .IN_LANES(IN_LANES),
        .OUT_CH(OUT_CH),
        .ACT_W(ACT_W),
        .WGT_W(WGT_W),
        .PSUM_W(PSUM_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .sparse_mode_en(sparse_mode_en),
        .clear_acc(clear_acc),
        .accum_en(accum_en),
        .left_valid(left_valid),
        .left_data(left_data),
        .dense_weight(dense_weight),
        .sparse_w_load_en(sparse_w_load_en),
        .sparse_w_load_idx(sparse_w_load_idx),
        .sparse_w_load_data(sparse_w_load_data),
        .out_valid(out_valid),
        .out_psum(out_psum),
        .packed_row_idx(packed_row_idx),
        .packed_valid(packed_valid)
    );

    always #5 clk = ~clk;

    task load_dense_weights;
        begin
            for (c = 0; c < COLS; c = c + 1) begin
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        dense_weight[c*W_W + (i*OUT_CH + j)*WGT_W +: WGT_W] = dense_w[c][i][j];
                    end
                end
            end
            @(posedge clk);
        end
    endtask

    task load_sparse_weights_all;
        begin
            for (idx = 0; idx < INDEX_DEPTH; idx = idx + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    sparse_w_load_en[c] = 1'b1;
                    sparse_w_load_idx[c*IDX_W +: IDX_W] = idx[IDX_W-1:0];
                    for (i = 0; i < IN_LANES; i = i + 1) begin
                        for (j = 0; j < OUT_CH; j = j + 1) begin
                            sparse_w_load_data[c*W_W + (i*OUT_CH + j)*WGT_W +: WGT_W] =
                                sparse_w[c][idx][i][j];
                        end
                    end
                end
                @(posedge clk);
                sparse_w_load_en = '0;
            end
        end
    endtask

    task inject_inputs_once;
        begin
            for (r = 0; r < ROWS; r = r + 1) begin
                left_valid[r] = 1'b1;
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    left_data[r*IN_W + i*ACT_W +: ACT_W] = in_vec[r][i];
                end
            end
            @(posedge clk);
            left_valid = '0;
        end
    endtask

    task build_sparse_packed_map;
        begin
            for (r = 0; r < ROWS; r = r + 1)
                packed_map[r] = -1;

            dst = 0;
            for (r = 0; r < ROWS; r = r + 1) begin
                row_has_nz = 1'b0;
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    if (in_vec[r][i] != 0)
                        row_has_nz = 1'b1;
                end
                if (row_has_nz && (dst < ROWS)) begin
                    packed_map[dst] = r;
                    dst = dst + 1;
                end
            end
        end
    endtask

    task compute_expected_dense;
        begin
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        sum = '0;
                        for (i = 0; i < IN_LANES; i = i + 1)
                            sum = sum + (in_vec[r][i] * dense_w[c][i][j]);
                        expected[r][c][j] = sum;
                    end
                end
            end
        end
    endtask

    task compute_expected_sparse;
        integer orig_r;
        begin
            build_sparse_packed_map();

            for (r = 0; r < ROWS; r = r + 1) begin
                if (packed_map[r] >= 0)
                    expected_slot_valid[r] = 1'b1;
                else
                    expected_slot_valid[r] = 1'b0;

                orig_r = packed_map[r];

                for (c = 0; c < COLS; c = c + 1) begin
                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        if (orig_r < 0) begin
                            expected[r][c][j] = 0;
                        end else begin
                            sum = '0;
                            for (i = 0; i < IN_LANES; i = i + 1)
                                sum = sum + (in_vec[orig_r][i] * sparse_w[c][orig_r][i][j]);
                            expected[r][c][j] = sum;
                        end
                    end
                end
            end
        end
    endtask
    task check_outputs;
        integer rr, cc, jj;
        reg signed [PSUM_W-1:0] dut_val;
        begin
            mismatch = 1'b0;

            for (rr = 0; rr < ROWS; rr = rr + 1) begin
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    // Dense mode: always check all rows
                    // Sparse mode: only check packed valid rows
                    if ((!sparse_mode_en) || expected_slot_valid[rr]) begin
                        for (jj = 0; jj < OUT_CH; jj = jj + 1) begin
                            dut_val = out_psum[(rr*COLS + cc)*O_W + jj*PSUM_W +: PSUM_W];
                            if (dut_val !== expected[rr][cc][jj]) begin
                                $display("[FAIL] mode=%0d row=%0d col=%0d ch=%0d expected=%0d got=%0d time=%0t",
                                        sparse_mode_en, rr, cc, jj, expected[rr][cc][jj], dut_val, $time);
                                mismatch = 1'b1;
                            end
                        end
                    end
                end
            end

            if (!mismatch)
                $display("[PASS] mode=%0d time=%0t", sparse_mode_en, $time);
        end
    endtask

    initial begin
        $dumpfile("sparse_rle_core_wave.vcd");
        $dumpvars(0, tb_lutein_sparse_rle_core_4x4);

        clk = 1'b0;
        rst_n = 1'b0;
        sparse_mode_en = 1'b0;
        clear_acc = 1'b0;
        accum_en = 1'b1;
        left_valid = '0;
        left_data = '0;
        dense_weight = '0;
        sparse_w_load_en = '0;
        sparse_w_load_idx = '0;
        sparse_w_load_data = '0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        for (c = 0; c < COLS; c = c + 1) begin
            for (i = 0; i < IN_LANES; i = i + 1) begin
                for (j = 0; j < OUT_CH; j = j + 1)
                    dense_w[c][i][j] = ((c + i + j) % 5) - 2;
            end
        end

        for (c = 0; c < COLS; c = c + 1) begin
            for (idx = 0; idx < INDEX_DEPTH; idx = idx + 1) begin
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    for (j = 0; j < OUT_CH; j = j + 1)
                        sparse_w[c][idx][i][j] = ((c + idx + i + j) % 7) - 3;
                end
            end
        end

        in_vec[0][0] =  1; in_vec[0][1] =  2; in_vec[0][2] = -1; in_vec[0][3] =  0;
        in_vec[1][0] =  0; in_vec[1][1] =  0; in_vec[1][2] =  0; in_vec[1][3] =  0;
        in_vec[2][0] = -2; in_vec[2][1] =  1; in_vec[2][2] =  3; in_vec[2][3] = -1;
        in_vec[3][0] =  4; in_vec[3][1] = -3; in_vec[3][2] =  1; in_vec[3][3] =  2;

        load_dense_weights();
        load_sparse_weights_all();

        // Dense mode
        sparse_mode_en = 1'b0;
        clear_acc = 1'b1;
        @(posedge clk);
        clear_acc = 1'b0;

        compute_expected_dense();
        inject_inputs_once();
        repeat (8) @(posedge clk);
        check_outputs();

        // Sparse mode with real compaction
        sparse_mode_en = 1'b1;
        clear_acc = 1'b1;
        @(posedge clk);
        clear_acc = 1'b0;

        compute_expected_sparse();
        inject_inputs_once();
        repeat (8) @(posedge clk);
        check_outputs();

        $display("[DONE] sparse rle core tb finished");
        $finish;
    end
endmodule