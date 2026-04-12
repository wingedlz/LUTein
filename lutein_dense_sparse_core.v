module lutein_rle_row #(
    parameter integer IN_LANES = 4,
    parameter integer ACT_W    = 4,
    parameter integer ROW_IDX_W = 4
) (
    input  wire                              in_valid,
    input  wire [ROW_IDX_W-1:0]              in_row_idx,
    input  wire signed [IN_LANES*ACT_W-1:0]  in_slice_flat,
    output reg                               nz_valid,
    output reg  [ROW_IDX_W-1:0]              nz_row_idx,
    output reg  signed [IN_LANES*ACT_W-1:0]  nz_slice_flat,
    output reg                               is_zero
);
    integer i;
    reg all_zero;
    always @(*) begin
        all_zero = 1'b1;
        for (i = 0; i < IN_LANES; i = i + 1) begin
            if ($signed(in_slice_flat[i*ACT_W +: ACT_W]) != 0)
                all_zero = 1'b0;
        end

        nz_valid     = in_valid && !all_zero;
        nz_row_idx   = in_row_idx;
        nz_slice_flat = in_slice_flat;
        is_zero      = all_zero;
    end
endmodule

module lutein_idxbuf #(
    parameter integer ROW_IDX_W = 4
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 push_en,
    input  wire [ROW_IDX_W-1:0] push_idx,
    output reg  [ROW_IDX_W-1:0] idx_out,
    output reg                  valid_out
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_out   <= '0;
            valid_out <= 1'b0;
        end else begin
            valid_out <= 1'b0;
            if (push_en) begin
                idx_out   <= push_idx;
                valid_out <= 1'b1;
            end
        end
    end
endmodule

module lutein_zs_frontend #(
    parameter integer ROWS      = 4,
    parameter integer IN_LANES  = 4,
    parameter integer ACT_W     = 4,
    parameter integer ROW_IDX_W = 4
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              sparse_mode_en,
    input  wire [ROWS-1:0]                   load_en_in,
    input  wire [ROWS*IN_LANES*ACT_W-1:0]    load_data_flat_in,
    output wire [ROWS-1:0]                   load_en_out,
    output wire [ROWS*IN_LANES*ACT_W-1:0]    load_data_flat_out,
    output wire [ROWS*ROW_IDX_W-1:0]         idx_flat_out,
    output wire [ROWS-1:0]                   idx_valid_out,
    output wire [ROWS-1:0]                   zero_row_out
);
    localparam integer IN_DATA_W = IN_LANES * ACT_W;

    genvar r;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : G_ZS_ROW
            wire rle_nz_valid;
            wire [ROW_IDX_W-1:0] rle_row_idx;
            wire signed [IN_DATA_W-1:0] rle_slice_flat;
            wire rle_is_zero;

            lutein_rle_row #(
                .IN_LANES(IN_LANES),
                .ACT_W(ACT_W),
                .ROW_IDX_W(ROW_IDX_W)
            ) u_rle_row (
                .in_valid(load_en_in[r]),
                .in_row_idx(r[ROW_IDX_W-1:0]),
                .in_slice_flat(load_data_flat_in[r*IN_DATA_W +: IN_DATA_W]),
                .nz_valid(rle_nz_valid),
                .nz_row_idx(rle_row_idx),
                .nz_slice_flat(rle_slice_flat),
                .is_zero(rle_is_zero)
            );

            lutein_idxbuf #(
                .ROW_IDX_W(ROW_IDX_W)
            ) u_idxbuf (
                .clk(clk),
                .rst_n(rst_n),
                .push_en(sparse_mode_en ? rle_nz_valid : load_en_in[r]),
                .push_idx(sparse_mode_en ? rle_row_idx : r[ROW_IDX_W-1:0]),
                .idx_out(idx_flat_out[r*ROW_IDX_W +: ROW_IDX_W]),
                .valid_out(idx_valid_out[r])
            );

            assign load_en_out[r] = sparse_mode_en ? rle_nz_valid : load_en_in[r];
            assign load_data_flat_out[r*IN_DATA_W +: IN_DATA_W] = sparse_mode_en ? rle_slice_flat : load_data_flat_in[r*IN_DATA_W +: IN_DATA_W];
            assign zero_row_out[r] = sparse_mode_en ? rle_is_zero : 1'b0;
        end
    endgenerate
endmodule

module lutein_sparse_weight_select #(
    parameter integer ROWS      = 4,
    parameter integer COLS      = 4,
    parameter integer ROW_IDX_W = 4,
    parameter integer WBUF_DATA_W = 128
) (
    input  wire                              sparse_mode_en,
    input  wire [ROWS*ROW_IDX_W-1:0]         idx_flat_in,
    input  wire [ROWS-1:0]                   idx_valid_in,
    input  wire [COLS*WBUF_DATA_W-1:0]       dense_wbuf_flat,
    output wire [COLS*WBUF_DATA_W-1:0]       selected_wbuf_flat
);
    // Current reduced model:
    // - Dense mode: direct column-wise broadcast.
    // - Sparse mode: still reuses the same column-wise weights, but this module
    //   is the insertion point where irregular weight fetch by index would be added.
    assign selected_wbuf_flat = dense_wbuf_flat;
endmodule

module lutein_dense_sparse_core_4x4 #(
    parameter integer ROWS      = 4,
    parameter integer COLS      = 4,
    parameter integer IN_LANES  = 4,
    parameter integer OUT_CH    = 8,
    parameter integer ACT_W     = 4,
    parameter integer WGT_W     = 4,
    parameter integer PROD_W    = 8,
    parameter integer ACC_W     = 24,
    parameter integer PSUM_W    = 24,
    parameter integer ROW_IDX_W = 4
) (
    input  wire clk,
    input  wire rst_n,
    input  wire sparse_mode_en,
    input  wire clear_acc,
    input  wire accum_en,
    input  wire [ROWS-1:0] left_load_en,
    input  wire [ROWS*IN_LANES*ACT_W-1:0] left_load_data_flat,
    input  wire [COLS-1:0] wbuf_load_en,
    input  wire [COLS*IN_LANES*OUT_CH*WGT_W-1:0] wbuf_load_data_flat,
    input  wire [ROWS*COLS-1:0] tile_ready,
    output wire [ROWS*COLS-1:0] tile_valid,
    output wire [ROWS*COLS*OUT_CH*PSUM_W-1:0] tile_psum_flat,
    output wire [ROWS*ROW_IDX_W-1:0] sparse_idx_flat,
    output wire [ROWS-1:0] sparse_idx_valid,
    output wire [ROWS-1:0] sparse_zero_row
);
    localparam integer IN_DATA_W   = IN_LANES * ACT_W;
    localparam integer WBUF_DATA_W = IN_LANES * OUT_CH * WGT_W;

    wire [ROWS-1:0]                front_load_en;
    wire [ROWS*IN_DATA_W-1:0]      front_load_data_flat;
    wire [COLS*WBUF_DATA_W-1:0]    selected_wbuf_flat;
    wire [ROWS*COLS-1:0]           pe_out_valid_flat;
    wire [ROWS*COLS*OUT_CH*PSUM_W-1:0] pe_out_psum_flat;

    lutein_zs_frontend #(
        .ROWS(ROWS),
        .IN_LANES(IN_LANES),
        .ACT_W(ACT_W),
        .ROW_IDX_W(ROW_IDX_W)
    ) u_zs_frontend (
        .clk(clk),
        .rst_n(rst_n),
        .sparse_mode_en(sparse_mode_en),
        .load_en_in(left_load_en),
        .load_data_flat_in(left_load_data_flat),
        .load_en_out(front_load_en),
        .load_data_flat_out(front_load_data_flat),
        .idx_flat_out(sparse_idx_flat),
        .idx_valid_out(sparse_idx_valid),
        .zero_row_out(sparse_zero_row)
    );

    lutein_sparse_weight_select #(
        .ROWS(ROWS),
        .COLS(COLS),
        .ROW_IDX_W(ROW_IDX_W),
        .WBUF_DATA_W(WBUF_DATA_W)
    ) u_sparse_weight_select (
        .sparse_mode_en(sparse_mode_en),
        .idx_flat_in(sparse_idx_flat),
        .idx_valid_in(sparse_idx_valid),
        .dense_wbuf_flat(wbuf_load_data_flat),
        .selected_wbuf_flat(selected_wbuf_flat)
    );

    lutein_dense_core_4x4 #(
        .ROWS(ROWS),
        .COLS(COLS),
        .IN_LANES(IN_LANES),
        .OUT_CH(OUT_CH),
        .ACT_W(ACT_W),
        .WGT_W(WGT_W),
        .PROD_W(PROD_W),
        .ACC_W(ACC_W),
        .PSUM_W(PSUM_W)
    ) u_dense_core (
        .clk(clk),
        .rst_n(rst_n),
        .clear_acc(clear_acc),
        .accum_en(accum_en),
        .left_load_en(front_load_en),
        .left_load_data_flat(front_load_data_flat),
        .wbuf_load_en(wbuf_load_en),
        .wbuf_load_data_flat(selected_wbuf_flat),
        .tile_ready(tile_ready),
        .pe_out_valid_flat(pe_out_valid_flat),
        .pe_out_psum_flat(pe_out_psum_flat),
        .tile_valid(tile_valid),
        .tile_psum_flat(tile_psum_flat)
    );
endmodule

module tb_lutein_dense_sparse_core_4x4;
    localparam integer ROWS       = 4;
    localparam integer COLS       = 4;
    localparam integer IN_LANES   = 4;
    localparam integer OUT_CH     = 8;
    localparam integer ACT_W      = 4;
    localparam integer WGT_W      = 4;
    localparam integer PSUM_W     = 24;
    localparam integer ROW_IDX_W  = 4;
    localparam integer IN_DATA_W  = IN_LANES * ACT_W;
    localparam integer WBUF_DATA_W = IN_LANES * OUT_CH * WGT_W;
    localparam integer PE_PSUM_W  = OUT_CH * PSUM_W;

    reg clk;
    reg rst_n;
    reg sparse_mode_en;
    reg clear_acc;
    reg accum_en;
    reg [ROWS-1:0] left_load_en;
    reg [ROWS*IN_DATA_W-1:0] left_load_data_flat;
    reg [COLS-1:0] wbuf_load_en;
    reg [COLS*WBUF_DATA_W-1:0] wbuf_load_data_flat;
    reg [ROWS*COLS-1:0] tile_ready;

    wire [ROWS*COLS-1:0] tile_valid;
    wire [ROWS*COLS*PE_PSUM_W-1:0] tile_psum_flat;
    wire [ROWS*ROW_IDX_W-1:0] sparse_idx_flat;
    wire [ROWS-1:0] sparse_idx_valid;
    wire [ROWS-1:0] sparse_zero_row;

    integer r, c, i, j;
    integer timeout;
    reg mismatch;
    reg signed [PSUM_W-1:0] dut_val;
    reg signed [ACT_W-1:0] in_vec [0:ROWS-1][0:IN_LANES-1];
    reg signed [WGT_W-1:0] w_mat  [0:COLS-1][0:IN_LANES-1][0:OUT_CH-1];
    reg signed [PSUM_W-1:0] expected [0:ROWS-1][0:COLS-1][0:OUT_CH-1];
    reg signed [PSUM_W-1:0] sum;

    reg [ROWS*COLS-1:0] expected_valid_mask;
    reg row_is_zero;

    lutein_dense_sparse_core_4x4 #(
        .ROWS(ROWS),
        .COLS(COLS),
        .IN_LANES(IN_LANES),
        .OUT_CH(OUT_CH),
        .ACT_W(ACT_W),
        .WGT_W(WGT_W),
        .PSUM_W(PSUM_W),
        .ROW_IDX_W(ROW_IDX_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .sparse_mode_en(sparse_mode_en),
        .clear_acc(clear_acc),
        .accum_en(accum_en),
        .left_load_en(left_load_en),
        .left_load_data_flat(left_load_data_flat),
        .wbuf_load_en(wbuf_load_en),
        .wbuf_load_data_flat(wbuf_load_data_flat),
        .tile_ready(tile_ready),
        .tile_valid(tile_valid),
        .tile_psum_flat(tile_psum_flat),
        .sparse_idx_flat(sparse_idx_flat),
        .sparse_idx_valid(sparse_idx_valid),
        .sparse_zero_row(sparse_zero_row)
    );

    always #5 clk = ~clk;

    task load_dense_weights;
        begin
            for (c = 0; c < COLS; c = c + 1) begin
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        wbuf_load_data_flat[(c*WBUF_DATA_W) + ((i*OUT_CH + j)*WGT_W) +: WGT_W] = w_mat[c][i][j];
                    end
                end
            end
            wbuf_load_en = {COLS{1'b1}};
            @(posedge clk);
            wbuf_load_en = '0;
        end
    endtask

    task inject_left_inputs;
        begin
            for (r = 0; r < ROWS; r = r + 1) begin
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    left_load_data_flat[(r*IN_DATA_W) + (i*ACT_W) +: ACT_W] = in_vec[r][i];
                end
            end
            left_load_en = {ROWS{1'b1}};
            @(posedge clk);
            left_load_en = '0;
        end
    endtask

    task compute_expected_dense_sparse;
        begin
            expected_valid_mask = '0;

            for (r = 0; r < ROWS; r = r + 1) begin
                row_is_zero = 1'b1;
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    if (in_vec[r][i] != 0)
                        row_is_zero = 1'b0;
                end

                for (c = 0; c < COLS; c = c + 1) begin
                    if (sparse_mode_en && row_is_zero)
                        expected_valid_mask[r*COLS + c] = 1'b0;
                    else
                        expected_valid_mask[r*COLS + c] = 1'b1;

                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        if (sparse_mode_en && row_is_zero) begin
                            expected[r][c][j] = 0;
                        end else begin
                            sum = '0;
                            for (i = 0; i < IN_LANES; i = i + 1) begin
                                sum = sum + (in_vec[r][i] * w_mat[c][i][j]);
                            end
                            expected[r][c][j] = sum;
                        end
                    end
                end
            end
        end
    endtask

    task wait_all_valid_and_check;
        begin
            timeout = 0;
            while (((tile_valid & expected_valid_mask) !== expected_valid_mask) && timeout < 80) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if ((tile_valid & expected_valid_mask) !== expected_valid_mask) begin
                $display("[FAIL] timeout waiting for expected tile_valid mask at time=%0t", $time);
                $finish;
            end
            #1;
            mismatch = 1'b0;
            if (expected_valid_mask[r*COLS + c]) begin
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    dut_val = tile_psum_flat[((r*COLS + c)*PE_PSUM_W) + (j*PSUM_W) +: PSUM_W];
                    if (dut_val !== expected[r][c][j]) begin
                        $display("[FAIL] sparse_mode=%0d row=%0d col=%0d ch=%0d expected=%0d got=%0d time=%0t",
                                sparse_mode_en, r, c, j, expected[r][c][j], dut_val, $time);
                        mismatch = 1'b1;
                    end
                end
            end
            if (!mismatch)
                $display("[PASS] dense_sparse core check sparse_mode=%0d time=%0t", sparse_mode_en, $time);
        end
    endtask

    task set_test_vectors;
        begin
            // row 0: non-zero
            in_vec[0][0] =  1; in_vec[0][1] =  2; in_vec[0][2] = -1; in_vec[0][3] =  0;
            // row 1: all-zero to exercise sparse skip
            in_vec[1][0] =  0; in_vec[1][1] =  0; in_vec[1][2] =  0; in_vec[1][3] =  0;
            // row 2: non-zero
            in_vec[2][0] = -2; in_vec[2][1] =  1; in_vec[2][2] =  3; in_vec[2][3] = -1;
            // row 3: non-zero
            in_vec[3][0] =  4; in_vec[3][1] = -3; in_vec[3][2] =  1; in_vec[3][3] =  2;

            for (c = 0; c < COLS; c = c + 1) begin
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        w_mat[c][i][j] = ((c + i + j) % 5) - 2;
                    end
                end
            end
        end
    endtask

    initial begin
        $dumpfile("dense_sparse_core_wave.vcd");
        $dumpvars(0, tb_lutein_dense_sparse_core_4x4);

        clk = 1'b0;
        rst_n = 1'b0;
        sparse_mode_en = 1'b0;
        clear_acc = 1'b0;
        accum_en = 1'b1;
        left_load_en = '0;
        left_load_data_flat = '0;
        wbuf_load_en = '0;
        wbuf_load_data_flat = '0;
        tile_ready = '0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        set_test_vectors();
        load_dense_weights();

        // Dense mode: zero row still injected, PE internal zero behavior is exercised.
        sparse_mode_en = 1'b0;
        compute_expected_dense_sparse();
        inject_left_inputs();
        wait_all_valid_and_check();
        tile_ready = {ROWS*COLS{1'b1}};
        repeat (4) @(posedge clk);

        clear_acc = 1'b1;
        @(posedge clk);
        clear_acc = 1'b0;
        tile_ready = '0;
        repeat (2) @(posedge clk);

        // Sparse mode: all-zero row is suppressed by front-end RLE/ZS.
        sparse_mode_en = 1'b1;
        compute_expected_dense_sparse();
        inject_left_inputs();
        wait_all_valid_and_check();
        tile_ready = {ROWS*COLS{1'b1}};
        repeat (4) @(posedge clk);

        $display("[DONE] dense_sparse core tb finished");
        $finish;
    end
endmodule
