// Single-hart CLINT, 64-bit AXI4 slave, no vendor IP. Common CPU clock/reset.
// 50 MHz / TICK_DIV=50 -> 1 MHz mtime. One read and one write outstanding.
// Only naturally aligned single-beat accesses to implemented registers are
// accepted. Invalid reads produce ARLEN+1 DECERR beats; invalid writes drain
// AWLEN+1 beats and produce DECERR. Master obeys AXI (including WLAST).
// Data uses AXI byte lanes. Out-of-transfer WSTRB produces SLVERR, no write.
// Reads snapshot at AR; writes commit at W, even if B is backpressured.
module rv64_clint #(parameter integer TICK_DIV=50) (
 input logic clk_i,aresetn_i,
 input logic s_arvalid_i,output logic s_arready_o,
 input logic s_arid_i,input logic [63:0] s_araddr_i,
 input logic [7:0] s_arlen_i,input logic [2:0] s_arsize_i,
 input logic [1:0] s_arburst_i,input logic s_arlock_i,
 output logic s_rvalid_o,input logic s_rready_i,
 output logic s_rid_o,s_rlast_o,output logic [63:0] s_rdata_o,output logic [1:0] s_rresp_o,
 input logic s_awvalid_i,output logic s_awready_o,
 input logic s_awid_i,input logic [63:0] s_awaddr_i,
 input logic [7:0] s_awlen_i,input logic [2:0] s_awsize_i,
 input logic [1:0] s_awburst_i,input logic s_awlock_i,
 input logic s_wvalid_i,output logic s_wready_o,input logic [63:0] s_wdata_i,
 input logic [7:0] s_wstrb_i,input logic s_wlast_i,
 output logic s_bvalid_o,input logic s_bready_i,output logic s_bid_o,output logic [1:0] s_bresp_o,
 output logic irq_msip_o,irq_mtip_o,output logic [63:0] time_o
);
 localparam integer DIV_BITS=TICK_DIV>1 ? $clog2(TICK_DIV) : 1;
 localparam logic [1:0] SEL_NONE=0,SEL_MSIP=1,SEL_CMP=2,SEL_TIME=3;
 localparam logic [1:0] W_IDLE=0,W_DATA=1,W_RESP=2;
 logic [DIV_BITS-1:0] divider_q;
 logic [63:0] mtime_q,mtimecmp_q,rdata_q;
 logic msip_q,rvalid_q,rid_q,rbad_q,wid_q,wbad_q;
 logic [7:0] rlen_q,rbeat_q,wlen_q,wbeat_q,wmask_q;
 logic [1:0] wstate_q,wsel_q,bresp_q;
 function automatic logic [1:0] select_reg(input logic [63:0] a);
  begin
   if(a>=64'h02000000&&a<64'h02000004)select_reg=SEL_MSIP;
   else if(a>=64'h02004000&&a<64'h02004008)select_reg=SEL_CMP;
   else if(a>=64'h0200bff8&&a<64'h0200c000)select_reg=SEL_TIME;
   else select_reg=SEL_NONE;
  end
 endfunction
 function automatic logic allowed(input logic [63:0] a,input logic [7:0] n,
   input logic [2:0] sz,input logic [1:0] burst,input logic lk);
  begin
   allowed=select_reg(a)!=SEL_NONE&&n==0&&sz<=3&&burst==1&&!lk&&
    (a[2:0]&((3'd1<<sz)-3'd1))==0&&
    !(select_reg(a)==SEL_MSIP&&sz==3);
  end
 endfunction
 function automatic logic [7:0] lane_mask(input logic [2:0] lane,sz);
  begin lane_mask=8'(((16'd1<<(4'd1<<sz))-16'd1)<<lane);end
 endfunction
 wire ar_fire=s_arvalid_i&&s_arready_o;
 wire aw_fire=s_awvalid_i&&s_awready_o;
 wire w_fire=s_wvalid_i&&s_wready_o;
 wire tick=divider_q==DIV_BITS'(TICK_DIV-1);
 wire write_ok=w_fire&&!wbad_q&&((s_wstrb_i&~wmask_q)==0)&&(|s_wstrb_i);
 logic [63:0] write_mask;
 for(genvar byte_lane=0;byte_lane<8;byte_lane=byte_lane+1)begin: g_mask
  assign write_mask[byte_lane*8+:8]={8{s_wstrb_i[byte_lane]}};
 end
 assign s_arready_o=aresetn_i&&!rvalid_q;
 assign s_rvalid_o=aresetn_i&&rvalid_q;
 assign s_rid_o=rid_q;assign s_rlast_o=rbeat_q==rlen_q;
 assign s_rdata_o=rdata_q;assign s_rresp_o=rbad_q?2'b11:2'b00;
 assign s_awready_o=aresetn_i&&wstate_q==W_IDLE;
 assign s_wready_o=aresetn_i&&wstate_q==W_DATA;
 assign s_bvalid_o=aresetn_i&&wstate_q==W_RESP;
 assign s_bid_o=wid_q;assign s_bresp_o=bresp_q;
 assign irq_msip_o=aresetn_i&&msip_q;
 assign irq_mtip_o=aresetn_i&&(mtime_q>=mtimecmp_q);
 assign time_o=mtime_q;
 // WLAST is checked only for an otherwise valid single beat. Invalid bursts
 // are drained by the accepted AWLEN, never by an untrusted early WLAST.
 always_ff @(posedge clk_i or negedge aresetn_i) begin
  if(!aresetn_i)begin
   divider_q<=0;mtime_q<=0;mtimecmp_q<=64'hffffffffffffffff;msip_q<=0;
   rvalid_q<=0;rid_q<=0;rbad_q<=0;rdata_q<=0;rlen_q<=0;rbeat_q<=0;
   wstate_q<=W_IDLE;wid_q<=0;wbad_q<=0;wsel_q<=SEL_NONE;
   wlen_q<=0;wbeat_q<=0;wmask_q<=0;bresp_q<=0;
  end else begin
   if(tick)begin divider_q<=0;mtime_q<=mtime_q+64'd1;end
   else divider_q<=divider_q+1'b1;
   if(ar_fire)begin
    rvalid_q<=1;rid_q<=s_arid_i;rlen_q<=s_arlen_i;rbeat_q<=0;
    rbad_q<=!allowed(s_araddr_i,s_arlen_i,s_arsize_i,s_arburst_i,s_arlock_i);
    rdata_q<=0;
    if(allowed(s_araddr_i,s_arlen_i,s_arsize_i,s_arburst_i,s_arlock_i))begin
     case(select_reg(s_araddr_i))
      SEL_MSIP:rdata_q<={63'd0,msip_q};
      SEL_CMP:rdata_q<=mtimecmp_q;
      SEL_TIME:rdata_q<=mtime_q;
      default:rdata_q<=0;
     endcase
    end
   end else if(s_rvalid_o&&s_rready_i)begin
    if(s_rlast_o)rvalid_q<=0;
    else rbeat_q<=rbeat_q+8'd1;
   end
   if(aw_fire)begin
    wstate_q<=W_DATA;wid_q<=s_awid_i;wlen_q<=s_awlen_i;wbeat_q<=0;
    wsel_q<=select_reg(s_awaddr_i);wmask_q<=lane_mask(s_awaddr_i[2:0],s_awsize_i);
    wbad_q<=!allowed(s_awaddr_i,s_awlen_i,s_awsize_i,s_awburst_i,s_awlock_i);
   end else if(w_fire)begin
    if(wbeat_q==wlen_q)begin
     wstate_q<=W_RESP;
     bresp_q<=wbad_q ? 2'b11 : (((s_wstrb_i&~wmask_q)!=0||!s_wlast_i)?2'b10:2'b00);
    end else wbeat_q<=wbeat_q+8'd1;
   end else if(s_bvalid_o&&s_bready_i)wstate_q<=W_IDLE;
   if(write_ok&&s_wlast_i)begin
    case(wsel_q)
     SEL_MSIP:if(s_wstrb_i[0])msip_q<=s_wdata_i[0];
     SEL_CMP:mtimecmp_q<=(mtimecmp_q&~write_mask)|(s_wdata_i&write_mask);
     SEL_TIME:mtime_q<=(mtime_q&~write_mask)|(s_wdata_i&write_mask);
     default:begin end
    endcase
   end
  end
 end
endmodule
