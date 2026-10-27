// R27: four asynchronous reads, two ordered committed writes.
// w0 is older, w1 is younger: w1 wins a same-address collision.
// No combinational write-through. Data banks are not reset.
module rv64_dual_regfile (
  input logic clk_i, rst_i,
  input logic we0_i, we1_i,
  input logic [4:0] waddr0_i, waddr1_i,
  input logic [63:0] wdata0_i, wdata1_i,
  input logic [4:0] raddr0_i, raddr1_i, raddr2_i, raddr3_i,
  output logic [63:0] rdata0_o, rdata1_o, rdata2_o, rdata3_o
);
  // Each bank has exactly one physical write port. A per-register live-value
  // bit selects the bank containing the most recent architectural write.
  logic [63:0] bank0_q [1:31];
  logic [63:0] bank1_q [1:31];
  logic [31:1] valid_q, owner_q;
  always_ff @(posedge clk_i) begin
    if (!rst_i && we0_i && waddr0_i != 0) bank0_q[waddr0_i] <= wdata0_i;
    if (!rst_i && we1_i && waddr1_i != 0) bank1_q[waddr1_i] <= wdata1_i;
  end
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      valid_q <= '0;
      owner_q <= '0;
    end else begin
      if (we0_i && waddr0_i != 0) begin
        valid_q[waddr0_i] <= 1'b1;
        owner_q[waddr0_i] <= 1'b0;
      end
      if (we1_i && waddr1_i != 0) begin
        valid_q[waddr1_i] <= 1'b1;
        owner_q[waddr1_i] <= 1'b1;
      end
    end
  end
  function automatic logic [63:0] read_arch(input logic [4:0] addr);
    read_arch = 64'b0;
    if (addr != 0 && valid_q[addr])
      read_arch = owner_q[addr] ? bank1_q[addr] : bank0_q[addr];
  endfunction
  always_comb begin
    rdata0_o = read_arch(raddr0_i);
    rdata1_o = read_arch(raddr1_i);
    rdata2_o = read_arch(raddr2_i);
    rdata3_o = read_arch(raddr3_i);
  end
`ifdef RV64_DUAL_RF_FORMAL
  `include "formal/rv64/dual_regfile_properties.svh"
`endif
endmodule
