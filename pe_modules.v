module lutein_radix4_addr_gen (
    input  wire [2:0] bits,
    output reg  [2:0] addr
);
    always @(*) begin
        case (bits)
            3'b000: addr = 3'd4; // 0
            3'b001: addr = 3'd0; // +a
            3'b010: addr = 3'd0; // +a
            3'b011: addr = 3'd2; // +2a
            3'b100: addr = 3'd3; // -2a
            3'b101: addr = 3'd1; // -a
            3'b110: addr = 3'd1; // -a
            3'b111: addr = 3'd4; // 0
            default: addr = 3'd4;
        endcase
    end
endmodule

module lutein_radix4_lut_ppg #(
    parameter integer A_W  = 4,
    parameter integer PP_W = 8
) (
    input  wire signed [A_W-1:0] a,
    input  wire [2:0]            addr,
    output reg  signed [PP_W-1:0] pp
);
    wire signed [PP_W-1:0] a_ext;
    wire signed [PP_W-1:0] neg_a;
    wire signed [PP_W-1:0] two_a;
    wire signed [PP_W-1:0] neg_two_a;

    assign a_ext     = $signed(a);
    assign neg_a     = -a_ext;
    assign two_a     = a_ext <<< 1;
    assign neg_two_a = -(a_ext <<< 1);

    always @(*) begin
        case (addr)
            3'd0: pp = a_ext;
            3'd1: pp = neg_a;
            3'd2: pp = two_a;
            3'd3: pp = neg_two_a;
            default: pp = {PP_W{1'b0}};
        endcase
    end
endmodule

module lutein_radix4_lut_mult_4b (
    input  wire signed [3:0] a,
    input  wire signed [3:0] b,
    output wire signed [7:0] p
);
    wire [2:0] addr_lo;
    wire [2:0] addr_hi;
    wire signed [7:0] pp_lo;
    wire signed [7:0] pp_hi;

    lutein_radix4_addr_gen u_addr_lo (
        .bits({b[1:0], 1'b0}),
        .addr(addr_lo)
    );

    lutein_radix4_addr_gen u_addr_hi (
        .bits(b[3:1]),
        .addr(addr_hi)
    );

    lutein_radix4_lut_ppg #(
        .A_W(4),
        .PP_W(8)
    ) u_ppg_lo (
        .a(a),
        .addr(addr_lo),
        .pp(pp_lo)
    );

    lutein_radix4_lut_ppg #(
        .A_W(4),
        .PP_W(8)
    ) u_ppg_hi (
        .a(a),
        .addr(addr_hi),
        .pp(pp_hi)
    );

    assign p = $signed(pp_lo) + ($signed(pp_hi) <<< 2);
endmodule

module lutein_slice_tensor_pe #(
    parameter integer IN_LANES = 4,
    parameter integer OUT_CH   = 8,
    parameter integer ACT_W    = 4,
    parameter integer WGT_W    = 4,
    parameter integer PROD_W   = 8,
    parameter integer ACC_W    = 24,
    parameter integer PSUM_W   = 24
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              in_valid,
    input  wire                              clear_acc,
    input  wire                              accum_en,
    input  wire                              out_ready,
    input  wire                              in_slice_fwd_ready,
    input  wire signed [IN_LANES*ACT_W-1:0]  in_slice_flat,
    input  wire signed [IN_LANES*OUT_CH*WGT_W-1:0] wgt_slice_flat,
    output wire                              in_ready,
    output reg                               out_valid,
    output reg  signed [OUT_CH*PSUM_W-1:0]   out_psum_flat,
    output reg  signed [IN_LANES*ACT_W-1:0]  in_slice_fwd_flat,
    output reg                               in_slice_fwd_valid
);
    integer i;
    integer j;

    reg signed [ACT_W-1:0] in_q [0:IN_LANES-1];
    reg signed [WGT_W-1:0] w_q  [0:IN_LANES-1][0:OUT_CH-1];
    reg                    compute_pending;
    reg                    zero_q;

    reg signed [ACC_W-1:0] acc_reg [0:OUT_CH-1];
    reg signed [ACC_W-1:0] sum_per_oc [0:OUT_CH-1];

    wire signed [PROD_W-1:0] prod [0:IN_LANES-1][0:OUT_CH-1];

    wire out_chan_free;
    wire fwd_chan_free;

    assign out_chan_free = (~out_valid) || out_ready;
    assign fwd_chan_free = (~in_slice_fwd_valid) || in_slice_fwd_ready;

    assign in_ready = (~compute_pending) && out_chan_free && fwd_chan_free;

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
        if (!rst_n) begin
            compute_pending   <= 1'b0;
            out_valid         <= 1'b0;
            in_slice_fwd_valid <= 1'b0;
            in_slice_fwd_flat <= '0;
            out_psum_flat     <= '0;
            zero_q            <= 1'b0;

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
            if (clear_acc) begin
                for (j = 0; j < OUT_CH; j = j + 1) begin
                    acc_reg[j] <= '0;
                end
            end

            if (out_valid && out_ready) begin
                out_valid <= 1'b0;
            end

            if (in_slice_fwd_valid && in_slice_fwd_ready) begin
                in_slice_fwd_valid <= 1'b0;
            end

            if (in_valid && in_ready) begin
                zero_q <= 1'b1;

                for (i = 0; i < IN_LANES; i = i + 1) begin
                    in_q[i] <= $signed(in_slice_flat[i*ACT_W +: ACT_W]);
                    if ($signed(in_slice_flat[i*ACT_W +: ACT_W]) != 0)
                        zero_q <= 1'b0;

                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        w_q[i][j] <= $signed(wgt_slice_flat[(i*OUT_CH + j)*WGT_W +: WGT_W]);
                    end
                end

                in_slice_fwd_flat  <= in_slice_flat;
                in_slice_fwd_valid <= 1'b1;
                compute_pending    <= 1'b1;
            end

            if (compute_pending) begin
                if (accum_en) begin
                    for (j = 0; j < OUT_CH; j = j + 1) begin
                        if (zero_q) begin
                            out_psum_flat[j*PSUM_W +: PSUM_W] <= acc_reg[j];
                        end else begin
                            acc_reg[j] <= $signed(acc_reg[j]) + $signed(sum_per_oc[j]);
                            out_psum_flat[j*PSUM_W +: PSUM_W] <= $signed(acc_reg[j]) + $signed(sum_per_oc[j]);
                        end
                    end
                    out_valid <= 1'b1;
                end
                compute_pending <= 1'b0;
            end
        end
    end
endmodule