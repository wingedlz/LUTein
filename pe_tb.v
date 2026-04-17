module tb_lutein_slice_tensor_pe;

    localparam integer IN_LANES = 4;
    localparam integer OUT_CH   = 8;
    localparam integer ACT_W    = 4;
    localparam integer WGT_W    = 4;
    localparam integer PROD_W   = 8;
    localparam integer ACC_W    = 24;
    localparam integer PSUM_W   = 24;

    reg clk;
    reg rst_n;
    reg in_valid;
    reg clear_acc;
    reg accum_en;
    reg out_ready;
    reg in_slice_fwd_ready;

    reg  signed [IN_LANES*ACT_W-1:0]        in_slice_flat;
    reg  signed [IN_LANES*OUT_CH*WGT_W-1:0] wgt_slice_flat;

    wire                                    in_ready;
    wire                                    out_valid;
    wire signed [OUT_CH*PSUM_W-1:0]         out_psum_flat;
    wire signed [IN_LANES*ACT_W-1:0]        in_slice_fwd_flat;
    wire                                    in_slice_fwd_valid;

    integer i;
    integer j;
    integer t;
    integer seed;
    integer total_checks;
    integer pass_checks;
    integer fail_checks;
    integer hold_cycles;
    integer hold_cycles_max;

    reg mismatch;
    reg signed [PSUM_W-1:0] dut_val;

    reg signed [ACT_W-1:0] in_tmp [0:IN_LANES-1];
    reg signed [WGT_W-1:0] w_tmp  [0:IN_LANES-1][0:OUT_CH-1];

    reg signed [PSUM_W-1:0] ref_acc  [0:OUT_CH-1];
    reg signed [PSUM_W-1:0] exp_psum [0:OUT_CH-1];
    reg all_zero;
    reg signed [PSUM_W-1:0] sum;

    reg signed [IN_LANES*ACT_W-1:0] exp_fwd_flat;

    lutein_slice_tensor_pe #(
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
        .in_valid(in_valid),
        .clear_acc(clear_acc),
        .accum_en(accum_en),
        .out_ready(out_ready),
        .in_slice_fwd_ready(in_slice_fwd_ready),
        .in_slice_flat(in_slice_flat),
        .wgt_slice_flat(wgt_slice_flat),
        .in_ready(in_ready),
        .out_valid(out_valid),
        .out_psum_flat(out_psum_flat),
        .in_slice_fwd_flat(in_slice_fwd_flat),
        .in_slice_fwd_valid(in_slice_fwd_valid)
    );

    always #5 clk = ~clk;

    task pack_inputs;
        begin
            for (i = 0; i < IN_LANES; i = i + 1) begin
                in_slice_flat[i*ACT_W +: ACT_W] = in_tmp[i];
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    wgt_slice_flat[(i*OUT_CH + j)*WGT_W +: WGT_W] = w_tmp[i][j];
                end
            end
        end
    endtask

    task pack_expected_fwd;
        begin
            for (i = 0; i < IN_LANES; i = i + 1) begin
                exp_fwd_flat[i*ACT_W +: ACT_W] = in_tmp[i];
            end
        end
    endtask

    task clear_reference_acc;
        begin
            for (j = 0; j < OUT_CH; j = j + 1) begin
                ref_acc[j] = '0;
            end
        end
    endtask

    task compute_expected;
        begin
            all_zero = 1'b1;
            for (i = 0; i < IN_LANES; i = i + 1) begin
                if (in_tmp[i] != 0)
                    all_zero = 1'b0;
            end

            for (j = 0; j < OUT_CH; j = j + 1) begin
                sum = '0;
                for (i = 0; i < IN_LANES; i = i + 1) begin
                    sum = sum + (in_tmp[i] * w_tmp[i][j]);
                end

                if (all_zero)
                    exp_psum[j] = ref_acc[j];
                else
                    exp_psum[j] = ref_acc[j] + sum;
            end
        end
    endtask

    task commit_reference;
        begin
            for (j = 0; j < OUT_CH; j = j + 1) begin
                ref_acc[j] = exp_psum[j];
            end
        end
    endtask

    task check_output;
        input [255:0] name;
        begin
            total_checks = total_checks + 1;
            mismatch = 1'b0;

            while (!out_valid) begin
                @(posedge clk);
            end

            #1;
            for (j = 0; j < OUT_CH; j = j + 1) begin
                dut_val = out_psum_flat[j*PSUM_W +: PSUM_W];
                if (dut_val !== exp_psum[j]) begin
                    $display("[FAIL] %0s psum ch%0d expected=%0d got=%0d at time=%0t",
                             name, j, exp_psum[j], dut_val, $time);
                    mismatch = 1'b1;
                end
            end

            if (mismatch) begin
                fail_checks = fail_checks + 1;
            end else begin
                pass_checks = pass_checks + 1;
                $display("[PASS] %0s psum at time=%0t", name, $time);
            end
        end
    endtask

    task drive_case;
        input [255:0] name;
        input integer hold_output;
        begin
            compute_expected();

            while (!in_ready) @(posedge clk);
            pack_inputs();

            in_valid = 1'b1;
            @(posedge clk);
            in_valid = 1'b0;

            if (hold_output > 0) begin
                out_ready = 1'b0;
                repeat (hold_output) @(posedge clk);
                out_ready = 1'b1;
            end

            check_output(name);
            commit_reference();
            @(posedge clk);
        end
    endtask

    task drive_case_with_forward;
        input [255:0] name;
        input integer hold_output;
        input integer hold_forward;

        integer wait_cycles;
        integer max_wait;
        reg got_psum;
        reg got_forward;
        begin
            compute_expected();
            pack_expected_fwd();

            out_ready          = 1'b1;
            in_slice_fwd_ready = 1'b1;

            while (!in_ready) begin
                @(posedge clk);
            end

            pack_inputs();
            in_valid = 1'b1;
            @(posedge clk);
            in_valid = 1'b0;

            if (hold_output > 0)
                out_ready = 1'b0;
            if (hold_forward > 0)
                in_slice_fwd_ready = 1'b0;

            got_psum    = 1'b0;
            got_forward = 1'b0;
            wait_cycles = 0;
            max_wait    = ((hold_output > hold_forward) ? hold_output : hold_forward) + 5;

            while (!(got_psum && got_forward) && (wait_cycles < max_wait)) begin
                @(posedge clk);
                #1;

                if (!got_psum && out_valid) begin
                    total_checks = total_checks + 1;
                    mismatch = 1'b0;

                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        dut_val = out_psum_flat[j*PSUM_W +: PSUM_W];
                        if (dut_val !== exp_psum[j]) begin
                            $display("[FAIL] %0s psum ch%0d expected=%0d got=%0d at time=%0t",
                                     name, j, exp_psum[j], dut_val, $time);
                            mismatch = 1'b1;
                        end
                    end

                    if (mismatch) begin
                        fail_checks = fail_checks + 1;
                    end else begin
                        pass_checks = pass_checks + 1;
                        $display("[PASS] %0s psum at time=%0t", name, $time);
                    end

                    got_psum = 1'b1;
                end

                if (!got_forward && in_slice_fwd_valid) begin
                    total_checks = total_checks + 1;

                    if (in_slice_fwd_flat !== exp_fwd_flat) begin
                        $display("[FAIL] %0s forward expected=%0h got=%0h at time=%0t",
                                 name, exp_fwd_flat, in_slice_fwd_flat, $time);
                        fail_checks = fail_checks + 1;
                    end else begin
                        $display("[PASS] %0s forward at time=%0t", name, $time);
                        pass_checks = pass_checks + 1;
                    end

                    got_forward = 1'b1;
                end

                wait_cycles = wait_cycles + 1;
            end

            if (!got_psum || !got_forward) begin
                $display("[FAIL] %0s timeout before release at time=%0t", name, $time);
                $display("       got_psum=%0b got_forward=%0b out_valid=%0b out_ready=%0b fwd_valid=%0b fwd_ready=%0b in_ready=%0b",
                         got_psum, got_forward,
                         out_valid, out_ready,
                         in_slice_fwd_valid, in_slice_fwd_ready,
                         in_ready);
                fail_checks = fail_checks + 1;
            end

            out_ready          = 1'b1;
            in_slice_fwd_ready = 1'b1;

            @(posedge clk);
            commit_reference();
            @(posedge clk);
        end
    endtask

    task pulse_clear_acc;
        begin
            clear_acc = 1'b1;
            @(posedge clk);
            clear_acc = 1'b0;
            clear_reference_acc();
            @(posedge clk);
        end
    endtask

    task set_case_pattern_1;
        begin
            in_tmp[0] =  4'sd1;
            in_tmp[1] =  4'sd2;
            in_tmp[2] = -4'sd1;
            in_tmp[3] =  4'sd3;

            for (i = 0; i < IN_LANES; i = i + 1) begin
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    w_tmp[i][j] = ((i + j) % 4) - 2;
                end
            end
        end
    endtask

    task set_case_all_zero_input;
        begin
            for (i = 0; i < IN_LANES; i = i + 1) begin
                in_tmp[i] = 4'sd0;
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    w_tmp[i][j] = (j % 3) - 1;
                end
            end
        end
    endtask

    task set_case_negative_heavy;
        begin
            in_tmp[0] = -4'sd8;
            in_tmp[1] = -4'sd3;
            in_tmp[2] =  4'sd7;
            in_tmp[3] = -4'sd1;

            for (i = 0; i < IN_LANES; i = i + 1) begin
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    case (j % 4)
                        0: w_tmp[i][j] = -4'sd8;
                        1: w_tmp[i][j] = -4'sd1;
                        2: w_tmp[i][j] =  4'sd3;
                        default: w_tmp[i][j] = 4'sd7;
                    endcase
                end
            end
        end
    endtask

    task set_case_random;
        integer rv;
        begin
            for (i = 0; i < IN_LANES; i = i + 1) begin
                rv = $random(seed);
                in_tmp[i] = rv % 16;
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    rv = $random(seed);
                    w_tmp[i][j] = rv % 16;
                end
            end
        end
    endtask

    task set_case_accum_easy;
        begin
            in_tmp[0] = 4'sd1;
            in_tmp[1] = 4'sd1;
            in_tmp[2] = 4'sd1;
            in_tmp[3] = 4'sd1;

            for (i = 0; i < IN_LANES; i = i + 1) begin
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    w_tmp[i][j] = 4'sd1;
                end
            end
        end
    endtask

    task set_case_accum_channel_varied;
        begin
            in_tmp[0] =  4'sd1;
            in_tmp[1] =  4'sd2;
            in_tmp[2] =  4'sd0;
            in_tmp[3] = -4'sd1;

            for (j = 0; j < OUT_CH; j = j + 1) begin
                w_tmp[0][j] =  4'sd1;
                w_tmp[1][j] =  j[3:0];
                w_tmp[2][j] = -4'sd3;
                w_tmp[3][j] =  4'sd1;
            end
        end
    endtask

    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_lutein_slice_tensor_pe);

        clk                = 1'b0;
        rst_n              = 1'b0;
        in_valid           = 1'b0;
        clear_acc          = 1'b0;
        accum_en           = 1'b1;
        out_ready          = 1'b1;
        in_slice_fwd_ready = 1'b1;
        in_slice_flat      = '0;
        wgt_slice_flat     = '0;

        seed         = 32'h1234abcd;
        total_checks = 0;
        pass_checks  = 0;
        fail_checks  = 0;

        clear_reference_acc();

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        set_case_pattern_1();
        drive_case("TC01_basic", 0);

        set_case_pattern_1();
        drive_case("TC02_accumulate_repeat", 0);

        set_case_all_zero_input();
        drive_case("TC03_zero_skip", 0);

        set_case_negative_heavy();
        drive_case("TC04_negative_heavy", 0);

        set_case_pattern_1();
        drive_case("TC05_output_backpressure", 4);

        pulse_clear_acc();
        set_case_negative_heavy();
        drive_case("TC06_after_clear", 0);

        pulse_clear_acc();

        set_case_accum_easy();
        drive_case("TC07_accum_easy_1x", 0);

        set_case_accum_easy();
        drive_case("TC08_accum_easy_2x", 0);

        set_case_accum_easy();
        drive_case("TC09_accum_easy_3x", 0);

        set_case_all_zero_input();
        drive_case("TC10_accum_hold_zero", 0);

        pulse_clear_acc();
        set_case_accum_easy();
        drive_case("TC11_accum_after_clear", 0);

        pulse_clear_acc();
        set_case_accum_channel_varied();
        drive_case("TC12_accum_varied_1x", 0);

        set_case_accum_channel_varied();
        drive_case("TC13_accum_varied_2x", 0);

        pulse_clear_acc();

        set_case_pattern_1();
        drive_case_with_forward("TC14_forward_basic", 0, 0);

        set_case_all_zero_input();
        drive_case_with_forward("TC15_forward_zero", 0, 0);

        set_case_negative_heavy();
        drive_case_with_forward("TC16_forward_negative", 0, 0);

        set_case_pattern_1();
        drive_case_with_forward("TC17_forward_backpressure", 3, 3);

        for (t = 0; t < 40; t = t + 1) begin
            if ((t % 9) == 0)
                pulse_clear_acc();

            if ((t % 7) == 0)
                set_case_all_zero_input();
            else
                set_case_random();

            if ((t % 5) == 0)
                hold_cycles = 2;
            else
                hold_cycles = 0;

            drive_case("TC18_random_stress", hold_cycles);
        end

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