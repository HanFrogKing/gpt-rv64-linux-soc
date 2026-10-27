// Buffered physical AXI4 manager. One whole transaction at a time, ID=0.
// Buffer word 0 is the first beat; narrow accesses retain AXI byte lanes.
// Common master/fabric reset only. No timeout, cancellation or write rollback.
module rv64_axi_transfer #(
  parameter integer MAX_BEATS=4 // Supported configurations: 1, 2, 4, 8, 16.
) (
  input logic clk_i, aresetn_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input logic req_write_i, req_lock_i,
  input logic [63:0] req_addr_i,
  input logic [2:0] req_size_i, req_prot_i,
  input logic [7:0] req_len_i,
  input logic [3:0] req_cache_i,
  input logic [MAX_BEATS*64-1:0] req_wdata_i,
  input logic [MAX_BEATS*8-1:0] req_wstrb_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output logic [MAX_BEATS*64-1:0] rsp_data_o,
  output logic [1:0] rsp_resp_o,
  output logic rsp_error_o, fatal_o,
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
  localparam logic [2:0] IDLE=0, AR=1, R=2, W=3, B=4, RESP=5;
  localparam integer BEAT_W=(MAX_BEATS>1) ? $clog2(MAX_BEATS) : 1;
  logic [2:0] state_q;
  logic [BEAT_W-1:0] beat_q;
  logic [63:0] addr_q;
  logic [7:0] len_q;
  logic [2:0] size_q, prot_q;
  logic [3:0] cache_q;
  logic lock_q, aw_pending_q, w_done_q, fatal_q;
  logic [MAX_BEATS*64-1:0] wdata_q, data_q;
  logic [MAX_BEATS*8-1:0] wstrb_q;
  logic [1:0] resp_q;
  logic invalid_req;
  logic [16:0] req_bytes;
  logic [64:0] req_end;
  logic [7:0] lane_mask;
  wire req_fire=req_valid_i && req_ready_o;
  wire ar_fire=m_axi_arvalid_o && m_axi_arready_i;
  wire r_fire=m_axi_rvalid_i && m_axi_rready_o;
  wire aw_fire=m_axi_awvalid_o && m_axi_awready_i;
  wire w_fire=m_axi_wvalid_o && m_axi_wready_i;
  wire b_fire=m_axi_bvalid_i && m_axi_bready_o;
  wire last_beat=8'(beat_q)==len_q;
  wire unused_end_offset=^req_end[11:0];
  if(MAX_BEATS!=1 && MAX_BEATS!=2 && MAX_BEATS!=4 && MAX_BEATS!=8 && MAX_BEATS!=16) begin : bad_config
    initial $fatal(1,"MAX_BEATS must be 1, 2, 4, 8 or 16");
  end
  always_comb begin
    req_bytes=({9'b0,req_len_i}+17'd1)<<req_size_i;
    req_end={1'b0,req_addr_i}+{48'b0,req_bytes}-65'd1;
    lane_mask=8'((9'd1<<(1<<req_size_i))-9'd1)<<req_addr_i[2:0];
    invalid_req=req_size_i>3 || int'(req_len_i)>=MAX_BEATS ||
      (req_addr_i & ((64'd1<<req_size_i)-64'd1))!=0 ||
      (req_len_i!=0 && req_size_i!=3) || req_end[64] ||
      req_end[63:12]!=req_addr_i[63:12] ||
      (req_lock_i && (req_len_i!=0 || (req_size_i!=2 && req_size_i!=3)));
    for(integer i=0;i<MAX_BEATS;i=i+1)
      if(req_write_i && i<=int'(req_len_i) && |(req_wstrb_i[i*8+:8] & ~lane_mask))
        invalid_req=1;
  end
  assign req_ready_o=aresetn_i && state_q==IDLE && !fatal_q;
  assign rsp_valid_o=aresetn_i && state_q==RESP;
  assign rsp_resp_o=resp_q;
  assign rsp_error_o=resp_q[1];
  assign rsp_data_o=resp_q[1] ? '0 : data_q;
  assign fatal_o=aresetn_i && fatal_q;
  assign m_axi_arvalid_o=aresetn_i && state_q==AR;
  assign m_axi_rready_o=aresetn_i && state_q==R;
  assign m_axi_awvalid_o=aresetn_i && state_q==W && aw_pending_q;
  assign m_axi_wvalid_o=aresetn_i && state_q==W && !w_done_q;
  assign m_axi_bready_o=aresetn_i && state_q==B;
  assign m_axi_arid_o=0;assign m_axi_awid_o=0;
  assign m_axi_araddr_o=addr_q;assign m_axi_awaddr_o=addr_q;
  assign m_axi_arlen_o=len_q;assign m_axi_awlen_o=len_q;
  assign m_axi_arsize_o=size_q;assign m_axi_awsize_o=size_q;
  assign m_axi_arprot_o=prot_q;assign m_axi_awprot_o=prot_q;
  assign m_axi_arcache_o=cache_q;assign m_axi_awcache_o=cache_q;
  assign m_axi_arburst_o=2'b01;assign m_axi_awburst_o=2'b01;
  assign m_axi_arlock_o=lock_q;assign m_axi_awlock_o=lock_q;
  assign m_axi_wdata_o=wdata_q[int'(beat_q)*64+:64];
  assign m_axi_wstrb_o=wstrb_q[int'(beat_q)*8+:8];
  assign m_axi_wlast_o=last_beat;
  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin
      state_q<=IDLE;beat_q<=0;addr_q<=0;len_q<=0;size_q<=0;prot_q<=0;cache_q<=0;
      lock_q<=0;aw_pending_q<=0;w_done_q<=0;fatal_q<=0;
      wdata_q<=0;wstrb_q<=0;data_q<=0;resp_q<=0;
    end else begin
      case(state_q)
        IDLE: if(req_fire) begin
          addr_q<=req_addr_i;len_q<=req_len_i;size_q<=req_size_i;
          prot_q<=req_prot_i;cache_q<=req_cache_i;lock_q<=req_lock_i;
          wdata_q<=req_wdata_i;wstrb_q<=req_wstrb_i;data_q<=0;beat_q<=0;
          resp_q<=invalid_req ? 2'b11 : 2'b00;
          aw_pending_q<=req_write_i;w_done_q<=0;
          state_q<=invalid_req ? RESP : (req_write_i ? W : AR);
        end
        AR: if(ar_fire) state_q<=R;
        R: if(r_fire) begin
          data_q[int'(beat_q)*64+:64]<=m_axi_rdata_i;
          if(m_axi_rresp_i>resp_q) resp_q<=m_axi_rresp_i;
          if(m_axi_rid_i || m_axi_rlast_i!=last_beat || (!lock_q && m_axi_rresp_i==1)) begin
            fatal_q<=1;resp_q<=3;state_q<=RESP;
          end else if(last_beat) state_q<=RESP;
          else beat_q<=beat_q+1'b1;
        end
        W: begin
          if(aw_fire) aw_pending_q<=0;
          if(w_fire) begin
            if(last_beat) w_done_q<=1;
            else beat_q<=beat_q+1'b1;
          end
          if((!aw_pending_q || aw_fire) && (w_done_q || (w_fire && last_beat))) state_q<=B;
        end
        B: if(b_fire) begin
          resp_q<=m_axi_bresp_i;
          if(m_axi_bid_i || (!lock_q && m_axi_bresp_i==1)) begin fatal_q<=1;resp_q<=3;end
          state_q<=RESP;
        end
        RESP: if(rsp_ready_i) state_q<=IDLE;
        default: begin fatal_q<=1;resp_q<=3;state_q<=RESP;end
      endcase
    end
  end
`ifdef RV64_TRANSFER_FORMAL
  `include "formal/rv64/axi_transfer_properties.svh"
`endif
endmodule
