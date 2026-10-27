// R28: physical 64-bit fetch blocks, 4 KiB direct mapped / 32-byte lines.
// The caller translates and checks execute permission before every request.
// Requests must be 8-byte aligned: a block never straddles a 4 KiB page.
// One synchronous lookup plus one elastic response: hits sustain one block/clk.
// Backend contract: 256-bit line OR a full 64-bit single-beat bypass response.
// The historical ifill uses ARSIZE=2 for bypass and needs a separate upgrade
// before integration; its 32-bit bypass must NOT be wired here unchanged.
module rv64_dual_icache #(
  parameter bit ENABLE=1,
  parameter logic [63:0] RAM_BASE=64'h80000000,
  parameter logic [63:0] RAM_BYTES=64'h08000000
) (
  input logic clk_i, aresetn_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input logic [63:0] req_addr_i,
  input logic [2:0] req_prot_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output logic [63:0] rsp_data_o,
  output logic [1:0] rsp_resp_o,
  input logic inv_valid_i,
  output logic inv_ready_o, inv_done_o,
  input logic inv_ack_i,
  output logic mem_arvalid_o,
  input logic mem_arready_i,
  output logic [63:0] mem_araddr_o,
  output logic [2:0] mem_arprot_o,
  output logic mem_arline_o,
  input logic mem_rvalid_i,
  output logic mem_rready_o,
  input logic [255:0] mem_rline_i,
  input logic [1:0] mem_rresp_i,
  output logic fatal_o,
  output logic [31:0] stat_req_o, stat_hit_o, stat_miss_o,
  output logic [31:0] stat_refill_o, stat_bypass_o, stat_inv_o, stat_error_o
);
  localparam logic [2:0] RUN=0, MEM_REQ=1, MEM_WAIT=2, FILL=3, INSTALL=4, RETURN=5;
  logic [2:0] state_q;
  logic [127:0] valid_q;
  logic [63:0] data_ram [0:511];
  logic [51:0] tag_ram [0:127];
  logic [63:0] read_data_q;
  logic [51:0] read_tag_q;
  logic lookup_valid_q, aligned_q, cacheable_q;
  logic [63:0] addr_q;
  logic [2:0] prot_q;
  logic line_q, inv_done_q, fatal_q, rsp_valid_q;
  logic [255:0] fill_q;
  logic [1:0] fill_word_q, pending_resp_q, rsp_resp_q;
  logic [63:0] pending_data_q, rsp_data_q;
  wire [63:0] offered_line={req_addr_i[63:5],5'b0};
  wire offered_aligned=req_addr_i[2:0]==0;
  wire offered_cacheable=ENABLE && RAM_BYTES>=32 && offered_line>=RAM_BASE &&
    (offered_line-RAM_BASE)<=RAM_BYTES-64'd32;
  wire [6:0] index_q=addr_q[11:5];
  wire hit=cacheable_q && valid_q[index_q] && read_tag_q==addr_q[63:12];
  wire rsp_space=!rsp_valid_q || rsp_ready_i;
  wire lookup_emit=lookup_valid_q && (!aligned_q || hit) && rsp_space;
  wire lookup_miss=lookup_valid_q && aligned_q && !hit;
  wire req_fire=req_valid_i && req_ready_o;
  wire inv_fire=inv_valid_i && inv_ready_o;
  wire mem_req_fire=mem_arvalid_o && mem_arready_i;
  wire mem_rsp_fire=mem_rvalid_i && mem_rready_o;
  wire ram_read=req_fire && offered_aligned && offered_cacheable;
  wire ram_write=aresetn_i && state_q==FILL;
  wire tag_write=aresetn_i && state_q==INSTALL;

  assign req_ready_o=aresetn_i && !fatal_q && state_q==RUN && !inv_done_q &&
    !inv_valid_i && (!lookup_valid_q || lookup_emit);
  assign rsp_valid_o=aresetn_i && rsp_valid_q;
  assign rsp_data_o=rsp_data_q;
  assign rsp_resp_o=rsp_resp_q;
  assign inv_ready_o=aresetn_i && !fatal_q && state_q==RUN &&
    !lookup_valid_q && !rsp_valid_q && !inv_done_q;
  assign inv_done_o=aresetn_i && inv_done_q;
  assign mem_arvalid_o=aresetn_i && state_q==MEM_REQ;
  assign mem_araddr_o=line_q ? {addr_q[63:5],5'b0} : addr_q;
  assign mem_arprot_o=prot_q;
  assign mem_arline_o=line_q;
  assign mem_rready_o=aresetn_i && state_q==MEM_WAIT;
  assign fatal_o=aresetn_i && fatal_q;

  always_ff @(posedge clk_i) begin
    if(ram_read) begin
      read_data_q<=data_ram[req_addr_i[11:3]];
      read_tag_q<=tag_ram[req_addr_i[11:5]];
    end
    if(ram_write) data_ram[{index_q,fill_word_q}]<=fill_q[int'(fill_word_q)*64+:64];
    if(tag_write) tag_ram[index_q]<=addr_q[63:12];
  end
  always_ff @(posedge clk_i) begin
    if(!aresetn_i) begin
      state_q<=RUN;valid_q<=0;lookup_valid_q<=0;aligned_q<=0;cacheable_q<=0;
      addr_q<=0;prot_q<=0;line_q<=0;inv_done_q<=0;fatal_q<=0;
      rsp_valid_q<=0;fill_q<=0;fill_word_q<=0;pending_resp_q<=0;
      pending_data_q<=0;rsp_data_q<=0;rsp_resp_q<=0;
      stat_req_o<=0;stat_hit_o<=0;stat_miss_o<=0;stat_refill_o<=0;
      stat_bypass_o<=0;stat_inv_o<=0;stat_error_o<=0;
    end else begin
      if(rsp_valid_q && rsp_ready_i) rsp_valid_q<=0;
      if(inv_done_q && inv_ack_i) inv_done_q<=0;
      case(state_q)
        RUN: begin
          if(inv_fire) begin valid_q<=0;inv_done_q<=1;stat_inv_o<=stat_inv_o+1'b1;end
          if(lookup_emit) begin
            lookup_valid_q<=0;rsp_valid_q<=1;
            rsp_data_q<=aligned_q ? read_data_q : 64'd0;
            rsp_resp_q<=aligned_q ? 2'd0 : 2'd3;
            if(aligned_q) stat_hit_o<=stat_hit_o+1'b1;
          end
          if(lookup_miss) begin
            lookup_valid_q<=0;line_q<=cacheable_q;state_q<=MEM_REQ;
            if(cacheable_q) begin valid_q[index_q]<=0;stat_miss_o<=stat_miss_o+1'b1;end
            else stat_bypass_o<=stat_bypass_o+1'b1;
          end
          if(req_fire) begin
            lookup_valid_q<=1;addr_q<=req_addr_i;prot_q<=req_prot_i;
            aligned_q<=offered_aligned;cacheable_q<=offered_cacheable;
            stat_req_o<=stat_req_o+1'b1;
            if(!offered_aligned) stat_error_o<=stat_error_o+1'b1;
          end
        end
        MEM_REQ: if(mem_req_fire) state_q<=MEM_WAIT;
        MEM_WAIT: if(mem_rsp_fire) begin
          if(mem_rresp_i!=0) begin
            pending_data_q<=0;pending_resp_q<=mem_rresp_i==1 ? 2'd3 : mem_rresp_i;
            fatal_q<=mem_rresp_i==1;stat_error_o<=stat_error_o+1'b1;state_q<=RETURN;
          end else if(line_q) begin
            fill_q<=mem_rline_i;fill_word_q<=0;state_q<=FILL;
          end else begin
            pending_data_q<=mem_rline_i[63:0];pending_resp_q<=0;state_q<=RETURN;
          end
        end
        FILL: begin
          if(fill_word_q==3) state_q<=INSTALL;
          else fill_word_q<=fill_word_q+1'b1;
        end
        INSTALL: begin
          valid_q[index_q]<=1;
          pending_data_q<=fill_q[int'(addr_q[4:3])*64+:64];pending_resp_q<=0;
          stat_refill_o<=stat_refill_o+1'b1;state_q<=RETURN;
        end
        RETURN: if(rsp_space) begin
          rsp_valid_q<=1;rsp_data_q<=pending_data_q;rsp_resp_q<=pending_resp_q;state_q<=RUN;
        end
        default: begin fatal_q<=1;lookup_valid_q<=0;state_q<=RUN;end
      endcase
    end
  end
`ifdef RV64_DUAL_ICACHE_FORMAL
  `include "formal/rv64/dual_icache_properties.svh"
`endif
endmodule
