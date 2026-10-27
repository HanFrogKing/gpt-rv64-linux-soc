// R51 isolated LSU: static R-state next-request payload selection.
// R44 isolated candidate: same-edge successful ordinary read response/new read ownership.
// One live transaction; no turnover for stores, exclusives, faults or held responses.
// R64-05: one irrevocable, naturally aligned little-endian access at a time.
// AXI4: 64-bit byte address/data, ID=0, LEN=0, narrow SIZE=0..3.
// Common master+fabric reset only. A store is not completed until B is accepted.
module rv64_lsu #(
  parameter bit ENABLE_EXCLUSIVE=0
) (
  input logic clk_i, aresetn_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input logic req_write_i, req_unsigned_i,
  input logic req_exclusive_i,
  input logic [1:0] req_size_i,
  input logic [63:0] req_addr_i, req_wdata_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output logic [63:0] rsp_data_o, rsp_cause_o, rsp_tval_o,
  output logic rsp_error_o, rsp_exokay_o, fatal_o,
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
  logic [2:0] state_q;
  logic [63:0] addr_q, wdata_q, data_q, cause_q;
  logic [1:0] size_q;
  logic unsigned_q, error_q, fatal_q, aw_pending_q, w_pending_q;
  logic exclusive_q, exokay_q;
  logic [7:0] strb_q;
  logic [63:0] shifted, loaded;
  logic misaligned;
  logic [7:0] byte_mask;
  wire req_fire=req_valid_i && req_ready_o;
  wire launch=aresetn_i && (state_q==IDLE || read_turnover) && !fatal_q && req_valid_i && !misaligned;
  wire launch_read=launch && !req_write_i;
  wire launch_write=launch && req_write_i;
  // R51: present the offered next read address/size throughout R, before
  // the old response arrives. ARVALID still needs the original precise
  // read_turnover guard. Invalid address payload is irrelevant to AXI;
  // accepted requests are captured before an AR stall. Old load extraction
  // still uses addr_q/size_q. Exclusive outputs retain the original contract.
  wire [63:0] channel_addr=(state_q==IDLE || state_q==R) ? req_addr_i : addr_q;
  wire [1:0] channel_size=(state_q==IDLE || state_q==R) ? req_size_i : size_q;
  wire channel_exclusive=(state_q==IDLE || read_turnover) ? (ENABLE_EXCLUSIVE && req_exclusive_i) : exclusive_q;
  // Only well-formed OKAY responses fall through. Faults/EXOKAY retain the
  // original registered response and poison semantics.
  wire fast_r=state_q==R && m_axi_rvalid_i && m_axi_rresp_i==0 && !m_axi_rid_i && m_axi_rlast_i;
  wire fast_b=state_q==B && m_axi_bvalid_i && m_axi_bresp_i==0 && !m_axi_bid_i;
  wire fast_response=fast_r || fast_b;
  wire read_turnover=fast_r && !exclusive_q && rsp_ready_i && !fatal_q &&
    !req_write_i && !(ENABLE_EXCLUSIVE && req_exclusive_i) && !misaligned;
  wire ar_fire=m_axi_arvalid_o && m_axi_arready_i;
  wire r_fire=m_axi_rvalid_i && m_axi_rready_o;
  wire aw_fire=m_axi_awvalid_o && m_axi_awready_i;
  wire w_fire=m_axi_wvalid_o && m_axi_wready_i;
  wire b_fire=m_axi_bvalid_i && m_axi_bready_o;
  always_comb begin
    case(req_size_i)
      0: begin misaligned=0;byte_mask=8'h01; end
      1: begin misaligned=req_addr_i[0];byte_mask=8'h03; end
      2: begin misaligned=|req_addr_i[1:0];byte_mask=8'h0f; end
      3: begin misaligned=|req_addr_i[2:0];byte_mask=8'hff; end
      default: begin misaligned=1;byte_mask=0; end
    endcase
    shifted=m_axi_rdata_i >> {addr_q[2:0],3'b000};
    case(size_q)
      0: loaded={{56{!unsigned_q && shifted[7]}},shifted[7:0]};
      1: loaded={{48{!unsigned_q && shifted[15]}},shifted[15:0]};
      2: loaded={{32{!unsigned_q && shifted[31]}},shifted[31:0]};
      3: loaded=shifted;
      default: loaded=0;
    endcase
  end
  assign req_ready_o=aresetn_i && (state_q==IDLE || read_turnover) && !fatal_q;
  assign rsp_valid_o=aresetn_i && (state_q==RESP || fast_response);
  assign rsp_data_o=fast_r ? loaded : fast_b ? 64'b0 : data_q;
  assign rsp_error_o=fast_response ? 1'b0 : error_q;
  assign rsp_exokay_o=fast_response ? 1'b0 : exokay_q;
  assign rsp_cause_o=fast_response ? 64'b0 : cause_q;
  assign rsp_tval_o=rsp_error_o ? addr_q : 64'b0;
  assign fatal_o=aresetn_i && fatal_q;
  assign m_axi_arvalid_o=aresetn_i && (state_q==AR || launch_read);
  assign m_axi_rready_o=aresetn_i && state_q==R;
  assign m_axi_awvalid_o=aresetn_i && ((state_q==W && aw_pending_q) || launch_write);
  assign m_axi_wvalid_o=aresetn_i && ((state_q==W && w_pending_q) || launch_write);
  assign m_axi_bready_o=aresetn_i && state_q==B;
  assign m_axi_araddr_o=channel_addr;
  assign m_axi_awaddr_o=channel_addr;
  assign m_axi_arsize_o={1'b0,channel_size};
  assign m_axi_awsize_o={1'b0,channel_size};
  assign m_axi_arid_o=0;
  assign m_axi_awid_o=0;
  assign m_axi_arlen_o=0;
  assign m_axi_awlen_o=0;
  assign m_axi_arburst_o=2'b01;
  assign m_axi_awburst_o=2'b01;
  assign m_axi_arlock_o=channel_exclusive;
  assign m_axi_awlock_o=channel_exclusive;
  assign m_axi_arcache_o=0;
  assign m_axi_awcache_o=0;
  assign m_axi_arprot_o=3'b001; // Fixed privileged, secure, DATA attribute.
  assign m_axi_awprot_o=3'b001;
  assign m_axi_wdata_o=state_q==IDLE ? (req_wdata_i << {req_addr_i[2:0],3'b000}) : wdata_q;
  assign m_axi_wstrb_o=state_q==IDLE ? (byte_mask << req_addr_i[2:0]) : strb_q;
  assign m_axi_wlast_o=1;
  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin
      state_q<=IDLE;addr_q<=0;wdata_q<=0;strb_q<=0;size_q<=0;unsigned_q<=0;
      data_q<=0;error_q<=0;cause_q<=0;fatal_q<=0;aw_pending_q<=0;w_pending_q<=0;
      exclusive_q<=0;exokay_q<=0;
    end else begin
      case(state_q)
        IDLE: if(req_fire) begin
          addr_q<=req_addr_i;size_q<=req_size_i;unsigned_q<=req_unsigned_i;
          exclusive_q<=ENABLE_EXCLUSIVE && req_exclusive_i;exokay_q<=0;
          wdata_q<=req_wdata_i << {req_addr_i[2:0],3'b000};
          strb_q<=byte_mask << req_addr_i[2:0];
          data_q<=0;error_q<=misaligned;
          cause_q<=misaligned ? (req_write_i ? 64'd6 : 64'd4) : 64'd0;
          aw_pending_q<=req_write_i && !aw_fire;w_pending_q<=req_write_i && !w_fire;
          state_q<=misaligned ? RESP : req_write_i ? ((aw_fire && w_fire) ? B : W) : (ar_fire ? R : AR);
        end
        AR: if(ar_fire) state_q<=R;
        R: if(r_fire) begin
          // A malformed ID/LAST or exclusive response is a platform fault.
          // Never reuse this channel without a common reset after it occurs.
          if(exclusive_q) begin
            fatal_q<=m_axi_rid_i || !m_axi_rlast_i;
            error_q<=m_axi_rresp_i[1] || m_axi_rid_i || !m_axi_rlast_i;
            cause_q<=(m_axi_rresp_i[1] || m_axi_rid_i || !m_axi_rlast_i) ? 64'd5 : 64'd0;
            data_q<=(!m_axi_rresp_i[1] && !m_axi_rid_i && m_axi_rlast_i) ? loaded : 64'b0;
            exokay_q<=m_axi_rresp_i==1 && !m_axi_rid_i && m_axi_rlast_i;
          end else begin
            fatal_q<=m_axi_rid_i || !m_axi_rlast_i || m_axi_rresp_i==1;
            error_q<=m_axi_rresp_i!=0 || m_axi_rid_i || !m_axi_rlast_i;
            cause_q<=(m_axi_rresp_i!=0 || m_axi_rid_i || !m_axi_rlast_i) ? 64'd5 : 64'd0;
            data_q<=(m_axi_rresp_i==0 && !m_axi_rid_i && m_axi_rlast_i) ? loaded : 64'b0;
          end
          state_q<=fast_response && rsp_ready_i ? IDLE : RESP;
          // The old response was consumed before the new request becomes live.
          // New AR may handshake now, or hold the captured payload in AR.
          if(req_fire) begin
            addr_q<=req_addr_i;size_q<=req_size_i;unsigned_q<=req_unsigned_i;
            exclusive_q<=0;exokay_q<=0;data_q<=0;error_q<=0;cause_q<=0;
            aw_pending_q<=0;w_pending_q<=0;state_q<=ar_fire ? R : AR;
          end
        end
        W: begin
          if(aw_fire) aw_pending_q<=0;
          if(w_fire) w_pending_q<=0;
          if((!aw_pending_q || aw_fire) && (!w_pending_q || w_fire)) state_q<=B;
        end
        B: if(b_fire) begin
          if(exclusive_q) begin
            fatal_q<=m_axi_bid_i;
            error_q<=m_axi_bresp_i[1] || m_axi_bid_i;
            cause_q<=(m_axi_bresp_i[1] || m_axi_bid_i) ? 64'd7 : 64'd0;
            exokay_q<=m_axi_bresp_i==1 && !m_axi_bid_i;
          end else begin
            fatal_q<=m_axi_bid_i || m_axi_bresp_i==1;
            error_q<=m_axi_bresp_i!=0 || m_axi_bid_i;
            cause_q<=(m_axi_bresp_i!=0 || m_axi_bid_i) ? 64'd7 : 64'd0;
          end
          state_q<=fast_response && rsp_ready_i ? IDLE : RESP;
        end
        RESP: if(rsp_ready_i) state_q<=IDLE;
        default: begin state_q<=IDLE;fatal_q<=1; end
      endcase
    end
  end
`ifdef RV64_LSU_FORMAL
  `include "formal/rv64/turn_lsu_properties.svh"
`endif
`ifdef RV64_PRIVILEGED_FORMAL
  // A poisoned channel cannot secretly remain active in an induction prefix.
  // It may hold its final response, then stays idle until a common reset.
  always @* if(aresetn_i) begin
    assert(state_q<=RESP);
    if(fatal_q) assert(state_q==IDLE || state_q==RESP);
  end
`endif
endmodule
