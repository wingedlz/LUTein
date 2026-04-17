`timescale 1ns/1ps

module tb_lutein_hybrid_sparse_core;

    localparam integer ROWS        = 4;
    localparam integer COLS        = 4;
    localparam integer INDEX_DEPTH = 16;
    localparam integer IN_LANES    = 4;
    localparam integer OUT_CH      = 8;
    localparam integer ACT_W       = 4;
    localparam integer WGT_W       = 4;
    localparam integer PROD_W      = 8;
    localparam integer ACC_W       = 24;
    localparam integer PSUM_W      = 24;

    localparam integer IN_W  = IN_LANES * ACT_W;
    localparam integer W_W   = IN_LANES * OUT_CH * WGT_W;
    localparam integer O_W   = OUT_CH * PSUM_W;
    localparam integer IDX_W = $clog2(INDEX_DEPTH);

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

    reg [ROWS*COLS-1:0] tile_ready;

    wire [ROWS*COLS-1:0] out_valid;
    wire [ROWS*COLS*O_W-1:0] out_psum;

    wire [ROWS*IDX_W-1:0] packed_row_idx;
    wire [ROWS-1:0]       packed_valid;

    integer r, c, i, j, idx;
    integer total_checks;
    integer pass_checks;
    integer fail_checks;

    reg signed [ACT_W-1:0] in_vec [0:ROWS-1][0:IN_LANES-1];
    reg signed [WGT_W-1:0] dense_w [0:COLS-1][0:IN_LANES-1][0:OUT_CH-1];
    reg signed [WGT_W-1:0] sparse_w [0:COLS-1][0:INDEX_DEPTH-1][0:IN_LANES-1][0:OUT_CH-1];

    reg signed [PSUM_W-1:0] expected [0:ROWS-1][0:COLS-1][0:OUT_CH-1];
    reg signed [PSUM_W-1:0] sum;
    reg mismatch;

    integer packed_map [0:ROWS-1];
    reg [ROWS-1:0] expected_slot_valid;
    reg [IDX_W-1:0] expected_slot_idx [0:ROWS-1];
    integer dst;
    reg row_has_nz;
    integer orig_r;

    reg signed [PSUM_W-1:0] dut_val;
    reg [IDX_W-1:0] dut_idx;

    lutein_hybrid_sparse_dense_core_4x4 #(
        .ROWS(ROWS),
        .COLS(COLS),
        .INDEX_DEPTH(INDEX_DEPTH),
        .IN_LANES(IN_LANES),
        .OUT_CH(OUT_CH),
        .ACT_W(ACT_W),
        .WGT_W(WGT_W),
        .PROD_W(PROD_W),
        .ACC_W(ACC_W),
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
        .tile_ready(tile_ready),
        .out_valid(out_valid),
        .out_psum(out_psum),
        .packed_row_idx(packed_row_idx),
        .packed_valid(packed_valid)
    );

    always #5 clk = ~clk;

    task clear_counters;
        begin
            total_checks = 0;
            pass_checks  = 0;
            fail_checks  = 0;
        end
    endtask

    task load_dense_weights;
        begin
            dense_weight = '0;
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

    task reset_and_reload_weights;
        begin
            rst_n              = 1'b0;
            clear_acc          = 1'b0;
            left_valid         = '0;
            left_data          = '0;
            sparse_w_load_en   = '0;
            sparse_w_load_idx  = '0;
            sparse_w_load_data = '0;
            tile_ready         = {ROWS*COLS{1'b1}};

            repeat (2) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);

            load_dense_weights();
            load_sparse_weights_all();
            @(posedge clk);
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
            for (r = 0; r < ROWS; r = r + 1) begin
                packed_map[r] = -1;
                expected_slot_valid[r] = 1'b0;
                expected_slot_idx[r] = '0;
            end

            dst = 0;
            for (r = 0; r < ROWS; r = r + 1) begin
                row_has_nz = 1'b0;
                if (left_valid[r]) begin
                    for (i = 0; i < IN_LANES; i = i + 1) begin
                        if (in_vec[r][i] != 0)
                            row_has_nz = 1'b1;
                    end
                end

                if (row_has_nz && (dst < ROWS)) begin
                    packed_map[dst] = r;
                    expected_slot_valid[dst] = 1'b1;
                    expected_slot_idx[dst] = r[IDX_W-1:0];
                    dst = dst + 1;
                end
            end
        end
    endtask

    task compute_expected_dense;
        begin
            for (r = 0; r < ROWS; r = r + 1) begin
                expected_slot_valid[r] = left_valid[r];
                expected_slot_idx[r]   = r[IDX_W-1:0];

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
        begin
            build_sparse_packed_map();

            for (r = 0; r < ROWS; r = r + 1) begin
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

    task check_packed_metadata;
        input [255:0] name;
        begin
            mismatch = 1'b0;

            for (r = 0; r < ROWS; r = r + 1) begin
                if (packed_valid[r] !== expected_slot_valid[r]) begin
                    $display("[FAIL] %0s packed_valid[%0d] expected=%0b got=%0b time=%0t",
                             name, r, expected_slot_valid[r], packed_valid[r], $time);
                    mismatch = 1'b1;
                end

                dut_idx = packed_row_idx[r*IDX_W +: IDX_W];
                if (expected_slot_valid[r] && (dut_idx !== expected_slot_idx[r])) begin
                    $display("[FAIL] %0s packed_row_idx[%0d] expected=%0d got=%0d time=%0t",
                             name, r, expected_slot_idx[r], dut_idx, $time);
                    mismatch = 1'b1;
                end
            end

            total_checks = total_checks + 1;
            if (mismatch) begin
                fail_checks = fail_checks + 1;
            end else begin
                pass_checks = pass_checks + 1;
                $display("[PASS] %0s packed metadata time=%0t", name, $time);
            end
        end
    endtask

    task check_outputs_dense;
        input [255:0] name;
        begin
            mismatch = 1'b0;

            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    if (out_valid[r*COLS + c] !== expected_slot_valid[r]) begin
                        $display("[FAIL] %0s out_valid row=%0d col=%0d expected=%0b got=%0b time=%0t",
                                 name, r, c, expected_slot_valid[r], out_valid[r*COLS + c], $time);
                        mismatch = 1'b1;
                    end

                    if (expected_slot_valid[r] && out_valid[r*COLS + c]) begin
                        for (j = 0; j < OUT_CH; j = j + 1) begin
                            dut_val = out_psum[(r*COLS + c)*O_W + j*PSUM_W +: PSUM_W];
                            if (dut_val !== expected[r][c][j]) begin
                                $display("[FAIL] %0s row=%0d col=%0d ch=%0d expected=%0d got=%0d time=%0t",
                                         name, r, c, j, expected[r][c][j], dut_val, $time);
                                mismatch = 1'b1;
                            end
                        end
                    end
                end
            end

            total_checks = total_checks + 1;
            if (mismatch) begin
                fail_checks = fail_checks + 1;
            end else begin
                pass_checks = pass_checks + 1;
                $display("[PASS] %0s outputs time=%0t", name, $time);
            end
        end
    endtask

    task check_outputs_sparse;
        input [255:0] name;
        begin
            mismatch = 1'b0;

            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    if (out_valid[r*COLS + c] !== expected_slot_valid[r]) begin
                        $display("[FAIL] %0s out_valid packed_row=%0d col=%0d expected=%0b got=%0b time=%0t",
                                 name, r, c, expected_slot_valid[r], out_valid[r*COLS + c], $time);
                        mismatch = 1'b1;
                    end

                    if (expected_slot_valid[r] && out_valid[r*COLS + c]) begin
                        for (j = 0; j < OUT_CH; j = j + 1) begin
                            dut_val = out_psum[(r*COLS + c)*O_W + j*PSUM_W +: PSUM_W];
                            if (dut_val !== expected[r][c][j]) begin
                                $display("[FAIL] %0s packed_row=%0d col=%0d ch=%0d expected=%0d got=%0d time=%0t",
                                         name, r, c, j, expected[r][c][j], dut_val, $time);
                                mismatch = 1'b1;
                            end
                        end
                    end
                end
            end

            total_checks = total_checks + 1;
            if (mismatch) begin
                fail_checks = fail_checks + 1;
            end else begin
                pass_checks = pass_checks + 1;
                $display("[PASS] %0s outputs time=%0t", name, $time);
            end
        end
    endtask

    task drain_outputs;
        integer k;
        begin
            tile_ready = {ROWS*COLS{1'b1}};
            for (k = 0; k < 8; k = k + 1)
                @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("hybrid_sparse_dense_core_wave.vcd");
        $dumpvars(0, tb_lutein_hybrid_sparse_dense_core_4x4);

        clk                = 1'b0;
        rst_n              = 1'b0;
        sparse_mode_en     = 1'b0;
        clear_acc          = 1'b0;
        accum_en           = 1'b1;
        left_valid         = '0;
        left_data          = '0;
        dense_weight       = '0;
        sparse_w_load_en   = '0;
        sparse_w_load_idx  = '0;
        sparse_w_load_data = '0;
        tile_ready         = {ROWS*COLS{1'b1}};

        clear_counters();

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

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

        reset_and_reload_weights();

        sparse_mode_en = 1'b0;
        in_vec[0][0] =  1; in_vec[0][1] =  2; in_vec[0][2] = -1; in_vec[0][3] =  0;
        in_vec[1][0] =  0; in_vec[1][1] =  0; in_vec[1][2] =  0; in_vec[1][3] =  0;
        in_vec[2][0] = -2; in_vec[2][1] =  1; in_vec[2][2] =  3; in_vec[2][3] = -1;
        in_vec[3][0] =  4; in_vec[3][1] = -3; in_vec[3][2] =  1; in_vec[3][3] =  2;

        left_valid = 4'b1111;
        compute_expected_dense();
        left_valid = '0;

        tile_ready = '0;
        clear_acc = 1'b1;
        @(posedge clk);
        clear_acc = 1'b0;

        inject_inputs_once();
        #1;
        check_packed_metadata("TC01_dense_metadata");

        repeat (16) @(posedge clk);
        #1;
        check_outputs_dense("TC01_dense_outputs");
        drain_outputs();

        reset_and_reload_weights();

        sparse_mode_en = 1'b1;

        left_valid = 4'b1111;
        compute_expected_sparse();
        left_valid = '0;

        tile_ready = '0;
        clear_acc = 1'b1;
        @(posedge clk);
        clear_acc = 1'b0;

        inject_inputs_once();
        #1;
        check_packed_metadata("TC02_sparse_metadata");

        repeat (16) @(posedge clk);
        #1;
        check_outputs_sparse("TC02_sparse_outputs");
        drain_outputs();

        reset_and_reload_weights();

        sparse_mode_en = 1'b1;
        in_vec[0][0] =  0; in_vec[0][1] =  0; in_vec[0][2] =  0; in_vec[0][3] =  0;
        in_vec[1][0] =  0; in_vec[1][1] =  0; in_vec[1][2] =  0; in_vec[1][3] =  0;
        in_vec[2][0] = -1; in_vec[2][1] =  2; in_vec[2][2] =  0; in_vec[2][3] =  1;
        in_vec[3][0] =  0; in_vec[3][1] =  0; in_vec[3][2] =  0; in_vec[3][3] =  0;

        left_valid = 4'b1111;
        compute_expected_sparse();
        left_valid = '0;

        tile_ready = '0;
        clear_acc = 1'b1;
        @(posedge clk);
        clear_acc = 1'b0;

        inject_inputs_once();
        #1;
        check_packed_metadata("TC03_sparse_single_row_metadata");

        repeat (16) @(posedge clk);
        #1;
        check_outputs_sparse("TC03_sparse_single_row_outputs");
        drain_outputs();

        $display("============================================================");
        $display("TB SUMMARY: total=%0d pass=%0d fail=%0d", total_checks, pass_checks, fail_checks);
        $display("============================================================");

        if (fail_checks == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");

        #20;
        $finish;
    end

endmodule