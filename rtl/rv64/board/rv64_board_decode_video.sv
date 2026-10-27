// R104 registered seven-target board AXI4 decoder. Target order: DDR window, ROM,
// CLINT, PS GP0 MMIO, DMA cache control, PLIC, scanout control. Common payload is broadcast, VALID selects one target.
// One read and one write outstanding independently. No vendor IP.
// Full 64-bit decode, aligned INCR <=8B, no 4KiB crossing. PS MMIO is limited
// to UART0/USB0/GPIO/SLCR pages and <=4B single beats. LOCK only reaches DDR.
// Invalid transactions return DECERR and consume exactly AxLEN+1 data beats.
// DMA control page admits only 64-bit single beats, never LOCK.
// PLIC admits only aligned32 single beats, no LOCK; other target rules unchanged.
// VIDEO: 256-byte aperture, aligned32/64 single INCR nonexclusive;
// R103 validates its 0x00..0x5f register subset and write contents.
// route_active releases after three edges; all functional reset uses this net.
// All endpoints obey AXI and share reset; not a timeout/rollback firewall.
module rv64_board_decode_video (
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
 output logic [6:0] m_arvalid_o,input logic [6:0] m_arready_i,
 output logic m_arid_o,output logic [63:0] m_araddr_o,
 output logic [7:0] m_arlen_o,output logic [2:0] m_arsize_o,m_arprot_o,
 output logic [1:0] m_arburst_o,output logic m_arlock_o,output logic [3:0] m_arcache_o,
 input logic [6:0] m_rvalid_i,output logic [6:0] m_rready_o,
 input logic [6:0] m_rid_i,m_rlast_i,input logic [447:0] m_rdata_i,input logic [13:0] m_rresp_i,
 output logic [6:0] m_awvalid_o,input logic [6:0] m_awready_i,
 output logic m_awid_o,output logic [63:0] m_awaddr_o,
 output logic [7:0] m_awlen_o,output logic [2:0] m_awsize_o,m_awprot_o,
 output logic [1:0] m_awburst_o,output logic m_awlock_o,output logic [3:0] m_awcache_o,
 output logic [6:0] m_wvalid_o,input logic [6:0] m_wready_i,output logic [63:0] m_wdata_o,
 output logic [7:0] m_wstrb_o,output logic m_wlast_o,
 input logic [6:0] m_bvalid_i,output logic [6:0] m_bready_o,input logic [6:0] m_bid_i,input logic [13:0] m_bresp_i
);
 (* ASYNC_REG="TRUE" *) logic [1:0] release_q;
 (* ASYNC_REG="TRUE" *) logic route_active;
 always_ff @(posedge clk_i or negedge aresetn_i)
  if(!aresetn_i)begin release_q<=0;route_active<=0;end
  else begin release_q<={release_q[0],1'b1};route_active<=release_q[1];end
 localparam logic [2:0] DDR=0,ROM=1,CLINT=2,PS=3,DMA=4,PLIC=5,VIDEO=6,REJECT=7;
 localparam logic [1:0] R_IDLE=0,R_ADDR=1,R_DATA=2,R_BAD=3;
 localparam logic [1:0] W_IDLE=0,W_ADDR=1,W_DATA=2,W_RESP=3;
 logic [1:0] rstate_q,wstate_q;
 logic [2:0] rsel_q,wsel_q;
 logic [63:0] raddr_q,waddr_q;
 logic rid_q,wid_q,rlock_q,wlock_q;
 logic [7:0] rlen_q,wlen_q,rbeat_q,wbeat_q;
 logic [2:0] rsize_q,wsize_q,rprot_q,wprot_q;
 logic [3:0] rcache_q,wcache_q;
 function automatic logic [2:0] target(input logic [63:0] a,input logic [7:0] n,
  input logic [2:0] sz,input logic [1:0] burst,input logic lk);
  logic [12:0] finish;
  logic [2:0] picked;
  begin
   picked=REJECT;
   finish={1'b0,a[11:0]}+(({5'd0,n}+13'd1)<<sz);
   if(a[63:32]==0)begin
    if(a[31:27]==5'b10000)picked=DDR;
    else if(a[31:12]==20'h00001)picked=ROM;
    else if(a[31:16]==16'h0200)picked=CLINT;
    else if(a[31:12]==20'h03000)picked=DMA;
    else if(a[31:22]==10'h030)picked=PLIC;
    else if(a[31:8]==24'h040000)picked=VIDEO;
    else if(a[31:12]==20'he0000||a[31:12]==20'he0002||a[31:12]==20'he000a||a[31:12]==20'hf8000)picked=PS;
   end
   if(sz>3||burst!=1||finish>13'h1000||(a[2:0]&((3'd1<<sz)-3'd1))!=0||
     (lk&&picked!=DDR)||(picked==PS&&(n!=0||sz>2))||(picked==DMA&&(n!=0||sz!=3))||(picked==PLIC&&(n!=0||sz!=2))||(picked==VIDEO&&(n!=0||(sz!=2&&sz!=3))))picked=REJECT;
   target=picked;
  end
 endfunction
 wire [6:0] rmask=7'b0000001<<rsel_q;
 wire [6:0] wmask=7'b0000001<<wsel_q;
 assign s_arready_o=route_active&&rstate_q==R_IDLE;
 assign s_awready_o=route_active&&wstate_q==W_IDLE;
 assign m_arvalid_o=route_active&&rstate_q==R_ADDR?rmask:7'd0;
 assign m_araddr_o=raddr_q;assign m_arid_o=rid_q;assign m_arlen_o=rlen_q;
 assign m_arsize_o=rsize_q;assign m_arprot_o=rprot_q;assign m_arcache_o=rcache_q;
 assign m_arburst_o=2'b01;assign m_arlock_o=rlock_q;
 assign s_rvalid_o=route_active&&((rstate_q==R_BAD)||(rstate_q==R_DATA&&m_rvalid_i[rsel_q]));
 assign s_rdata_o=rstate_q==R_BAD?64'd0:m_rdata_i[int'(rsel_q)*64+:64];
 assign s_rresp_o=rstate_q==R_BAD?2'b11:m_rresp_i[int'(rsel_q)*2+:2];
 assign s_rid_o=rstate_q==R_BAD?rid_q:m_rid_i[rsel_q];
 assign s_rlast_o=rstate_q==R_BAD?rbeat_q==rlen_q:m_rlast_i[rsel_q];
 assign m_rready_o=route_active&&rstate_q==R_DATA&&s_rready_i?rmask:7'd0;
 assign m_awvalid_o=route_active&&wstate_q==W_ADDR?wmask:7'd0;
 assign m_awaddr_o=waddr_q;assign m_awid_o=wid_q;assign m_awlen_o=wlen_q;
 assign m_awsize_o=wsize_q;assign m_awprot_o=wprot_q;assign m_awcache_o=wcache_q;
 assign m_awburst_o=2'b01;assign m_awlock_o=wlock_q;
 assign m_wvalid_o=route_active&&wstate_q==W_DATA&&s_wvalid_i?wmask:7'd0;
 assign m_wdata_o=s_wdata_i;assign m_wstrb_o=s_wstrb_i;assign m_wlast_o=s_wlast_i;
 assign s_wready_o=route_active&&wstate_q==W_DATA&&(wsel_q==REJECT||m_wready_i[wsel_q]);
 assign s_bvalid_o=route_active&&wstate_q==W_RESP&&(wsel_q==REJECT||m_bvalid_i[wsel_q]);
 assign s_bresp_o=wsel_q==REJECT?2'b11:m_bresp_i[int'(wsel_q)*2+:2];
 assign s_bid_o=wsel_q==REJECT?wid_q:m_bid_i[wsel_q];
 assign m_bready_o=route_active&&wstate_q==W_RESP&&wsel_q!=REJECT&&s_bready_i?wmask:7'd0;
 always_ff @(posedge clk_i or negedge route_active)begin
  if(!route_active)begin
   rstate_q<=R_IDLE;wstate_q<=W_IDLE;rsel_q<=REJECT;wsel_q<=REJECT;
   raddr_q<=0;waddr_q<=0;rid_q<=0;wid_q<=0;rlock_q<=0;wlock_q<=0;
   rlen_q<=0;wlen_q<=0;rbeat_q<=0;wbeat_q<=0;
   rsize_q<=0;wsize_q<=0;rprot_q<=0;wprot_q<=0;rcache_q<=0;wcache_q<=0;
  end else begin
   if(s_arvalid_i&&s_arready_o)begin
    raddr_q<=s_araddr_i;rid_q<=s_arid_i;rlen_q<=s_arlen_i;rsize_q<=s_arsize_i;
    rprot_q<=s_arprot_i;rcache_q<=s_arcache_i;rlock_q<=s_arlock_i;rbeat_q<=0;
    rsel_q<=target(s_araddr_i,s_arlen_i,s_arsize_i,s_arburst_i,s_arlock_i);
    rstate_q<=target(s_araddr_i,s_arlen_i,s_arsize_i,s_arburst_i,s_arlock_i)==REJECT?R_BAD:R_ADDR;
   end else if(rstate_q==R_ADDR&&m_arready_i[rsel_q])rstate_q<=R_DATA;
   else if(s_rvalid_o&&s_rready_i)begin
    if(s_rlast_o)rstate_q<=R_IDLE;else rbeat_q<=rbeat_q+8'd1;
   end
   if(s_awvalid_i&&s_awready_o)begin
    waddr_q<=s_awaddr_i;wid_q<=s_awid_i;wlen_q<=s_awlen_i;wsize_q<=s_awsize_i;
    wprot_q<=s_awprot_i;wcache_q<=s_awcache_i;wlock_q<=s_awlock_i;wbeat_q<=0;
    wsel_q<=target(s_awaddr_i,s_awlen_i,s_awsize_i,s_awburst_i,s_awlock_i);
    wstate_q<=target(s_awaddr_i,s_awlen_i,s_awsize_i,s_awburst_i,s_awlock_i)==REJECT?W_DATA:W_ADDR;
   end else if(wstate_q==W_ADDR&&m_awready_i[wsel_q])wstate_q<=W_DATA;
   else if(s_wvalid_i&&s_wready_o)begin
    if(wbeat_q==wlen_q)wstate_q<=W_RESP;else wbeat_q<=wbeat_q+8'd1;
   end else if(s_bvalid_o&&s_bready_i)wstate_q<=W_IDLE;
  end
 end
endmodule
