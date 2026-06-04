module bb_power_ts1n28_1rw_array #(
  parameter int ADDR_WIDTH = 7,
  parameter int DEPTH = 128,
  parameter int DATA_WIDTH = 64
) (
  input  logic [ADDR_WIDTH-1:0] RW0_addr,
  input  logic                  RW0_en,
                               RW0_clk,
                               RW0_wmode,
  input  logic [DATA_WIDTH-1:0] RW0_wdata,
  output logic [DATA_WIDTH-1:0] RW0_rdata,
  input  logic [DATA_WIDTH-1:0] RW0_wbiten
);

  localparam int MACRO_ADDR_WIDTH = 7;
  localparam int MACRO_DATA_WIDTH = 64;
  localparam int DEPTH_BANKS = (DEPTH + 127) / 128;
  localparam int WIDTH_BANKS = (DATA_WIDTH + MACRO_DATA_WIDTH - 1) / MACRO_DATA_WIDTH;
  localparam int BANK_SEL_WIDTH = (DEPTH_BANKS > 1) ? $clog2(DEPTH_BANKS) : 1;

  logic [BANK_SEL_WIDTH-1:0] bank_sel;
  logic [MACRO_ADDR_WIDTH-1:0] macro_addr;
  logic [BANK_SEL_WIDTH-1:0] rbank_d0;
  logic ren_d0;
  logic rwrite_d0;

  logic [DATA_WIDTH-1:0] bank_rdata [0:DEPTH_BANKS-1];
  logic [MACRO_DATA_WIDTH-1:0] macro_q [0:DEPTH_BANKS-1][0:WIDTH_BANKS-1];

  generate
    if (ADDR_WIDTH > MACRO_ADDR_WIDTH) begin : gen_bank_sel
      assign bank_sel = RW0_addr[ADDR_WIDTH-1:MACRO_ADDR_WIDTH];
    end else begin : gen_bank_sel_const
      assign bank_sel = '0;
    end

    if (ADDR_WIDTH >= MACRO_ADDR_WIDTH) begin : gen_macro_addr_direct
      assign macro_addr = RW0_addr[MACRO_ADDR_WIDTH-1:0];
    end else begin : gen_macro_addr_padded
      assign macro_addr = {{(MACRO_ADDR_WIDTH - ADDR_WIDTH){1'b0}}, RW0_addr};
    end
  endgenerate

  generate
    for (genvar depth_bank = 0; depth_bank < DEPTH_BANKS; depth_bank++) begin : gen_depth_bank
      localparam int BANK_INDEX = depth_bank;
      logic bank_hit;

      if (DEPTH_BANKS == 1) begin : gen_single_depth_bank
        assign bank_hit = RW0_en;
      end else begin : gen_multi_depth_bank
        assign bank_hit = RW0_en && (bank_sel == BANK_INDEX[BANK_SEL_WIDTH-1:0]);
      end

      for (genvar width_bank = 0; width_bank < WIDTH_BANKS; width_bank++) begin : gen_width_bank
        localparam int BIT_LO = width_bank * MACRO_DATA_WIDTH;
        localparam int USED_BITS = ((BIT_LO + MACRO_DATA_WIDTH) <= DATA_WIDTH) ? MACRO_DATA_WIDTH : (DATA_WIDTH - BIT_LO);

        logic [MACRO_DATA_WIDTH-1:0] d_slice;
        logic [MACRO_DATA_WIDTH-1:0] bweb_slice;

        if (USED_BITS == MACRO_DATA_WIDTH) begin : gen_full_width_slice
          assign d_slice = RW0_wdata[BIT_LO +: MACRO_DATA_WIDTH];
          assign bweb_slice = ~(RW0_wbiten[BIT_LO +: MACRO_DATA_WIDTH] & {MACRO_DATA_WIDTH{bank_hit & RW0_wmode}});
          assign bank_rdata[depth_bank][BIT_LO +: MACRO_DATA_WIDTH] = macro_q[depth_bank][width_bank];
        end else begin : gen_partial_width_slice
          assign d_slice = {{(MACRO_DATA_WIDTH - USED_BITS){1'b0}}, RW0_wdata[BIT_LO +: USED_BITS]};
          assign bweb_slice = {{(MACRO_DATA_WIDTH - USED_BITS){1'b1}}, ~(RW0_wbiten[BIT_LO +: USED_BITS] & {USED_BITS{bank_hit & RW0_wmode}})};
          assign bank_rdata[depth_bank][BIT_LO +: USED_BITS] = macro_q[depth_bank][width_bank][USED_BITS-1:0];
        end

        TS1N28HPCPHVTB128X64M4SWBASO u_sram (
          .SLP   (1'b0),
          .SD    (1'b0),
          .CLK   (RW0_clk),
          .CEB   (~bank_hit),
          .WEB   (~(bank_hit & RW0_wmode)),
          .CEBM  (1'b1),
          .WEBM  (1'b1),
          .AWT   (1'b0),
          .A     (macro_addr),
          .D     (d_slice),
          .BWEB  (bweb_slice),
          .AM    (7'b0),
          .DM    (64'b0),
          .BWEBM ({64{1'b1}}),
          .BIST  (1'b0),
          .Q     (macro_q[depth_bank][width_bank])
        );
      end
    end
  endgenerate

  always @(posedge RW0_clk) begin
    ren_d0 <= RW0_en;
    rwrite_d0 <= RW0_wmode;
    rbank_d0 <= bank_sel;
  end

  always @* begin
    RW0_rdata = {DATA_WIDTH{1'bx}};
    if (ren_d0 && !rwrite_d0) begin
      for (int bank_index = 0; bank_index < DEPTH_BANKS; bank_index++) begin
        if (rbank_d0 == BANK_SEL_WIDTH'(bank_index)) begin
          RW0_rdata = bank_rdata[bank_index];
        end
      end
    end
  end
endmodule

// Build a 1R1W SRAM from two copies of the available 1RW macro and a
// 1-bit live-value table so the design can sustain one read and one write
// on the same clock edge.
module bb_power_ts1n28_1r1w_array #(
  parameter int ADDR_WIDTH = 6,
  parameter int DEPTH = 64,
  parameter int DATA_WIDTH = 64
) (
  input  logic [ADDR_WIDTH-1:0] R0_addr,
  input  logic                  R0_en,
                               R0_clk,
  output logic [DATA_WIDTH-1:0] R0_data,
  input  logic [ADDR_WIDTH-1:0] W0_addr,
  input  logic                  W0_en,
                               W0_clk,
  input  logic [DATA_WIDTH-1:0] W0_data
);

  localparam int MACRO_ADDR_WIDTH = 7;
  localparam int MACRO_DATA_WIDTH = 64;
  localparam int DEPTH_BANKS = (DEPTH + 127) / 128;
  localparam int WIDTH_BANKS = (DATA_WIDTH + MACRO_DATA_WIDTH - 1) / MACRO_DATA_WIDTH;
  localparam int BANK_SEL_WIDTH = (DEPTH_BANKS > 1) ? $clog2(DEPTH_BANKS) : 1;

  logic [DEPTH-1:0] latest_bank_bits;
  logic read_bank_copy_now;
  logic write_bank_copy_now;
  logic same_addr_op;

  logic [BANK_SEL_WIDTH-1:0] read_depth_bank_sel;
  logic [BANK_SEL_WIDTH-1:0] write_depth_bank_sel;
  logic [MACRO_ADDR_WIDTH-1:0] read_macro_addr;
  logic [MACRO_ADDR_WIDTH-1:0] write_macro_addr;

  logic ren_d0;
  logic rbank_copy_d0;
  logic [BANK_SEL_WIDTH-1:0] rdepth_bank_d0;
  logic rbypass_d0;
  logic [DATA_WIDTH-1:0] rdata_bypass_d0;

  logic [DATA_WIDTH-1:0] read_copy_rdata [0:1][0:DEPTH_BANKS-1];
  logic [MACRO_DATA_WIDTH-1:0] macro_q [0:1][0:DEPTH_BANKS-1][0:WIDTH_BANKS-1];

  generate
    if (ADDR_WIDTH > MACRO_ADDR_WIDTH) begin : gen_read_bank_sel
      assign read_depth_bank_sel = R0_addr[ADDR_WIDTH-1:MACRO_ADDR_WIDTH];
      assign write_depth_bank_sel = W0_addr[ADDR_WIDTH-1:MACRO_ADDR_WIDTH];
    end else begin : gen_read_bank_sel_const
      assign read_depth_bank_sel = '0;
      assign write_depth_bank_sel = '0;
    end

    if (ADDR_WIDTH >= MACRO_ADDR_WIDTH) begin : gen_macro_addr_direct
      assign read_macro_addr = R0_addr[MACRO_ADDR_WIDTH-1:0];
      assign write_macro_addr = W0_addr[MACRO_ADDR_WIDTH-1:0];
    end else begin : gen_macro_addr_padded
      assign read_macro_addr = {{(MACRO_ADDR_WIDTH - ADDR_WIDTH){1'b0}}, R0_addr};
      assign write_macro_addr = {{(MACRO_ADDR_WIDTH - ADDR_WIDTH){1'b0}}, W0_addr};
    end
  endgenerate

  assign read_bank_copy_now = latest_bank_bits[R0_addr];
  assign same_addr_op = R0_en && W0_en && (R0_addr == W0_addr);
  assign write_bank_copy_now = (R0_en && !same_addr_op) ? ~read_bank_copy_now : 1'b0;

  generate
    for (genvar bank_copy = 0; bank_copy < 2; bank_copy++) begin : gen_bank_copy
      for (genvar depth_bank = 0; depth_bank < DEPTH_BANKS; depth_bank++) begin : gen_depth_bank
        localparam int BANK_INDEX = depth_bank;
        logic read_bank_hit;
        logic write_bank_hit;

        if (DEPTH_BANKS == 1) begin : gen_single_depth_bank
          assign read_bank_hit = R0_en && !same_addr_op && (read_bank_copy_now == bank_copy);
          assign write_bank_hit = W0_en && (write_bank_copy_now == bank_copy);
        end else begin : gen_multi_depth_bank
          assign read_bank_hit =
            R0_en && !same_addr_op && (read_bank_copy_now == bank_copy)
            && (read_depth_bank_sel == BANK_INDEX[BANK_SEL_WIDTH-1:0]);
          assign write_bank_hit =
            W0_en && (write_bank_copy_now == bank_copy)
            && (write_depth_bank_sel == BANK_INDEX[BANK_SEL_WIDTH-1:0]);
        end

        for (genvar width_bank = 0; width_bank < WIDTH_BANKS; width_bank++) begin : gen_width_bank
          localparam int BIT_LO = width_bank * MACRO_DATA_WIDTH;
          localparam int USED_BITS =
            ((BIT_LO + MACRO_DATA_WIDTH) <= DATA_WIDTH) ? MACRO_DATA_WIDTH : (DATA_WIDTH - BIT_LO);

          logic [MACRO_DATA_WIDTH-1:0] d_slice;
          logic [MACRO_DATA_WIDTH-1:0] bweb_slice;
          logic [MACRO_ADDR_WIDTH-1:0] macro_addr_muxed;

          assign macro_addr_muxed = write_bank_hit ? write_macro_addr : read_macro_addr;

          if (USED_BITS == MACRO_DATA_WIDTH) begin : gen_full_width_slice
            assign d_slice = W0_data[BIT_LO +: MACRO_DATA_WIDTH];
            assign bweb_slice = {MACRO_DATA_WIDTH{~write_bank_hit}};
            assign read_copy_rdata[bank_copy][depth_bank][BIT_LO +: MACRO_DATA_WIDTH] =
              macro_q[bank_copy][depth_bank][width_bank];
          end else begin : gen_partial_width_slice
            assign d_slice = {{(MACRO_DATA_WIDTH - USED_BITS){1'b0}}, W0_data[BIT_LO +: USED_BITS]};
            assign bweb_slice = {{(MACRO_DATA_WIDTH - USED_BITS){1'b1}}, {USED_BITS{~write_bank_hit}}};
            assign read_copy_rdata[bank_copy][depth_bank][BIT_LO +: USED_BITS] =
              macro_q[bank_copy][depth_bank][width_bank][USED_BITS-1:0];
          end

          TS1N28HPCPHVTB128X64M4SWBASO u_sram (
            .SLP   (1'b0),
            .SD    (1'b0),
            .CLK   (W0_clk),
            .CEB   (~(read_bank_hit | write_bank_hit)),
            .WEB   (~write_bank_hit),
            .CEBM  (1'b1),
            .WEBM  (1'b1),
            .AWT   (1'b0),
            .A     (macro_addr_muxed),
            .D     (d_slice),
            .BWEB  (bweb_slice),
            .AM    (7'b0),
            .DM    (64'b0),
            .BWEBM ({64{1'b1}}),
            .BIST  (1'b0),
            .Q     (macro_q[bank_copy][depth_bank][width_bank])
          );
        end
      end
    end
  endgenerate

  always @(posedge R0_clk) begin
    ren_d0 <= R0_en;
    rbank_copy_d0 <= same_addr_op ? write_bank_copy_now : read_bank_copy_now;
    rdepth_bank_d0 <= read_depth_bank_sel;
    rbypass_d0 <= same_addr_op;
    rdata_bypass_d0 <= W0_data;
  end

  always @(posedge W0_clk) begin
    if (W0_en) begin
      latest_bank_bits[W0_addr] <= write_bank_copy_now;
    end
  end

  always @* begin
    R0_data = {DATA_WIDTH{1'bx}};
    if (ren_d0) begin
      if (rbypass_d0) begin
        R0_data = rdata_bypass_d0;
      end else begin
        for (int depth_bank = 0; depth_bank < DEPTH_BANKS; depth_bank++) begin
          if (rdepth_bank_d0 == BANK_SEL_WIDTH'(depth_bank)) begin
            R0_data = read_copy_rdata[rbank_copy_d0][depth_bank];
          end
        end
      end
    end
  end
endmodule

module mem_128x128(
  input  [6:0]   RW0_addr,
  input          RW0_en,
                 RW0_clk,
                 RW0_wmode,
  input  [127:0] RW0_wdata,
  output [127:0] RW0_rdata,
  input  [15:0]  RW0_wmask
);
  logic [127:0] RW0_wbiten;

  always @* begin
    RW0_wbiten = '0;
    for (int byte_index = 0; byte_index < 16; byte_index++) begin
      RW0_wbiten[byte_index * 8 +: 8] = {8{RW0_wmask[byte_index]}};
    end
  end

  bb_power_ts1n28_1rw_array #(
    .ADDR_WIDTH(7),
    .DEPTH(128),
    .DATA_WIDTH(128)
  ) u_mem_128x128 (
    .RW0_addr(RW0_addr),
    .RW0_en(RW0_en),
    .RW0_clk(RW0_clk),
    .RW0_wmode(RW0_wmode),
    .RW0_wdata(RW0_wdata),
    .RW0_rdata(RW0_rdata),
    .RW0_wbiten(RW0_wbiten)
  );
endmodule

module mem_8192x64(
  input  [12:0] RW0_addr,
  input         RW0_en,
                RW0_clk,
                RW0_wmode,
  input  [63:0] RW0_wdata,
  output [63:0] RW0_rdata,
  input  [7:0]  RW0_wmask
);
  logic [63:0] RW0_wbiten;

  always @* begin
    RW0_wbiten = '0;
    for (int byte_index = 0; byte_index < 8; byte_index++) begin
      RW0_wbiten[byte_index * 8 +: 8] = {8{RW0_wmask[byte_index]}};
    end
  end

  bb_power_ts1n28_1rw_array #(
    .ADDR_WIDTH(13),
    .DEPTH(8192),
    .DATA_WIDTH(64)
  ) u_mem_8192x64 (
    .RW0_addr(RW0_addr),
    .RW0_en(RW0_en),
    .RW0_clk(RW0_clk),
    .RW0_wmode(RW0_wmode),
    .RW0_wdata(RW0_wdata),
    .RW0_rdata(RW0_rdata),
    .RW0_wbiten(RW0_wbiten)
  );
endmodule

module cc_banks_8192x64(
  input  [12:0] RW0_addr,
  input         RW0_en,
                RW0_clk,
                RW0_wmode,
  input  [63:0] RW0_wdata,
  output [63:0] RW0_rdata
);
  bb_power_ts1n28_1rw_array #(
    .ADDR_WIDTH(13),
    .DEPTH(8192),
    .DATA_WIDTH(64)
  ) u_cc_banks_8192x64 (
    .RW0_addr(RW0_addr),
    .RW0_en(RW0_en),
    .RW0_clk(RW0_clk),
    .RW0_wmode(RW0_wmode),
    .RW0_wdata(RW0_wdata),
    .RW0_rdata(RW0_rdata),
    .RW0_wbiten({64{1'b1}})
  );
endmodule

module bbtile_icache_data_arrays_256x256(
  input  [7:0]   RW0_addr,
  input          RW0_en,
                 RW0_clk,
                 RW0_wmode,
  input  [255:0] RW0_wdata,
  output [255:0] RW0_rdata,
  input  [7:0]   RW0_wmask
);
  logic [255:0] RW0_wbiten;

  always @* begin
    RW0_wbiten = '0;
    for (int chunk_index = 0; chunk_index < 8; chunk_index++) begin
      RW0_wbiten[chunk_index * 32 +: 32] = {32{RW0_wmask[chunk_index]}};
    end
  end

  bb_power_ts1n28_1rw_array #(
    .ADDR_WIDTH(8),
    .DEPTH(256),
    .DATA_WIDTH(256)
  ) u_bbtile_icache_data_arrays_256x256 (
    .RW0_addr(RW0_addr),
    .RW0_en(RW0_en),
    .RW0_clk(RW0_clk),
    .RW0_wmode(RW0_wmode),
    .RW0_wdata(RW0_wdata),
    .RW0_rdata(RW0_rdata),
    .RW0_wbiten(RW0_wbiten)
  );
endmodule

module bbtile_icache_tag_array_64x168(
  input  [5:0]   RW0_addr,
  input          RW0_en,
                 RW0_clk,
                 RW0_wmode,
  input  [167:0] RW0_wdata,
  output [167:0] RW0_rdata,
  input  [7:0]   RW0_wmask
);
  logic [167:0] RW0_wbiten;

  always @* begin
    RW0_wbiten = '0;
    for (int chunk_index = 0; chunk_index < 8; chunk_index++) begin
      RW0_wbiten[chunk_index * 21 +: 21] = {21{RW0_wmask[chunk_index]}};
    end
  end

  bb_power_ts1n28_1rw_array #(
    .ADDR_WIDTH(6),
    .DEPTH(64),
    .DATA_WIDTH(168)
  ) u_bbtile_icache_tag_array_64x168 (
    .RW0_addr(RW0_addr),
    .RW0_en(RW0_en),
    .RW0_clk(RW0_clk),
    .RW0_wmode(RW0_wmode),
    .RW0_wdata(RW0_wdata),
    .RW0_rdata(RW0_rdata),
    .RW0_wbiten(RW0_wbiten)
  );
endmodule

module bbtile_dcache_data_arrays_256x512(
  input  [7:0]   RW0_addr,
  input          RW0_en,
                 RW0_clk,
                 RW0_wmode,
  input  [511:0] RW0_wdata,
  output [511:0] RW0_rdata,
  input  [63:0]  RW0_wmask
);
  logic [511:0] RW0_wbiten;

  always @* begin
    RW0_wbiten = '0;
    for (int byte_index = 0; byte_index < 64; byte_index++) begin
      RW0_wbiten[byte_index * 8 +: 8] = {8{RW0_wmask[byte_index]}};
    end
  end

  bb_power_ts1n28_1rw_array #(
    .ADDR_WIDTH(8),
    .DEPTH(256),
    .DATA_WIDTH(512)
  ) u_bbtile_dcache_data_arrays_256x512 (
    .RW0_addr(RW0_addr),
    .RW0_en(RW0_en),
    .RW0_clk(RW0_clk),
    .RW0_wmode(RW0_wmode),
    .RW0_wdata(RW0_wdata),
    .RW0_rdata(RW0_rdata),
    .RW0_wbiten(RW0_wbiten)
  );
endmodule

module bbtile_dcache_tag_array_64x176(
  input  [5:0]   RW0_addr,
  input          RW0_en,
                 RW0_clk,
                 RW0_wmode,
  input  [175:0] RW0_wdata,
  output [175:0] RW0_rdata,
  input  [7:0]   RW0_wmask
);
  logic [175:0] RW0_wbiten;

  always @* begin
    RW0_wbiten = '0;
    for (int chunk_index = 0; chunk_index < 8; chunk_index++) begin
      RW0_wbiten[chunk_index * 22 +: 22] = {22{RW0_wmask[chunk_index]}};
    end
  end

  bb_power_ts1n28_1rw_array #(
    .ADDR_WIDTH(6),
    .DEPTH(64),
    .DATA_WIDTH(176)
  ) u_bbtile_dcache_tag_array_64x176 (
    .RW0_addr(RW0_addr),
    .RW0_en(RW0_en),
    .RW0_clk(RW0_clk),
    .RW0_wmode(RW0_wmode),
    .RW0_wdata(RW0_wdata),
    .RW0_rdata(RW0_rdata),
    .RW0_wbiten(RW0_wbiten)
  );
endmodule

module cc_dir_1024x136(
  input  [9:0]   RW0_addr,
  input          RW0_en,
                 RW0_clk,
                 RW0_wmode,
  input  [135:0] RW0_wdata,
  output [135:0] RW0_rdata,
  input  [7:0]   RW0_wmask
);
  logic [135:0] RW0_wbiten;

  always @* begin
    RW0_wbiten = '0;
    for (int chunk_index = 0; chunk_index < 8; chunk_index++) begin
      RW0_wbiten[chunk_index * 17 +: 17] = {17{RW0_wmask[chunk_index]}};
    end
  end

  bb_power_ts1n28_1rw_array #(
    .ADDR_WIDTH(10),
    .DEPTH(1024),
    .DATA_WIDTH(136)
  ) u_cc_dir_1024x136 (
    .RW0_addr(RW0_addr),
    .RW0_en(RW0_en),
    .RW0_clk(RW0_clk),
    .RW0_wmode(RW0_wmode),
    .RW0_wdata(RW0_wdata),
    .RW0_rdata(RW0_rdata),
    .RW0_wbiten(RW0_wbiten)
  );
endmodule

module sram_64x1144(
  input  [5:0]    R0_addr,
  input           R0_en,
                  R0_clk,
  output [1143:0] R0_data,
  input  [5:0]    W0_addr,
  input           W0_en,
                  W0_clk,
  input  [1143:0] W0_data
);
  bb_power_ts1n28_1r1w_array #(
    .ADDR_WIDTH(6),
    .DEPTH(64),
    .DATA_WIDTH(1144)
  ) u_sram_64x1144 (
    .R0_addr(R0_addr),
    .R0_en(R0_en),
    .R0_clk(R0_clk),
    .R0_data(R0_data),
    .W0_addr(W0_addr),
    .W0_en(W0_en),
    .W0_clk(W0_clk),
    .W0_data(W0_data)
  );
endmodule
