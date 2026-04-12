module lutein_dense_ibuf #(
    parameter integer DATA_W = 16
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

module lutein_dense_wbuf #(
    parameter integer DATA_W = 128
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              load_en,
    input  wire [DATA_W-1:0] load_data,
    output reg  [DATA_W-1:0] data_out
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            data_out <= '0;
        else if (load_en)
            data_out <= load_data;
    end
endmodule

module lutein_dense_agg #(
    parameter integer ROWS   = 4,
    parameter integer COLS   = 4,
    parameter integer OUT_CH = 8,
    parameter integer PSUM_W = 24
) (
    input  wire [ROWS*COLS-1:0]                     pe_out_valid,
    input  wire [ROWS*COLS*OUT_CH*PSUM_W-1:0]       pe_out_psum_flat,
    output wire [ROWS*COLS-1:0]                     tile_valid,
    output wire [ROWS*COLS*OUT_CH*PSUM_W-1:0]       tile_psum_flat
);
    assign tile_valid     = pe_out_valid;
    assign tile_psum_flat = pe_out_psum_flat;
endmodule

module lutein_dense_core_4x4 #(
    parameter integer ROWS     = 4,
    parameter integer COLS     = 4,
    parameter integer IN_LANES = 4,
    parameter integer OUT_CH   = 8,
    parameter integer ACT_W    = 4,
    parameter integer WGT_W    = 4,
    parameter integer PROD_W   = 8,
    parameter integer ACC_W    = 24,
    parameter integer PSUM_W   = 24
) (
    input  wire clk,
    input  wire rst_n,

    input  wire clear_acc,
    input  wire accum_en,

    input  wire [ROWS-1:0] left_load_en,
    input  wire [ROWS*IN_LANES*ACT_W-1:0] left_load_data_flat,

    input  wire [COLS-1:0] wbuf_load_en,
    input  wire [COLS*IN_LANES*OUT_CH*WGT_W-1:0] wbuf_load_data_flat,

    input  wire [ROWS*COLS-1:0] tile_ready,

    output wire [ROWS*COLS-1:0] pe_out_valid_flat,
    output wire [ROWS*COLS*OUT_CH*PSUM_W-1:0] pe_out_psum_flat,
    output wire [ROWS*COLS-1:0] tile_valid,
    output wire [ROWS*COLS*OUT_CH*PSUM_W-1:0] tile_psum_flat
);
    localparam integer IN_DATA_W  = IN_LANES * ACT_W;
    localparam integer WBUF_DATA_W = IN_LANES * OUT_CH * WGT_W;
    localparam integer PE_PSUM_W   = OUT_CH * PSUM_W;

    genvar r;
    genvar c;

    wire [IN_DATA_W-1:0] ibuf_data_out [0:ROWS-1];
    wire                 ibuf_valid_out[0:ROWS-1];
    wire [WBUF_DATA_W-1:0] wbuf_data_out[0:COLS-1];

    wire [IN_DATA_W-1:0] pe_in_slice   [0:ROWS-1][0:COLS-1];
    wire                 pe_in_valid   [0:ROWS-1][0:COLS-1];
    wire                 pe_in_ready   [0:ROWS-1][0:COLS-1];
    wire [IN_DATA_W-1:0] pe_fwd_slice  [0:ROWS-1][0:COLS-1];
    wire                 pe_fwd_valid  [0:ROWS-1][0:COLS-1];
    wire [PE_PSUM_W-1:0] pe_psum       [0:ROWS-1][0:COLS-1];
    wire                 pe_out_valid  [0:ROWS-1][0:COLS-1];

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : G_IBUF
            lutein_dense_ibuf #(
                .DATA_W(IN_DATA_W)
            ) u_ibuf (
                .clk(clk),
                .rst_n(rst_n),
                .load_en(left_load_en[r]),
                .load_data(left_load_data_flat[r*IN_DATA_W +: IN_DATA_W]),
                .ready_in(pe_in_ready[r][0]),
                .data_out(ibuf_data_out[r]),
                .valid_out(ibuf_valid_out[r])
            );
        end
    endgenerate

    generate
        for (c = 0; c < COLS; c = c + 1) begin : G_WBUF
            lutein_dense_wbuf #(
                .DATA_W(WBUF_DATA_W)
            ) u_wbuf (
                .clk(clk),
                .rst_n(rst_n),
                .load_en(wbuf_load_en[c]),
                .load_data(wbuf_load_data_flat[c*WBUF_DATA_W +: WBUF_DATA_W]),
                .data_out(wbuf_data_out[c])
            );
        end
    endgenerate

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : G_ROW
            for (c = 0; c < COLS; c = c + 1) begin : G_COL
                if (c == 0) begin : G_LEFT_EDGE
                    assign pe_in_slice[r][c] = ibuf_data_out[r];
                    assign pe_in_valid[r][c] = ibuf_valid_out[r];
                end else begin : G_INTERIOR
                    assign pe_in_slice[r][c] = pe_fwd_slice[r][c-1];
                    assign pe_in_valid[r][c] = pe_fwd_valid[r][c-1];
                end
                if (c == COLS-1) begin : G_LAST_COL
                    lutein_slice_tensor_pe #(
                        .IN_LANES(IN_LANES),
                        .OUT_CH(OUT_CH),
                        .ACT_W(ACT_W),
                        .WGT_W(WGT_W),
                        .PROD_W(PROD_W),
                        .ACC_W(ACC_W),
                        .PSUM_W(PSUM_W)
                    ) u_pe (
                        .clk(clk),
                        .rst_n(rst_n),
                        .in_valid(pe_in_valid[r][c]),
                        .clear_acc(clear_acc),
                        .accum_en(accum_en),
                        .out_ready(tile_ready[r*COLS + c]),
                        .in_slice_fwd_ready(1'b1),
                        .in_slice_flat(pe_in_slice[r][c]),
                        .wgt_slice_flat(wbuf_data_out[c]),
                        .in_ready(pe_in_ready[r][c]),
                        .out_valid(pe_out_valid[r][c]),
                        .out_psum_flat(pe_psum[r][c]),
                        .in_slice_fwd_flat(pe_fwd_slice[r][c]),
                        .in_slice_fwd_valid(pe_fwd_valid[r][c])
                    );
                end else begin : G_NON_LAST_COL
                    lutein_slice_tensor_pe #(
                        .IN_LANES(IN_LANES),
                        .OUT_CH(OUT_CH),
                        .ACT_W(ACT_W),
                        .WGT_W(WGT_W),
                        .PROD_W(PROD_W),
                        .ACC_W(ACC_W),
                        .PSUM_W(PSUM_W)
                    ) u_pe (
                        .clk(clk),
                        .rst_n(rst_n),
                        .in_valid(pe_in_valid[r][c]),
                        .clear_acc(clear_acc),
                        .accum_en(accum_en),
                        .out_ready(tile_ready[r*COLS + c]),
                        .in_slice_fwd_ready(pe_in_ready[r][c+1]),
                        .in_slice_flat(pe_in_slice[r][c]),
                        .wgt_slice_flat(wbuf_data_out[c]),
                        .in_ready(pe_in_ready[r][c]),
                        .out_valid(pe_out_valid[r][c]),
                        .out_psum_flat(pe_psum[r][c]),
                        .in_slice_fwd_flat(pe_fwd_slice[r][c]),
                        .in_slice_fwd_valid(pe_fwd_valid[r][c])
                    );
                end

                assign pe_out_valid_flat[r*COLS + c] = pe_out_valid[r][c];
                assign pe_out_psum_flat[(r*COLS + c)*PE_PSUM_W +: PE_PSUM_W] = pe_psum[r][c];
            end
        end
    endgenerate

    lutein_dense_agg #(
        .ROWS(ROWS),
        .COLS(COLS),
        .OUT_CH(OUT_CH),
        .PSUM_W(PSUM_W)
    ) u_agg (
        .pe_out_valid(pe_out_valid_flat),
        .pe_out_psum_flat(pe_out_psum_flat),
        .tile_valid(tile_valid),
        .tile_psum_flat(tile_psum_flat)
    );
endmodule
