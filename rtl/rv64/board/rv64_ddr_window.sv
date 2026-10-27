// Board DDR-only AXI4 aperture. One read and one write may be outstanding.
// 0x80000000..0x87ffffff -> PS DDR 0..0x07ffffff; no other alias.
// Registered addresses isolate the 64-bit decode from the vendor converter.
// Unsupported/overflow/cross-4KiB/out-of-aperture requests return DECERR;
// rejected writes consume exactly AWLEN+1 data beats before replying.
// Upstream and downstream obey AXI and share reset. No timeout or rollback.
module rv64_ddr_window (
 input logic clk_i,aresetn_i,
 input logic s_arvalid_i,output logic s_arready_o,
 input logic s_arid_i,input logic [63:0] s_araddr_i,
 input logic [7:0] s_arlen_i,input logic [2:0] s_arsize_i,s_arprot_i,
 input logic [1:0] s_arburst_i,input logic s_arlock_i,input logic [3:0] s_arcache_i,
 output logic s_rvalid_o,input logic s_rready_i,
 output logic s_rid_o,s_rlast_o,output logic [63:0] s_rdata_o,output logic [1:0] s_rresp_o,
 input logic s_awvalid_i,output logic s_awready_o,
 input logic s_awid_i,input logic [63:0] s_awaddr_i,
 input logic [7:0] s_awlen_i,input logic [2:0] s_awsize_i,s_awprot_i,
 input logic [1:0] s_awburst_i,input logic s_awlock_i,input logic [3:0] s_awcache_i,
 input logic s_wvalid_i,output logic s_wready_o,input logic [63:0] s_wdata_i,
 input logic [7:0] s_wstrb_i,input logic s_wlast_i,
 output logic s_bvalid_o,input logic s_bready_i,output logic s_bid_o,output logic [1:0] s_bresp_o,
 output logic m_arvalid_o,input logic m_arready_i,
 output logic m_arid_o,output logic [31:0] m_araddr_o,
 output logic [7:0] m_arlen_o,output logic [2:0] m_arsize_o,m_arprot_o,
 output logic [1:0] m_arburst_o,output logic m_arlock_o,output logic [3:0] m_arcache_o,
 input logic m_rvalid_i,output logic m_rready_o,
 input logic m_rid_i,m_rlast_i,input logic [63:0] m_rdata_i,input logic [1:0] m_rresp_i,
 output logic m_awvalid_o,input logic m_awready_i,
 output logic m_awid_o,output logic [31:0] m_awaddr_o,
 output logic [7:0] m_awlen_o,output logic [2:0] m_awsize_o,m_awprot_o,
 output logic [1:0] m_awburst_o,output logic m_awlock_o,output logic [3:0] m_awcache_o,
 output logic m_wvalid_o,input logic m_wready_i,output logic [63:0] m_wdata_o,
 output logic [7:0] m_wstrb_o,output logic m_wlast_o,
 input logic m_bvalid_i,output logic m_bready_o,input logic m_bid_i,input logic [1:0] m_bresp_i
);
 localparam logic [1:0] R_IDLE=0,R_ADDR=1,R_DATA=2,R_REJECT=3;
 localparam logic [1:0] W_IDLE=0,W_DATA=1,W_RESP=2;
 logic [1:0] rstate_q,wstate_q;
 logic [31:0] raddr_q,waddr_q;
 logic rid_q,wid_q,rlock_q,wlock_q,wbad_q,aw_pending_q,w_done_q;
 logic [7:0] rlen_q,wlen_q,rbeat_q,wbeat_q;
 logic [2:0] rsize_q,wsize_q,rprot_q,wprot_q;
 logic [3:0] rcache_q,wcache_q;
 function automatic logic allowed(input logic [63:0] addr,input logic [7:0] len,
   input logic [2:0] size,input logic [1:0] burst,input logic locked);
  logic [11:0] span;
  logic [27:0] finish;
  logic [12:0] page_finish;
  begin
   // Maximum legal span is 256*8=2048. Wider temporary prevents wrap.
   span=({4'b0,len}+12'd1)<<size;
   finish={1'b0,addr[26:0]}+{16'b0,span};
   page_finish={1'b0,addr[11:0]}+{1'b0,span};
   allowed=addr[63:27]==37'h10 && size<=3 && burst==2'b01 &&
    (addr[2:0]&((3'd1<<size)-3'd1))==0 &&
    finish<=28'h8000000 && page_finish<=13'h1000 &&
    (!locked || (len==0 && (size==2 || size==3)));
  end
 endfunction
 wire ar_fire=s_arvalid_i&&s_arready_o;
 wire aw_fire=s_awvalid_i&&s_awready_o;
 wire r_fire=s_rvalid_o&&s_rready_i;
 wire w_fire=s_wvalid_i&&s_wready_o;
 wire ma_fire=m_awvalid_o&&m_awready_i;
 wire w_last=wbad_q ? wbeat_q==wlen_q : s_wlast_i;
 assign s_arready_o=aresetn_i&&rstate_q==R_IDLE;
 assign s_awready_o=aresetn_i&&wstate_q==W_IDLE;
 assign m_arvalid_o=aresetn_i&&rstate_q==R_ADDR;
 assign m_araddr_o=raddr_q;assign m_arid_o=rid_q;
 assign m_arlen_o=rlen_q;assign m_arsize_o=rsize_q;assign m_arprot_o=rprot_q;
 assign m_arburst_o=2'b01;assign m_arlock_o=rlock_q;assign m_arcache_o=rcache_q;
 assign s_rvalid_o=aresetn_i&&((rstate_q==R_REJECT)||(rstate_q==R_DATA&&m_rvalid_i));
 assign s_rdata_o=rstate_q==R_REJECT ? 64'd0 : m_rdata_i;
 assign s_rresp_o=rstate_q==R_REJECT ? 2'b11 : m_rresp_i;
 assign s_rid_o=rstate_q==R_REJECT ? rid_q : m_rid_i;
 assign s_rlast_o=rstate_q==R_REJECT ? rbeat_q==rlen_q : m_rlast_i;
 assign m_rready_o=aresetn_i&&rstate_q==R_DATA&&s_rready_i;
 assign m_awvalid_o=aresetn_i&&wstate_q==W_DATA&&!wbad_q&&aw_pending_q;
 assign m_awaddr_o=waddr_q;assign m_awid_o=wid_q;
 assign m_awlen_o=wlen_q;assign m_awsize_o=wsize_q;assign m_awprot_o=wprot_q;
 assign m_awburst_o=2'b01;assign m_awlock_o=wlock_q;assign m_awcache_o=wcache_q;
 assign s_wready_o=aresetn_i&&wstate_q==W_DATA&&!w_done_q&&(wbad_q||m_wready_i);
 assign m_wvalid_o=aresetn_i&&wstate_q==W_DATA&&!w_done_q&&!wbad_q&&s_wvalid_i;
 assign m_wdata_o=s_wdata_i;assign m_wstrb_o=s_wstrb_i;assign m_wlast_o=s_wlast_i;
 assign s_bvalid_o=aresetn_i&&wstate_q==W_RESP&&(wbad_q||m_bvalid_i);
 assign s_bid_o=wbad_q ? wid_q : m_bid_i;
 assign s_bresp_o=wbad_q ? 2'b11 : m_bresp_i;
 assign m_bready_o=aresetn_i&&wstate_q==W_RESP&&!wbad_q&&s_bready_i;
 always_ff @(posedge clk_i or negedge aresetn_i) begin
  if(!aresetn_i) begin
   rstate_q<=R_IDLE;wstate_q<=W_IDLE;raddr_q<=0;waddr_q<=0;
   rid_q<=0;wid_q<=0;rlock_q<=0;wlock_q<=0;wbad_q<=0;aw_pending_q<=0;w_done_q<=0;
   rlen_q<=0;wlen_q<=0;rbeat_q<=0;wbeat_q<=0;
   rsize_q<=0;wsize_q<=0;rprot_q<=0;wprot_q<=0;rcache_q<=0;wcache_q<=0;
  end else begin
   if(ar_fire) begin
    raddr_q<={5'd0,s_araddr_i[26:0]};rid_q<=s_arid_i;rlen_q<=s_arlen_i;
    rsize_q<=s_arsize_i;rprot_q<=s_arprot_i;rlock_q<=s_arlock_i;rcache_q<=s_arcache_i;rbeat_q<=0;
    rstate_q<=allowed(s_araddr_i,s_arlen_i,s_arsize_i,s_arburst_i,s_arlock_i) ? R_ADDR : R_REJECT;
   end else if(rstate_q==R_ADDR&&m_arready_i)rstate_q<=R_DATA;
   else if(r_fire)begin
    if(s_rlast_o)rstate_q<=R_IDLE;
    else rbeat_q<=rbeat_q+8'd1;
   end
   if(aw_fire)begin
    waddr_q<={5'd0,s_awaddr_i[26:0]};wid_q<=s_awid_i;wlen_q<=s_awlen_i;
    wsize_q<=s_awsize_i;wprot_q<=s_awprot_i;wlock_q<=s_awlock_i;wcache_q<=s_awcache_i;wbeat_q<=0;
    wbad_q<=!allowed(s_awaddr_i,s_awlen_i,s_awsize_i,s_awburst_i,s_awlock_i);
    aw_pending_q<=allowed(s_awaddr_i,s_awlen_i,s_awsize_i,s_awburst_i,s_awlock_i);
    w_done_q<=0;wstate_q<=W_DATA;
   end else if(wstate_q==W_DATA)begin
    if(ma_fire)aw_pending_q<=0;
    if(w_fire)begin
     if(w_last)w_done_q<=1;
     else wbeat_q<=wbeat_q+8'd1;
    end
    if((!aw_pending_q||ma_fire)&&(w_done_q||(w_fire&&w_last)))wstate_q<=W_RESP;
   end else if(s_bvalid_o&&s_bready_i)wstate_q<=W_IDLE;
  end
 end
endmodule
