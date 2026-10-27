// R32: 64-bit instruction bypass, four-beat 32-byte I/D lines.
// New module; preserves the original D-cache burst/writeback/lock/PTW contract.
// Owner and full payload remain registered until the selected response is used.
module rv64_dual_cache_arbiter #(parameter bit ENABLE_I_LINE=1) (
  input logic clk_i, aresetn_i,
  input logic i_req_valid_i,
  output logic i_req_ready_o,
  input logic [63:0] i_req_addr_i,
  input logic [2:0] i_req_prot_i,
  input logic i_req_line_i,
  output logic i_rsp_valid_o,
  input logic i_rsp_ready_i,
  output logic [255:0] i_rsp_data_o,
  output logic [1:0] i_rsp_resp_o,
  output logic i_rsp_error_o,
  input logic d_req_valid_i,
  output logic d_req_ready_o,
  input logic d_req_write_i, d_req_lock_i, d_req_ptw_i,
  input logic [63:0] d_req_addr_i,
  input logic [2:0] d_req_size_i, d_req_prot_i,
  input logic [7:0] d_req_len_i,
  input logic [3:0] d_req_cache_i,
  input logic [255:0] d_req_wdata_i,
  input logic [31:0] d_req_wstrb_i,
  output logic d_rsp_valid_o,
  input logic d_rsp_ready_i,
  output logic [255:0] d_rsp_data_o,
  output logic [1:0] d_rsp_resp_o,
  output logic d_rsp_error_o,
  output logic bus_ptw_o, fatal_o,
  output logic [31:0] stat_i_req_o, stat_d_req_o, stat_error_o,
  output logic [31:0] stat_i_wait_o, stat_d_wait_o,
  output logic m_axi_arvalid_o,
  input logic m_axi_arready_i,
  output logic m_axi_arid_o,
  output logic [63:0] m_axi_araddr_o,
  output logic [7:0] m_axi_arlen_o,
  output logic [2:0] m_axi_arsize_o, m_axi_arprot_o,
  output logic [1:0] m_axi_arburst_o,
  output logic m_axi_arlock_o,
  output logic [3:0] m_axi_arcache_o,
  input logic m_axi_rvalid_i,
  output logic m_axi_rready_o,
  input logic m_axi_rid_i, m_axi_rlast_i,
  input logic [63:0] m_axi_rdata_i,
  input logic [1:0] m_axi_rresp_i,
  output logic m_axi_awvalid_o,
  input logic m_axi_awready_i,
  output logic m_axi_awid_o,
  output logic [63:0] m_axi_awaddr_o,
  output logic [7:0] m_axi_awlen_o,
  output logic [2:0] m_axi_awsize_o, m_axi_awprot_o,
  output logic [1:0] m_axi_awburst_o,
  output logic m_axi_awlock_o,
  output logic [3:0] m_axi_awcache_o,
  output logic m_axi_wvalid_o,
  input logic m_axi_wready_i,
  output logic [63:0] m_axi_wdata_o,
  output logic [7:0] m_axi_wstrb_o,
  output logic m_axi_wlast_o,
  input logic m_axi_bvalid_i,
  output logic m_axi_bready_o,
  input logic m_axi_bid_i,
  input logic [1:0] m_axi_bresp_i
);
  localparam logic [1:0] IDLE=0,OFFER=1,WAIT_RSP=2;
  logic [1:0] state_q;
  logic owner_d_q,prefer_d_q;
  logic write_q,lock_q,ptw_q;
  logic [63:0] addr_q;
  logic [2:0] size_q,prot_q;
  logic [7:0] len_q;
  logic [3:0] cache_q;
  logic [255:0] wdata_q;
  logic [31:0] wstrb_q;
  wire idle=aresetn_i && state_q==IDLE && !fatal_o;
  wire take_i=i_req_valid_i && i_req_ready_o;
  wire take_d=d_req_valid_i && d_req_ready_o;
  wire transfer_ready,transfer_valid,transfer_error;
  wire [255:0] transfer_data;
  wire [1:0] transfer_resp;
  wire transfer_request=aresetn_i && state_q==OFFER;
  wire response_ready=aresetn_i && state_q==WAIT_RSP && (owner_d_q ? d_rsp_ready_i : i_rsp_ready_i);
  wire response_fire=transfer_valid && response_ready;
  assign i_req_ready_o=idle && (!d_req_valid_i || !prefer_d_q);
  assign d_req_ready_o=idle && (!i_req_valid_i || prefer_d_q);
  assign i_rsp_valid_o=aresetn_i && state_q==WAIT_RSP && !owner_d_q && transfer_valid;
  assign d_rsp_valid_o=aresetn_i && state_q==WAIT_RSP && owner_d_q && transfer_valid;
  assign i_rsp_data_o=transfer_data;
  assign d_rsp_data_o=transfer_data;
  assign i_rsp_resp_o=transfer_resp;
  assign d_rsp_resp_o=transfer_resp;
  assign i_rsp_error_o=transfer_error;
  assign d_rsp_error_o=transfer_error;
  assign bus_ptw_o=aresetn_i && state_q!=IDLE && owner_d_q && ptw_q;
  always_ff @(posedge clk_i) begin
    if(!aresetn_i) begin
      state_q<=IDLE;owner_d_q<=0;prefer_d_q<=0;write_q<=0;lock_q<=0;ptw_q<=0;
      addr_q<=0;size_q<=0;prot_q<=0;len_q<=0;cache_q<=0;wdata_q<=0;wstrb_q<=0;
      stat_i_req_o<=0;stat_d_req_o<=0;stat_error_o<=0;stat_i_wait_o<=0;stat_d_wait_o<=0;
    end else begin
      if(i_req_valid_i && !i_req_ready_o) stat_i_wait_o<=stat_i_wait_o+1'b1;
      if(d_req_valid_i && !d_req_ready_o) stat_d_wait_o<=stat_d_wait_o+1'b1;
      case(state_q)
        IDLE: begin
          if(take_i) begin
            owner_d_q<=0;prefer_d_q<=1;write_q<=0;lock_q<=0;ptw_q<=0;
            addr_q<=i_req_addr_i;prot_q<=i_req_prot_i;len_q<=i_req_line_i ? 8'd3 : 8'd0;
            size_q<=i_req_line_i ? ((!ENABLE_I_LINE || |i_req_addr_i[4:0]) ? 3'd7 : 3'd3) : 3'd3;
            cache_q<=0;wdata_q<=0;wstrb_q<=0;state_q<=OFFER;stat_i_req_o<=stat_i_req_o+1'b1;
          end
          if(take_d) begin
            owner_d_q<=1;prefer_d_q<=0;write_q<=d_req_write_i;lock_q<=d_req_lock_i;ptw_q<=d_req_ptw_i;
            addr_q<=d_req_addr_i;prot_q<=d_req_prot_i;size_q<=d_req_size_i;
            len_q<=d_req_len_i;cache_q<=d_req_cache_i;wdata_q<=d_req_wdata_i;wstrb_q<=d_req_wstrb_i;
            state_q<=OFFER;stat_d_req_o<=stat_d_req_o+1'b1;
          end
        end
        OFFER: if(transfer_ready) state_q<=WAIT_RSP;
        WAIT_RSP: if(response_fire) begin
          state_q<=IDLE;if(transfer_error) stat_error_o<=stat_error_o+1'b1;
        end
        default: state_q<=IDLE;
      endcase
    end
  end
  rv64_axi_transfer #(.MAX_BEATS(4)) transfer (
    .clk_i(clk_i),.aresetn_i(aresetn_i),.req_valid_i(transfer_request),.req_ready_o(transfer_ready),
    .req_write_i(write_q),.req_lock_i(lock_q),.req_addr_i(addr_q),.req_size_i(size_q),.req_prot_i(prot_q),
    .req_len_i(len_q),.req_cache_i(cache_q),.req_wdata_i(wdata_q),.req_wstrb_i(wstrb_q),
    .rsp_valid_o(transfer_valid),.rsp_ready_i(response_ready),.rsp_data_o(transfer_data),
    .rsp_resp_o(transfer_resp),.rsp_error_o(transfer_error),.fatal_o(fatal_o),
    .m_axi_arvalid_o(m_axi_arvalid_o),
    .m_axi_arready_i(m_axi_arready_i),
    .m_axi_arid_o(m_axi_arid_o),
    .m_axi_araddr_o(m_axi_araddr_o),
    .m_axi_arlen_o(m_axi_arlen_o),
    .m_axi_arsize_o(m_axi_arsize_o),
    .m_axi_arprot_o(m_axi_arprot_o),
    .m_axi_arburst_o(m_axi_arburst_o),
    .m_axi_arlock_o(m_axi_arlock_o),
    .m_axi_arcache_o(m_axi_arcache_o),
    .m_axi_rvalid_i(m_axi_rvalid_i),
    .m_axi_rready_o(m_axi_rready_o),
    .m_axi_rid_i(m_axi_rid_i),
    .m_axi_rlast_i(m_axi_rlast_i),
    .m_axi_rdata_i(m_axi_rdata_i),
    .m_axi_rresp_i(m_axi_rresp_i),
    .m_axi_awvalid_o(m_axi_awvalid_o),
    .m_axi_awready_i(m_axi_awready_i),
    .m_axi_awid_o(m_axi_awid_o),
    .m_axi_awaddr_o(m_axi_awaddr_o),
    .m_axi_awlen_o(m_axi_awlen_o),
    .m_axi_awsize_o(m_axi_awsize_o),
    .m_axi_awprot_o(m_axi_awprot_o),
    .m_axi_awburst_o(m_axi_awburst_o),
    .m_axi_awlock_o(m_axi_awlock_o),
    .m_axi_awcache_o(m_axi_awcache_o),
    .m_axi_wvalid_o(m_axi_wvalid_o),
    .m_axi_wready_i(m_axi_wready_i),
    .m_axi_wdata_o(m_axi_wdata_o),
    .m_axi_wstrb_o(m_axi_wstrb_o),
    .m_axi_wlast_o(m_axi_wlast_o),
    .m_axi_bvalid_i(m_axi_bvalid_i),
    .m_axi_bready_o(m_axi_bready_o),
    .m_axi_bid_i(m_axi_bid_i),
    .m_axi_bresp_i(m_axi_bresp_i)
  );
`ifdef RV64_DUAL_CACHE_ARBITER_FORMAL
  `include "formal/rv64/dual_cache_arbiter_properties.svh"
`endif
endmodule
