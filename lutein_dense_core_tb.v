module tb_lutein_dense_core_4x4;
    localparam integer ROWS      = 4;
    localparam integer COLS      = 4;
    localparam integer IN_LANES  = 4;
    localparam integer OUT_CH    = 8;
    localparam integer ACT_W     = 4;
    localparam integer WGT_W     = 4;
    localparam integer PSUM_W    = 24;
    localparam integer IN_DATA_W = IN_LANES * ACT_W;
    localparam integer WBUF_DATA_W = IN_LANES * OUT_CH * WGT_W;
    localparam integer PE_PSUM_W = OUT_CH * PSUM_W;

    reg clk;
    reg rst_n;
    reg clear_acc;
    reg accum_en;

    reg [ROWS-1:0] left_load_en;
    reg [ROWS*IN_DATA_W-1:0] left_load_data_flat;

    reg [COLS-1:0] wbuf_load_en;
    reg [COLS*WBUF_DATA_W-1:0] wbuf_load_data_flat;

    reg [ROWS*COLS-1:0] tile_ready;

    wire [ROWS*COLS-1:0] pe_out_valid_flat;
    wire [ROWS*COLS*PE_PSUM_W-1:0] pe_out_psum_flat;
    wire [ROWS*COLS-1:0] tile_valid;
    wire [ROWS*COLS*PE_PSUM_W-1:0] tile_psum_flat;

    integer r, c, i, j;
    integer timeout;
    reg mismatch;
    reg signed [PSUM_W-1:0] dut_val;
    reg signed [ACT_W-1:0] in_vec [0:ROWS-1][0:IN_LANES-1];
    reg signed [WGT_W-1:0] w_mat  [0:COLS-1][0:IN_LANES-1][0:OUT_CH-1];
    reg signed [PSUM_W-1:0] expected [0:ROWS-1][0:COLS-1][0:OUT_CH-1];
    reg signed [PSUM_W-1:0] sum;

    lutein_dense_core_4x4 #(
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
        .clear_acc(clear_acc),
        .accum_en(accum_en),
        .left_load_en(left_load_en),
        .left_load_data_flat(left_load_data_flat),
        .wbuf_load_en(wbuf_load_en),
        .wbuf_load_data_flat(wbuf_load_data_flat),
        .tile_ready(tile_ready),
        .pe_out_valid_flat(pe_out_valid_flat),
        .pe_out_psum_flat(pe_out_psum_flat),
        .tile_valid(tile_valid),
        .tile_psum_flat(tile_psum_flat)
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

    task compute_expected_dense;
        begin
            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        sum = '0;
                        for (i = 0; i < IN_LANES; i = i + 1) begin
                            sum = sum + (in_vec[r][i] * w_mat[c][i][j]);
                        end
                        expected[r][c][j] = sum;
                    end
                end
            end
        end
    endtask

    task wait_all_valid_and_check;
        begin
            timeout = 0;
            while ((&tile_valid) !== 1'b1 && timeout < 80) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if ((&tile_valid) !== 1'b1) begin
                $display("[FAIL] timeout waiting for tile_valid at time=%0t", $time);
                $finish;
            end

            #1;
            mismatch = 1'b0;

            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        dut_val = tile_psum_flat[((r*COLS + c)*PE_PSUM_W) + (j*PSUM_W) +: PSUM_W];
                        if (dut_val !== expected[r][c][j]) begin
                            $display("[FAIL] row=%0d col=%0d ch=%0d expected=%0d got=%0d time=%0t",
                                     r, c, j, expected[r][c][j], dut_val, $time);
                            mismatch = 1'b1;
                        end
                    end
                end
            end

            if (!mismatch)
                $display("[PASS] dense tile check passed at time=%0t", $time);
        end
    endtask

    initial begin
        $dumpfile("dense_core_wave.vcd");
        $dumpvars(0, tb_lutein_dense_core_4x4);

        clk = 1'b0;
        rst_n = 1'b0;
        clear_acc = 1'b0;
        accum_en = 1'b1;
        left_load_en = '0;
        left_load_data_flat = '0;
        wbuf_load_en = '0;
        wbuf_load_data_flat = '0;
        tile_ready = '0;  // 먼저 막아두고 valid 유지 확인

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Column-wise weight setup
        for (c = 0; c < COLS; c = c + 1) begin
            for (i = 0; i < IN_LANES; i = i + 1) begin
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    w_mat[c][i][j] = ((c + i + j) % 5) - 2;
                end
            end
        end

        // One input vector per row
        for (r = 0; r < ROWS; r = r + 1) begin
            in_vec[r][0] = r;
            in_vec[r][1] = r + 1;
            in_vec[r][2] = -r;
            in_vec[r][3] = 2 - r;
        end

        compute_expected_dense();
        load_dense_weights();
        inject_left_inputs();

        // out_ready=0 상태에서도 tile_valid가 유지되는지 포함해서 검사
        wait_all_valid_and_check();

        // 이제 결과 drain
        tile_ready = {ROWS*COLS{1'b1}};
        repeat (4) @(posedge clk);

        $display("[DONE] dense core tb finished");
        $finish;
    end
endmodule