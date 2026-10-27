// R85 single-line maintenance MMIO endpoint. Vendor-IP-free, common reset.
// 0x03000000 ADDRESS, +8 COMMAND, +16 STATUS, +24 completed address,
// +32 identity. Only aligned 64-bit single-beat INCR, no exclusives.
// Writes require all eight strobes. Invalid bursts drain AxLEN+1 beats.
// COMMAND 0/1/2 = clean/invalidate/flush; 4 = clear completion (idle only).
// A command is snapshotted at W, but never issued before its own B handshake.
// Cache ready must mean all CPU/bus fragments have drained (R84 contract).
// STATUS busy[0], done[1], error[2], fatal[3], response[5:4], count[63:32].
// Command B acknowledges queueing, not cache completion. Software must poll.
module rv64_dma_cache_control (
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
 output logic maint_valid_o,input logic maint_ready_i,
 output logic [63:0] maint_addr_o,output logic [1:0] maint_op_o,
 input logic maint_done_i,output logic maint_ack_o,input logic [1:0] maint_resp_i,
 input logic cache_fatal_i,
 output logic busy_o,done_o,error_o,fatal_o
);
 localparam logic [63:0] BASE=64'h03000000,IDENTITY=64'h5238350000200001;
 localparam logic [1:0] W_IDLE=0,W_DATA=1,W_RESP=2;
 localparam logic [2:0] C_IDLE=0,C_QUEUED=1,C_ISSUE=2,C_WAIT=3,C_FATAL=4;
 logic [1:0] wstate_q,bresp_q,result_q;
 logic [2:0] cstate_q;
 logic [63:0] address_q,command_addr_q,completed_addr_q,rdata_q;
 logic [31:0] count_q;
 logic [1:0] command_op_q;
 logic done_q,rvalid_q,rid_q,rbad_q,wid_q,wbad_q,wcmd_q;
 logic [7:0] rlen_q,rbeat_q,wlen_q,wbeat_q;
 logic [2:0] wreg_q;
 function automatic logic legal(input logic [63:0] a,input logic [7:0] n,
  input logic [2:0] size,input logic [1:0] burst,input logic lock);
  begin legal=a>=BASE&&a<=BASE+64'd32&&a[2:0]==0&&n==0&&size==3&&burst==1&&!lock;end
 endfunction
 wire ar_fire=s_arvalid_i&&s_arready_o;
 wire aw_fire=s_awvalid_i&&s_awready_o;
 wire w_fire=s_wvalid_i&&s_wready_o;
 wire b_fire=s_bvalid_o&&s_bready_i;
 wire command_write=w_fire&&!wbad_q&&s_wlast_i&&s_wstrb_i==8'hff&&
   wreg_q==1&&cstate_q==C_IDLE&&!cache_fatal_i&&s_wdata_i<=64'd2;
 logic [1:0] write_response;
 always_comb begin
  write_response=0;
  if(wbad_q||wreg_q>1)write_response=3;
  else if(!s_wlast_i||s_wstrb_i!=8'hff)write_response=2;
  else if(cstate_q!=C_IDLE||cache_fatal_i)write_response=2;
  else if(wreg_q==1&&s_wdata_i>2&&s_wdata_i!=4)write_response=3;
 end
 assign s_arready_o=aresetn_i&&!rvalid_q;
 assign s_rvalid_o=aresetn_i&&rvalid_q;
 assign s_rid_o=rid_q;assign s_rlast_o=rbeat_q==rlen_q;
 assign s_rdata_o=rdata_q;assign s_rresp_o=rbad_q?2'b11:2'b00;
 assign s_awready_o=aresetn_i&&wstate_q==W_IDLE;
 assign s_wready_o=aresetn_i&&wstate_q==W_DATA;
 assign s_bvalid_o=aresetn_i&&wstate_q==W_RESP;
 assign s_bid_o=wid_q;assign s_bresp_o=bresp_q;
 assign busy_o=aresetn_i&&(cstate_q==C_QUEUED||cstate_q==C_ISSUE||cstate_q==C_WAIT);
 assign done_o=aresetn_i&&done_q;
 assign error_o=aresetn_i&&(result_q!=0||cstate_q==C_FATAL);
 assign fatal_o=aresetn_i&&cstate_q==C_FATAL;
 assign maint_valid_o=aresetn_i&&cstate_q==C_ISSUE&&!cache_fatal_i;
 assign maint_addr_o=command_addr_q;assign maint_op_o=command_op_q;
 assign maint_ack_o=aresetn_i&&cstate_q==C_WAIT&&maint_done_i&&!cache_fatal_i;
 always_ff @(posedge clk_i or negedge aresetn_i)begin
  if(!aresetn_i)begin
   wstate_q<=W_IDLE;cstate_q<=C_IDLE;address_q<=0;command_addr_q<=0;command_op_q<=0;
   completed_addr_q<=0;count_q<=0;result_q<=0;done_q<=0;
   rvalid_q<=0;rid_q<=0;rbad_q<=0;rdata_q<=0;rlen_q<=0;rbeat_q<=0;
   wid_q<=0;wbad_q<=0;wcmd_q<=0;wreg_q<=0;wlen_q<=0;wbeat_q<=0;bresp_q<=0;
  end else begin
   if(ar_fire)begin
    rvalid_q<=1;rid_q<=s_arid_i;rlen_q<=s_arlen_i;rbeat_q<=0;
    rbad_q<=!legal(s_araddr_i,s_arlen_i,s_arsize_i,s_arburst_i,s_arlock_i);rdata_q<=0;
    if(legal(s_araddr_i,s_arlen_i,s_arsize_i,s_arburst_i,s_arlock_i))begin
     case(s_araddr_i[5:3])
      0:rdata_q<=address_q;
      2:rdata_q<={count_q,26'd0,result_q,fatal_o,error_o,done_o,busy_o};
      3:rdata_q<=completed_addr_q;
      4:rdata_q<=IDENTITY;
      default:rdata_q<=0;
     endcase
    end
   end else if(s_rvalid_o&&s_rready_i)begin
    if(s_rlast_o)rvalid_q<=0;else rbeat_q<=rbeat_q+8'd1;
   end
   if(aw_fire)begin
    wstate_q<=W_DATA;wid_q<=s_awid_i;wlen_q<=s_awlen_i;wbeat_q<=0;
    wreg_q<=s_awaddr_i[5:3];wcmd_q<=0;
    wbad_q<=!legal(s_awaddr_i,s_awlen_i,s_awsize_i,s_awburst_i,s_awlock_i);
   end else if(w_fire)begin
    if(wbeat_q==wlen_q)begin wstate_q<=W_RESP;bresp_q<=write_response;end
    else wbeat_q<=wbeat_q+8'd1;
    if(write_response==0)begin
     if(wreg_q==0)address_q<=s_wdata_i;
     else if(s_wdata_i==4)begin done_q<=0;result_q<=0;end
     else if(command_write)begin
      command_addr_q<=address_q;command_op_q<=s_wdata_i[1:0];
      cstate_q<=C_QUEUED;wcmd_q<=1;done_q<=0;result_q<=0;
     end
    end
   end else if(b_fire)begin
    wstate_q<=W_IDLE;wcmd_q<=0;
    if(wcmd_q&&cstate_q==C_QUEUED)cstate_q<=C_ISSUE;
   end
   if(maint_valid_o&&maint_ready_i)cstate_q<=C_WAIT;
   if(maint_ack_o)begin
    cstate_q<=C_IDLE;done_q<=1;result_q<=maint_resp_i;
    completed_addr_q<=command_addr_q;count_q<=count_q+32'd1;
   end
   // Fatal is sticky until common reset, never counted as successful completion.
   if(cache_fatal_i)begin cstate_q<=C_FATAL;done_q<=0;result_q<=2;end
  end
 end
endmodule
