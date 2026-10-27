// R91 candidate: one hart, M/S contexts, 31 synchronous level sources.
// AXI64 lanes with atomic 32-bit single-beat registers, no vendor IP.
// Priority/threshold 0..7; claim ignores threshold, completion checks enable.
// Notification is registered (one cycle after the corresponding state change).
module rv64_plic (
 input logic clk_i,aresetn_i,input logic [31:1] sources_i,
 output logic irq_meip_o,irq_seip_o,
 input logic s_arvalid_i,output logic s_arready_o,input logic s_arid_i,
 input logic [63:0] s_araddr_i,input logic [7:0] s_arlen_i,
 input logic [2:0] s_arsize_i,input logic [1:0] s_arburst_i,input logic s_arlock_i,
 output logic s_rvalid_o,input logic s_rready_i,output logic s_rid_o,s_rlast_o,
 output logic [63:0] s_rdata_o,output logic [1:0] s_rresp_o,
 input logic s_awvalid_i,output logic s_awready_o,input logic s_awid_i,
 input logic [63:0] s_awaddr_i,input logic [7:0] s_awlen_i,
 input logic [2:0] s_awsize_i,input logic [1:0] s_awburst_i,input logic s_awlock_i,
 input logic s_wvalid_i,output logic s_wready_o,input logic [63:0] s_wdata_i,
 input logic [7:0] s_wstrb_i,input logic s_wlast_i,
 output logic s_bvalid_o,input logic s_bready_i,output logic s_bid_o,
 output logic [1:0] s_bresp_o
);
 localparam logic [63:0] BASE=64'h0c000000;
 localparam logic [1:0] W_IDLE=0,W_DATA=1,W_RESP=2;
 logic [2:0] priority_q [0:31],threshold_q [0:1];
 logic [31:0] enable_q [0:1];
 logic [31:0] pending_q,blocked_q,pending_d,blocked_d;
 logic [1:0] irq_q,wstate_q,bresp_q;
 logic rvalid_q,rid_q,rbad_q,wid_q,wbad_q;
 logic [7:0] rlen_q,rbeat_q,wlen_q,wbeat_q;
 logic [63:0] rdata_q,waddr_q;
 logic [2:0] tree_priority [0:1][1:63];
 logic [4:0] tree_id [0:1][1:63],winner [0:1];
 logic [31:0] read_word,write_word;
 logic [1:0] write_response;
 function automatic logic legal(input logic [63:0] a,input logic [7:0] n,
  input logic [2:0] size,input logic [1:0] burst,input logic lock);
  legal=a>=BASE&&a<BASE+64'h400000&&a[1:0]==0&&n==0&&size==2&&burst==1&&!lock;
 endfunction
 // A balanced 32-leaf tournament limits priority selection to five levels.
 always_comb begin
  for(integer t=0;t<2;t=t+1)begin
   for(integer i=0;i<32;i=i+1)begin
    tree_priority[t][32+i]=(pending_q[i]&&enable_q[t][i])?priority_q[i]:3'd0;
    tree_id[t][32+i]=5'(i);
   end
   for(integer i=31;i>0;i=i-1)begin
    if(tree_priority[t][2*i]>=tree_priority[t][2*i+1])begin
     tree_priority[t][i]=tree_priority[t][2*i];tree_id[t][i]=tree_id[t][2*i];
    end else begin
     tree_priority[t][i]=tree_priority[t][2*i+1];tree_id[t][i]=tree_id[t][2*i+1];
    end
   end
   winner[t]=tree_priority[t][1]!=0?tree_id[t][1]:5'd0;
  end
 end
 assign irq_meip_o=aresetn_i&&irq_q[0];assign irq_seip_o=aresetn_i&&irq_q[1];
 // One transaction globally; AW wins a simultaneous read/write request.
 assign s_arready_o=aresetn_i&&!rvalid_q&&wstate_q==W_IDLE&&!s_awvalid_i;
 assign s_awready_o=aresetn_i&&!rvalid_q&&wstate_q==W_IDLE;
 assign s_wready_o=aresetn_i&&wstate_q==W_DATA;
 assign s_rvalid_o=aresetn_i&&rvalid_q;assign s_rid_o=rid_q;
 assign s_rlast_o=rbeat_q==rlen_q;assign s_rdata_o=rdata_q;
 assign s_rresp_o=rbad_q?2'b11:2'b00;
 assign s_bvalid_o=aresetn_i&&wstate_q==W_RESP;assign s_bid_o=wid_q;assign s_bresp_o=bresp_q;
 wire ar_fire=s_arvalid_i&&s_arready_o,aw_fire=s_awvalid_i&&s_awready_o;
 wire w_fire=s_wvalid_i&&s_wready_o;
 wire ar_legal=legal(s_araddr_i,s_arlen_i,s_arsize_i,s_arburst_i,s_arlock_i);
 wire claim_m=ar_fire&&ar_legal&&s_araddr_i==BASE+64'h200004;
 wire claim_s=ar_fire&&ar_legal&&s_araddr_i==BASE+64'h201004;
 always_comb begin
  read_word=0;
  if(s_araddr_i>=BASE+4&&s_araddr_i<=BASE+124)read_word={29'd0,priority_q[s_araddr_i[6:2]]};
  else case(s_araddr_i-BASE)
   64'h1000:read_word=pending_q;
   64'h2000:read_word=enable_q[0];64'h2080:read_word=enable_q[1];
   64'h200000:read_word={29'd0,threshold_q[0]};64'h201000:read_word={29'd0,threshold_q[1]};
   64'h200004:read_word={27'd0,winner[0]};64'h201004:read_word={27'd0,winner[1]};
   default:read_word=0;
  endcase
  write_word=waddr_q[2]?s_wdata_i[63:32]:s_wdata_i[31:0];
  write_response=0;
  if(wbad_q)write_response=3;
  else if(!s_wlast_i||s_wstrb_i!=(waddr_q[2]?8'hf0:8'h0f))write_response=2;
 end
 wire write_effect=w_fire&&write_response==0;
 wire complete_m=write_effect&&waddr_q==BASE+64'h200004;
 wire complete_s=write_effect&&waddr_q==BASE+64'h201004;
 wire complete_valid=write_word>0&&write_word<32&&
  ((complete_m&&enable_q[0][write_word[4:0]])||(complete_s&&enable_q[1][write_word[4:0]]));
 always_comb begin
  pending_d=pending_q;blocked_d=blocked_q;
  for(integer i=1;i<32;i=i+1)begin
   if(!blocked_q[i]&&sources_i[i])begin pending_d[i]=1;blocked_d[i]=1;end
  end
  if(complete_valid)blocked_d[write_word[4:0]]=0;
  if(claim_m&&winner[0]!=0)pending_d[winner[0]]=0;
  if(claim_s&&winner[1]!=0)pending_d[winner[1]]=0;
  pending_d[0]=0;blocked_d[0]=0;
 end
 always_ff @(posedge clk_i or negedge aresetn_i)begin
  if(!aresetn_i)begin
   for(integer i=0;i<32;i=i+1)priority_q[i]<=0;
   for(integer t=0;t<2;t=t+1)begin threshold_q[t]<=0;enable_q[t]<=0;end
   pending_q<=0;blocked_q<=0;irq_q<=0;wstate_q<=W_IDLE;bresp_q<=0;
   rvalid_q<=0;rid_q<=0;rbad_q<=0;rlen_q<=0;rbeat_q<=0;rdata_q<=0;
   wid_q<=0;wbad_q<=0;waddr_q<=0;wlen_q<=0;wbeat_q<=0;
  end else begin
   pending_q<=pending_d;blocked_q<=blocked_d;
   for(integer t=0;t<2;t=t+1)irq_q[t]<=tree_priority[t][1]>threshold_q[t];
   if(ar_fire)begin
    rvalid_q<=1;rid_q<=s_arid_i;rlen_q<=s_arlen_i;rbeat_q<=0;rbad_q<=!ar_legal;
    rdata_q<=ar_legal?(s_araddr_i[2]?{read_word,32'd0}:{32'd0,read_word}):64'd0;
   end else if(s_rvalid_o&&s_rready_i)begin
    if(s_rlast_o)rvalid_q<=0;else rbeat_q<=rbeat_q+8'd1;
   end
   if(aw_fire)begin
    wstate_q<=W_DATA;wid_q<=s_awid_i;waddr_q<=s_awaddr_i;wlen_q<=s_awlen_i;wbeat_q<=0;
    wbad_q<=!legal(s_awaddr_i,s_awlen_i,s_awsize_i,s_awburst_i,s_awlock_i);
   end else if(w_fire)begin
    if(wbeat_q==wlen_q)begin wstate_q<=W_RESP;bresp_q<=write_response;end
    else wbeat_q<=wbeat_q+8'd1;
    if(write_effect)begin
     if(waddr_q>=BASE+4&&waddr_q<=BASE+124)priority_q[waddr_q[6:2]]<=write_word[2:0];
     else case(waddr_q-BASE)
      64'h2000:enable_q[0]<=write_word&32'hfffffffe;
      64'h2080:enable_q[1]<=write_word&32'hfffffffe;
      64'h200000:threshold_q[0]<=write_word[2:0];64'h201000:threshold_q[1]<=write_word[2:0];
      default:begin end
     endcase
    end
   end else if(s_bvalid_o&&s_bready_i)wstate_q<=W_IDLE;
  end
 end
`ifdef RV64_PLIC_FORMAL
 `include "formal/rv64/r91_plic_properties.svh"
`endif
endmodule
