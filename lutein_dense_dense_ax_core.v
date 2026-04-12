`timescale 1ns/1ps

module lutein_rle_pack_rows #(
    parameter integer SLOTS  = 4,
    parameter integer DATA_W = 16,
    parameter integer IDX_W  = 4
)(
    input  wire [SLOTS-1:0]              in_valid,
    input  wire [SLOTS*DATA_W-1:0]       in_data_flat,
    output reg  [SLOTS-1:0]              out_valid,
    output reg  [SLOTS*DATA_W-1:0]       out_data_flat,
    output reg  [SLOTS*IDX_W-1:0]        out_idx_flat
);
    integer src, dst;
    integer k;
    reg all_zero;

    always @(*) begin
        out_valid     = '0;
        out_data_flat = '0;
        out_idx_flat  = '0;

        dst = 0;
        for (src = 0; src < SLOTS; src = src + 1) begin
            all_zero = 1'b1;
            for (k = 0; k < DATA_W; k = k + 1) begin
                if (in_data_flat[src*DATA_W + k] != 1'b0)
                    all_zero = 1'b0;
            end

            if (in_valid[src] && !all_zero && (dst < SLOTS)) begin
                out_valid[dst] = 1'b1;
                out_data_flat[dst*DATA_W +: DATA_W] = in_data_flat[src*DATA_W +: DATA_W];
                out_idx_flat[dst*IDX_W +: IDX_W] = src[IDX_W-1:0];
                dst = dst + 1;
            end
        end
    end
endmodule


module lutein_rle_pack_cols #(
    parameter integer SLOTS  = 4,
    parameter integer DATA_W = 128,
    parameter integer IDX_W  = 4
)(
    input  wire [SLOTS-1:0]              in_valid,
    input  wire [SLOTS*DATA_W-1:0]       in_data_flat,
    output reg  [SLOTS-1:0]              out_valid,
    output reg  [SLOTS*DATA_W-1:0]       out_data_flat,
    output reg  [SLOTS*IDX_W-1:0]        out_idx_flat
);
    integer src, dst;
    integer k;
    reg all_zero;

    always @(*) begin
        out_valid     = '0;
        out_data_flat = '0;
        out_idx_flat  = '0;

        dst = 0;
        for (src = 0; src < SLOTS; src = src + 1) begin
            all_zero = 1'b1;
            for (k = 0; k < DATA_W; k = k + 1) begin
                if (in_data_flat[src*DATA_W + k] != 1'b0)
                    all_zero = 1'b0;
            end

            if (in_valid[src] && !all_zero && (dst < SLOTS)) begin
                out_valid[dst] = 1'b1;
                out_data_flat[dst*DATA_W +: DATA_W] = in_data_flat[src*DATA_W +: DATA_W];
                out_idx_flat[dst*IDX_W +: IDX_W] = src[IDX_W-1:0];
                dst = dst + 1;
            end
        end
    end
endmodule


module lutein_birle_ax_core_4x4 #(
    parameter integer ROWS     = 4,
    parameter integer COLS     = 4,
    parameter integer IN_LANES = 4,
    parameter integer OUT_CH   = 8,
    parameter integer ACT_W    = 4,
    parameter integer WGT_W    = 4,
    parameter integer PSUM_W   = 24
)(
    input  wire clk,
    input  wire rst_n,
    input  wire sparse_mode_en,
    input  wire clear_acc,
    input  wire accum_en,

    // A-side: left injection candidates (one slice per row)
    input  wire [ROWS-1:0]                         a_left_valid,
    input  wire [ROWS*IN_LANES*ACT_W-1:0]          a_left_data_flat,

    // X-side: top injection candidates (one weight-slice per column)
    input  wire [COLS-1:0]                         x_top_valid,
    input  wire [COLS*IN_LANES*OUT_CH*WGT_W-1:0]   x_top_data_flat,

    output wire [ROWS*COLS-1:0]                    pe_out_valid_flat,
    output wire [ROWS*COLS*OUT_CH*PSUM_W-1:0]      pe_out_psum_flat,

    output wire [ROWS*$clog2(ROWS)-1:0]            packed_a_idx_flat,
    output wire [ROWS-1:0]                         packed_a_valid,
    output wire [COLS*$clog2(COLS)-1:0]            packed_x_idx_flat,
    output wire [COLS-1:0]                         packed_x_valid
);
    localparam integer A_W   = IN_LANES * ACT_W;
    localparam integer X_W   = IN_LANES * OUT_CH * WGT_W;
    localparam integer O_W   = OUT_CH * PSUM_W;
    localparam integer AIDX_W = $clog2(ROWS);
    localparam integer XIDX_W = $clog2(COLS);

    integer r, c;

    // -----------------------------------------
    // Bilateral RLE packing
    // -----------------------------------------
    wire [ROWS-1:0]           a_packed_valid;
    wire [ROWS*A_W-1:0]       a_packed_data_flat;
    wire [ROWS*AIDX_W-1:0]    a_packed_idx_flat;

    wire [COLS-1:0]           x_packed_valid;
    wire [COLS*X_W-1:0]       x_packed_data_flat;
    wire [COLS*XIDX_W-1:0]    x_packed_idx_flat;

    lutein_rle_pack_rows #(
        .SLOTS(ROWS),
        .DATA_W(A_W),
        .IDX_W(AIDX_W)
    ) u_pack_a (
        .in_valid(sparse_mode_en ? a_left_valid : a_left_valid),
        .in_data_flat(a_left_data_flat),
        .out_valid(a_packed_valid),
        .out_data_flat(a_packed_data_flat),
        .out_idx_flat(a_packed_idx_flat)
    );

    lutein_rle_pack_cols #(
        .SLOTS(COLS),
        .DATA_W(X_W),
        .IDX_W(XIDX_W)
    ) u_pack_x (
        .in_valid(sparse_mode_en ? x_top_valid : x_top_valid),
        .in_data_flat(x_top_data_flat),
        .out_valid(x_packed_valid),
        .out_data_flat(x_packed_data_flat),
        .out_idx_flat(x_packed_idx_flat)
    );

    assign packed_a_valid   = sparse_mode_en ? a_packed_valid : a_left_valid;
    assign packed_a_idx_flat = sparse_mode_en ? a_packed_idx_flat : '0;
    assign packed_x_valid   = sparse_mode_en ? x_packed_valid : x_top_valid;
    assign packed_x_idx_flat = sparse_mode_en ? x_packed_idx_flat : '0;

    // -----------------------------------------
    // Horizontal A pipeline
    // -----------------------------------------
    reg [A_W-1:0]  a_pipe_data  [0:ROWS-1][0:COLS-1];
    reg            a_pipe_valid [0:ROWS-1][0:COLS-1];

    // -----------------------------------------
    // Vertical X pipeline
    // -----------------------------------------
    reg [X_W-1:0]  x_pipe_data  [0:ROWS-1][0:COLS-1];
    reg            x_pipe_valid [0:ROWS-1][0:COLS-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    a_pipe_data[r][c]  <= '0;
                    a_pipe_valid[r][c] <= 1'b0;
                    x_pipe_data[r][c]  <= '0;
                    x_pipe_valid[r][c] <= 1'b0;
                end
            end
        end else begin
            // Inject packed A on left edge
            for (r = 0; r < ROWS; r = r + 1) begin
                if (sparse_mode_en) begin
                    a_pipe_data[r][0]  <= a_packed_data_flat[r*A_W +: A_W];
                    a_pipe_valid[r][0] <= a_packed_valid[r];
                end else begin
                    a_pipe_data[r][0]  <= a_left_data_flat[r*A_W +: A_W];
                    a_pipe_valid[r][0] <= a_left_valid[r];
                end
            end

            // Shift A to the right
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 1; c < COLS; c = c + 1) begin
                    a_pipe_data[r][c]  <= a_pipe_data[r][c-1];
                    a_pipe_valid[r][c] <= a_pipe_valid[r][c-1];
                end
            end

            // Inject packed X on top edge
            for (c = 0; c < COLS; c = c + 1) begin
                if (sparse_mode_en) begin
                    x_pipe_data[0][c]  <= x_packed_data_flat[c*X_W +: X_W];
                    x_pipe_valid[0][c] <= x_packed_valid[c];
                end else begin
                    x_pipe_data[0][c]  <= x_top_data_flat[c*X_W +: X_W];
                    x_pipe_valid[0][c] <= x_top_valid[c];
                end
            end

            // Shift X downward
            for (r = 1; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    x_pipe_data[r][c]  <= x_pipe_data[r-1][c];
                    x_pipe_valid[r][c] <= x_pipe_valid[r-1][c];
                end
            end
        end
    end

    // -----------------------------------------
    // PE array: existing lutein_slice_tensor_pe reused
    // A = in_slice_flat
    // X = wgt_slice_flat
    // -----------------------------------------
    genvar gr, gc;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : G_ROW
            for (gc = 0; gc < COLS; gc = gc + 1) begin : G_COL
                lutein_slice_tensor_pe #(
                    .IN_LANES(IN_LANES),
                    .OUT_CH(OUT_CH),
                    .ACT_W(ACT_W),
                    .WGT_W(WGT_W),
                    .PSUM_W(PSUM_W)
                ) u_pe (
                    .clk(clk),
                    .rst_n(rst_n),
                    .in_valid(a_pipe_valid[gr][gc] & x_pipe_valid[gr][gc]),
                    .clear_acc(clear_acc),
                    .accum_en(accum_en),
                    .out_ready(1'b1),
                    .in_slice_flat(a_pipe_data[gr][gc]),
                    .wgt_slice_flat(x_pipe_data[gr][gc]),
                    .in_ready(),
                    .out_valid(pe_out_valid_flat[gr*COLS + gc]),
                    .out_psum_flat(pe_out_psum_flat[(gr*COLS + gc)*O_W +: O_W]),
                    .in_slice_fwd_flat(),
                    .in_slice_fwd_valid(),
                    .in_slice_fwd_ready(1'b1)
                );
            end
        end
    endgenerate

endmodule


module tb_lutein_birle_ax_core_4x4;
    localparam integer ROWS     = 4;
    localparam integer COLS     = 4;
    localparam integer IN_LANES = 4;
    localparam integer OUT_CH   = 8;
    localparam integer ACT_W    = 4;
    localparam integer WGT_W    = 4;
    localparam integer PSUM_W   = 24;

    localparam integer A_W    = IN_LANES * ACT_W;
    localparam integer X_W    = IN_LANES * OUT_CH * WGT_W;
    localparam integer O_W    = OUT_CH * PSUM_W;
    localparam integer AIDX_W = $clog2(ROWS);
    localparam integer XIDX_W = $clog2(COLS);

    reg clk;
    reg rst_n;
    reg sparse_mode_en;
    reg clear_acc;
    reg accum_en;

    reg [ROWS-1:0]               a_left_valid;
    reg [ROWS*A_W-1:0]           a_left_data_flat;
    reg [COLS-1:0]               x_top_valid;
    reg [COLS*X_W-1:0]           x_top_data_flat;

    wire [ROWS*COLS-1:0]         pe_out_valid_flat;
    wire [ROWS*COLS*O_W-1:0]     pe_out_psum_flat;
    wire [ROWS*AIDX_W-1:0]       packed_a_idx_flat;
    wire [ROWS-1:0]              packed_a_valid;
    wire [COLS*XIDX_W-1:0]       packed_x_idx_flat;
    wire [COLS-1:0]              packed_x_valid;

    reg [ROWS*COLS-1:0] expected_cell_valid;

    integer r, c, i, j;
    integer pa, px;
    integer packed_a_map [0:ROWS-1];
    integer packed_x_map [0:COLS-1];
    integer next_slot;
    reg any_nz;
    reg signed [ACT_W-1:0] A_in [0:ROWS-1][0:IN_LANES-1];
    reg signed [WGT_W-1:0] X_in [0:COLS-1][0:IN_LANES-1][0:OUT_CH-1];
    reg signed [PSUM_W-1:0] expected [0:ROWS-1][0:COLS-1][0:OUT_CH-1];
    reg signed [PSUM_W-1:0] sum;
    reg mismatch;
    reg signed [PSUM_W-1:0] dut_val;

    integer packed_a_count;
    integer packed_x_count;
    

    lutein_birle_ax_core_4x4 #(
        .ROWS(ROWS),
        .COLS(COLS),
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
        .a_left_valid(a_left_valid),
        .a_left_data_flat(a_left_data_flat),
        .x_top_valid(x_top_valid),
        .x_top_data_flat(x_top_data_flat),
        .pe_out_valid_flat(pe_out_valid_flat),
        .pe_out_psum_flat(pe_out_psum_flat),
        .packed_a_idx_flat(packed_a_idx_flat),
        .packed_a_valid(packed_a_valid),
        .packed_x_idx_flat(packed_x_idx_flat),
        .packed_x_valid(packed_x_valid)
    );

    always #5 clk = ~clk;

    task drive_inputs_wavefront;
        integer t;
        integer orig_r, orig_c;
        begin
            a_left_valid     = '0;
            a_left_data_flat = '0;
            x_top_valid      = '0;
            x_top_data_flat  = '0;

            if (sparse_mode_en)
                build_packed_maps();

            for (t = 0; t < ROWS + COLS - 1; t = t + 1) begin
                a_left_valid     = '0;
                a_left_data_flat = '0;
                x_top_valid      = '0;
                x_top_data_flat  = '0;

                // A side: inject slot/row r at time t=r
                for (r = 0; r < ROWS; r = r + 1) begin
                    if (t == r) begin
                        if (sparse_mode_en)
                            orig_r = packed_a_map[r];
                        else
                            orig_r = r;

                        if (orig_r >= 0) begin
                            a_left_valid[r] = 1'b1;
                            for (i = 0; i < IN_LANES; i = i + 1)
                                a_left_data_flat[r*A_W + i*ACT_W +: ACT_W] = A_in[orig_r][i];
                        end
                    end
                end

                // X side: inject slot/col c at time t=c
                for (c = 0; c < COLS; c = c + 1) begin
                    if (t == c) begin
                        if (sparse_mode_en)
                            orig_c = packed_x_map[c];
                        else
                            orig_c = c;

                        if (orig_c >= 0) begin
                            x_top_valid[c] = 1'b1;
                            for (i = 0; i < IN_LANES; i = i + 1) begin
                                for (j = 0; j < OUT_CH; j = j + 1) begin
                                    x_top_data_flat[c*X_W + (i*OUT_CH + j)*WGT_W +: WGT_W] = X_in[orig_c][i][j];
                                end
                            end
                        end
                    end
                end

                @(posedge clk);
            end

            a_left_valid     = '0;
            a_left_data_flat = '0;
            x_top_valid      = '0;
            x_top_data_flat  = '0;
        end
    endtask

    task build_packed_maps;
        begin
            for (pa = 0; pa < ROWS; pa = pa + 1)
                packed_a_map[pa] = -1;
            for (px = 0; px < COLS; px = px + 1)
                packed_x_map[px] = -1;

            packed_a_count = 0;
            for (r = 0; r < ROWS; r = r + 1) begin
                any_nz = 1'b0;
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    if (A_in[r][i] != 0)
                        any_nz = 1'b1;
                end
                if (any_nz && packed_a_count < ROWS) begin
                    packed_a_map[packed_a_count] = r;
                    packed_a_count = packed_a_count + 1;
                end
            end

            packed_x_count = 0;
            for (c = 0; c < COLS; c = c + 1) begin
                any_nz = 1'b0;
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        if (X_in[c][i][j] != 0)
                            any_nz = 1'b1;
                    end
                end
                if (any_nz && packed_x_count < COLS) begin
                    packed_x_map[packed_x_count] = c;
                    packed_x_count = packed_x_count + 1;
                end
            end
        end
    endtask

    task compute_expected_dense;
        begin
            expected_cell_valid = '0;
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    expected_cell_valid[r*COLS + c] = 1'b1;
                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        sum = '0;
                        for (i = 0; i < IN_LANES; i = i + 1)
                            sum = sum + (A_in[r][i] * X_in[c][i][j]);
                        expected[r][c][j] = sum;
                    end
                end
            end
        end
    endtask

    task compute_expected_sparse;
        integer orig_r, orig_c;
        begin
            build_packed_maps();
            expected_cell_valid = '0;

            for (r = 0; r < ROWS; r = r + 1) begin
                orig_r = packed_a_map[r];
                for (c = 0; c < COLS; c = c + 1) begin
                    orig_c = packed_x_map[c];

                    if (orig_r >= 0 && orig_c >= 0)
                        expected_cell_valid[r*COLS + c] = 1'b1;
                    else
                        expected_cell_valid[r*COLS + c] = 1'b0;

                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        if (orig_r < 0 || orig_c < 0) begin
                            expected[r][c][j] = 0;
                        end else begin
                            sum = '0;
                            for (i = 0; i < IN_LANES; i = i + 1)
                                sum = sum + (A_in[orig_r][i] * X_in[orig_c][i][j]);
                            expected[r][c][j] = sum;
                        end
                    end
                end
            end
        end
    endtask

    task check_outputs;
        integer rr, cc, jj;
        begin
            mismatch = 1'b0;
            for (rr = 0; rr < ROWS; rr = rr + 1) begin
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    if (expected_cell_valid[rr*COLS + cc]) begin
                        for (jj = 0; jj < OUT_CH; jj = jj + 1) begin
                            dut_val = pe_out_psum_flat[(rr*COLS + cc)*O_W + jj*PSUM_W +: PSUM_W];
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

    task reset_dut;
        begin
            rst_n = 1'b0;
            a_left_valid = '0;
            a_left_data_flat = '0;
            x_top_valid = '0;
            x_top_data_flat = '0;
            clear_acc = 1'b0;
            accum_en = 1'b1;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("birle_ax_core_wave.vcd");
        $dumpvars(0, tb_lutein_birle_ax_core_4x4);

        clk = 1'b0;
        rst_n = 1'b0;
        sparse_mode_en = 1'b0;
        clear_acc = 1'b0;
        accum_en = 1'b1;
        a_left_valid = '0;
        a_left_data_flat = '0;
        x_top_valid = '0;
        x_top_data_flat = '0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // A side candidates
        A_in[0][0] =  1; A_in[0][1] =  2; A_in[0][2] = -1; A_in[0][3] =  0;
        A_in[1][0] =  0; A_in[1][1] =  0; A_in[1][2] =  0; A_in[1][3] =  0; // zero row
        A_in[2][0] = -2; A_in[2][1] =  1; A_in[2][2] =  3; A_in[2][3] = -1;
        A_in[3][0] =  4; A_in[3][1] = -3; A_in[3][2] =  1; A_in[3][3] =  2;

        // X side candidates (each is one weight slice)
        for (c = 0; c < COLS; c = c + 1) begin
            for (i = 0; i < IN_LANES; i = i + 1) begin
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    X_in[c][i][j] = ((c + i + j) % 5) - 2;
                end
            end
        end
        // make one X column all-zero for sparse packing demo
        for (i = 0; i < IN_LANES; i = i + 1)
            for (j = 0; j < OUT_CH; j = j + 1)
                X_in[1][i][j] = 0;

        // Dense mode
        sparse_mode_en = 1'b0;
        clear_acc = 1'b1;
        @(posedge clk);
        clear_acc = 1'b0;

        compute_expected_dense();
        drive_inputs_wavefront();
        repeat (8) @(posedge clk);
        check_outputs();

        // Dense mode
        sparse_mode_en = 1'b0;
        reset_dut();
        compute_expected_dense();
        drive_inputs_wavefront();
        repeat (8) @(posedge clk);
        check_outputs();

        // Sparse mode
        sparse_mode_en = 1'b1;
        reset_dut();
        compute_expected_sparse();
        drive_inputs_wavefront();
        repeat (8) @(posedge clk);
        check_outputs();

        // Sparse mode: bilateral RLE packing
        sparse_mode_en = 1'b1;
        clear_acc = 1'b1;
        @(posedge clk);
        clear_acc = 1'b0;

        compute_expected_sparse();
        drive_inputs_wavefront();
        repeat (8) @(posedge clk);
        check_outputs();

        $display("[DONE] birle AX core tb finished");
        $finish;
    end

endmodule