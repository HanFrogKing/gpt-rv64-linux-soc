// R103 fixed-framebuffer scanout control and coherent pixel-domain snapshot.
// Portable RTL. Common reset MUST include the AXI interconnect/reader.
module rv64_scanout_control #(
 parameter [63:0] MMIO_BASE=64'h04000000
)(
 input wire bus_clk_i,pixel_clk_i,aresetn_i,
 input wire s_arvalid_i,output wire s_arready_o,input wire s_arid_i,
 input wire [63:0] s_araddr_i,input wire [7:0] s_arlen_i,input wire [2:0] s_arsize_i,
 input wire [1:0] s_arburst_i,input wire s_arlock_i,
 output wire s_rvalid_o,input wire s_rready_i,output wire s_rid_o,s_rlast_o,
 output wire [63:0] s_rdata_o,output wire [1:0] s_rresp_o,
 input wire s_awvalid_i,output wire s_awready_o,input wire s_awid_i,
 input wire [63:0] s_awaddr_i,input wire [7:0] s_awlen_i,input wire [2:0] s_awsize_i,
 input wire [1:0] s_awburst_i,input wire s_awlock_i,
 input wire s_wvalid_i,output wire s_wready_o,input wire [63:0] s_wdata_i,
 input wire [7:0] s_wstrb_i,input wire s_wlast_i,
 output wire s_bvalid_o,input wire s_bready_i,output wire s_bid_o,output wire [1:0] s_bresp_o,
 output wire cmd_valid_o,input wire cmd_ready_i,output wire [31:0] cmd_base_o,
 input wire reader_busy_i,input wire [191:0] bus_stats_i,
 // Low to high: CRC, started, good, bad, underflow, marker, dropped, pixels.
 input wire [255:0] video_status_i,
 output wire run_o,base_locked_o,snapshot_busy_o,snapshot_valid_o,
 output wire [31:0] snapshot_sequence_o
);
 (* ASYNC_REG="TRUE" *) reg [1:0] bus_release_q,pixel_release_q;
 // Intentional mixed use: local synchronous release drives both async CDC
 // reset and synchronous endpoint initialization, following frozen R99.
 /* verilator lint_off SYNCASYNCNET */
 (* ASYNC_REG="TRUE" *) reg bus_active,pixel_active;
 /* verilator lint_on SYNCASYNCNET */
 always @(posedge bus_clk_i or negedge aresetn_i)
  if(!aresetn_i)begin bus_release_q<=0;bus_active<=0;end
  else begin bus_release_q<={bus_release_q[0],1'b1};bus_active<=bus_release_q[1];end
 always @(posedge pixel_clk_i or negedge aresetn_i)
  if(!aresetn_i)begin pixel_release_q<=0;pixel_active<=0;end
  else begin pixel_release_q<={pixel_release_q[0],1'b1};pixel_active<=pixel_release_q[1];end
 reg request_q,ack_q;
 (* ASYNC_REG="TRUE" *) reg [2:0] request_sync_q,ack_sync_q;
 reg [255:0] pixel_hold_q;
 (* ASYNC_REG="TRUE" *) reg [255:0] data_meta_q,data_sync_q;
 always @(posedge pixel_clk_i or negedge pixel_active)begin
  if(!pixel_active)begin request_sync_q<=0;ack_q<=0;pixel_hold_q<=0;end
  else begin
   request_sync_q<={request_sync_q[1:0],request_q};
   if(request_sync_q[2]!=ack_q)begin
    pixel_hold_q<=video_status_i;
    ack_q<=request_sync_q[2];
   end
  end
 end
 always @(posedge bus_clk_i or negedge bus_active)begin
  if(!bus_active)begin ack_sync_q<=0;data_meta_q<=0;data_sync_q<=0;end
  else begin
   ack_sync_q<={ack_sync_q[1:0],ack_q};
   data_meta_q<=pixel_hold_q;data_sync_q<=data_meta_q;
  end
 end
 reg [31:0] base_q,issued_q,snapshot_sequence_q;
 reg configured_q,locked_q,run_q,cmd_pending_q,snapshot_busy_q,snapshot_valid_q;
 reg [255:0] snapshot_q;
 reg rvalid_q,rid_q,rbad_q;
 reg [63:0] rdata_q;
 reg [7:0] rlen_q,rbeat_q,wlen_q,wbeat_q;
 reg [1:0] wstate_q,bresp_q;
 reg wid_q,wbad_q,wupper_q;
 reg [2:0] wsize_q;
 reg [5:0] woffset_q;
 reg [31:0] commit_base_q;
 reg commit_base_en_q,commit_run_en_q,commit_run_q,commit_snapshot_q;
 localparam [1:0] W_IDLE=0,W_DATA=1,W_RESP=2;
 function automatic legal(input [63:0] a,input [7:0] n,input [2:0] size,
  input [1:0] burst,input lock);
  begin legal=a>=MMIO_BASE&&a<MMIO_BASE+64'h60&&n==0&&burst==1&&!lock&&
   ((size==2&&a[1:0]==0)||(size==3&&a[2:0]==0));end
 endfunction
 function automatic valid_base(input [31:0] value);
  begin valid_base=value[2:0]==0&&value>=32'h00200000&&value<=32'h07e2b400;end
 endfunction
 function automatic [31:0] read_word(input [5:0] offset);
  begin
   case(offset)
    0:read_word=32'h52313033;
    1:read_word=32'h00010001;
    2:read_word=base_q;
    3:read_word={31'd0,run_q};
    4:read_word={25'd0,configured_q,snapshot_valid_q,snapshot_busy_q,reader_busy_i,cmd_pending_q,locked_q,run_q};
    5:read_word=32'd1920000;
    6:read_word=0;
    7:read_word=snapshot_sequence_q;
    8,9,10,11,12,13,14,15:read_word=snapshot_q[(offset-8)*32+:32];
    16,17,18,19,20,21:read_word=bus_stats_i[(offset-16)*32+:32];
    22:read_word=issued_q;
    23:read_word=32'd40000000;
    default:read_word=0;
   endcase
  end
 endfunction
 wire ar_fire=s_arvalid_i&&s_arready_o;
 wire aw_fire=s_awvalid_i&&s_awready_o;
 wire w_fire=s_wvalid_i&&s_wready_o;
 wire b_fire=s_bvalid_o&&s_bready_i;
 wire r_fire=s_rvalid_o&&s_rready_i;
 wire cmd_fire=cmd_valid_o&&cmd_ready_i;
 wire [31:0] write_word=wupper_q?s_wdata_i[63:32]:s_wdata_i[31:0];
 wire [7:0] expected_strobe=wsize_q==3?8'hff:(wupper_q?8'hf0:8'h0f);
 wire write_base=woffset_q==2;
 wire write_run=(woffset_q==3)||(woffset_q==2&&wsize_q==3);
 wire write_snapshot=woffset_q==6;
 wire [31:0] write_run_value=(woffset_q==2&&wsize_q==3)?s_wdata_i[63:32]:write_word;
 reg [1:0] write_response;
 always @* begin
  write_response=0;
  if(wbad_q||!(write_base||write_run||write_snapshot))write_response=3;
  else if(s_wlast_i!=(wbeat_q==wlen_q)||s_wstrb_i!=expected_strobe)write_response=2;
  else if(write_base&&(locked_q||!valid_base(s_wdata_i[31:0])))write_response=2;
  else if(write_run&&(write_run_value>1||(write_run_value[0]&&!configured_q&&!write_base)))write_response=2;
  else if(write_snapshot&&(write_word!=1||snapshot_busy_q||(wsize_q==3&&s_wdata_i[63:32]!=0)))write_response=2;
 end
 assign s_arready_o=bus_active&&!rvalid_q;
 assign s_rvalid_o=bus_active&&rvalid_q;
 assign s_rid_o=rid_q;assign s_rlast_o=rbeat_q==rlen_q;
 assign s_rdata_o=rdata_q;assign s_rresp_o=rbad_q?2'b11:2'b00;
 assign s_awready_o=bus_active&&wstate_q==W_IDLE;
 assign s_wready_o=bus_active&&wstate_q==W_DATA;
 assign s_bvalid_o=bus_active&&wstate_q==W_RESP;
 assign s_bid_o=wid_q;assign s_bresp_o=bresp_q;
 assign cmd_valid_o=bus_active&&cmd_pending_q;
 assign cmd_base_o=base_q;
 assign run_o=bus_active&&run_q;assign base_locked_o=bus_active&&locked_q;
 assign snapshot_busy_o=bus_active&&snapshot_busy_q;
 assign snapshot_valid_o=bus_active&&snapshot_valid_q;
 assign snapshot_sequence_o=snapshot_sequence_q;
 wire stop_commit=b_fire&&bresp_q==0&&commit_run_en_q&&!commit_run_q;
 always @(posedge bus_clk_i or negedge bus_active)begin
  if(!bus_active)begin
   base_q<=0;configured_q<=0;locked_q<=0;run_q<=0;cmd_pending_q<=0;issued_q<=0;
   request_q<=0;snapshot_busy_q<=0;snapshot_valid_q<=0;snapshot_sequence_q<=0;snapshot_q<=0;
   rvalid_q<=0;rid_q<=0;rbad_q<=0;rdata_q<=0;rlen_q<=0;rbeat_q<=0;
   wstate_q<=W_IDLE;wid_q<=0;wbad_q<=0;wupper_q<=0;wsize_q<=0;woffset_q<=0;
   wlen_q<=0;wbeat_q<=0;bresp_q<=0;commit_base_q<=0;commit_base_en_q<=0;
   commit_run_en_q<=0;commit_run_q<=0;commit_snapshot_q<=0;
  end else begin
   if(ar_fire)begin
    rvalid_q<=1;rid_q<=s_arid_i;rlen_q<=s_arlen_i;rbeat_q<=0;
    rbad_q<=!legal(s_araddr_i,s_arlen_i,s_arsize_i,s_arburst_i,s_arlock_i);
    rdata_q<=0;
    if(legal(s_araddr_i,s_arlen_i,s_arsize_i,s_arburst_i,s_arlock_i))begin
     if(s_arsize_i==3)rdata_q<={read_word(s_araddr_i[7:2]+6'd1),read_word(s_araddr_i[7:2])};
     else if(s_araddr_i[2])rdata_q<={read_word(s_araddr_i[7:2]),32'd0};
     else rdata_q<={32'd0,read_word(s_araddr_i[7:2])};
    end
   end else if(r_fire)begin
    if(s_rlast_o)rvalid_q<=0;else rbeat_q<=rbeat_q+1'b1;
   end
   if(aw_fire)begin
    wstate_q<=W_DATA;wid_q<=s_awid_i;wlen_q<=s_awlen_i;wbeat_q<=0;
    woffset_q<=s_awaddr_i[7:2];wupper_q<=s_awaddr_i[2];wsize_q<=s_awsize_i;
    wbad_q<=!legal(s_awaddr_i,s_awlen_i,s_awsize_i,s_awburst_i,s_awlock_i);
    commit_base_en_q<=0;commit_run_en_q<=0;commit_snapshot_q<=0;
   end else if(w_fire)begin
    // Illegal bursts always drain exactly AWLEN+1, even with malformed WLAST.
    if(s_wlast_i!=(wbeat_q==wlen_q))wbad_q<=1;
    if(wbeat_q==wlen_q)begin
     wstate_q<=W_RESP;bresp_q<=write_response;
     if(write_response==0)begin
      commit_base_en_q<=write_base;commit_base_q<=s_wdata_i[31:0];
      commit_run_en_q<=write_run;commit_run_q<=write_run_value[0];
      commit_snapshot_q<=write_snapshot;
     end
    end else wbeat_q<=wbeat_q+1'b1;
   end else if(b_fire)begin
    wstate_q<=W_IDLE;
    if(bresp_q==0)begin
     if(commit_base_en_q)begin base_q<=commit_base_q;configured_q<=1;end
     if(commit_run_en_q)begin run_q<=commit_run_q;if(commit_run_q)locked_q<=1;end
     if(commit_snapshot_q)begin request_q<=!request_q;snapshot_busy_q<=1;end
    end
    commit_base_en_q<=0;commit_run_en_q<=0;commit_snapshot_q<=0;
   end
   if(!cmd_pending_q&&run_q&&!stop_commit)cmd_pending_q<=1;
   if(cmd_fire)begin cmd_pending_q<=0;issued_q<=issued_q+1'b1;end
   if(snapshot_busy_q&&ack_sync_q[2]==request_q)begin
    snapshot_q<=data_sync_q;snapshot_sequence_q<=snapshot_sequence_q+1'b1;
    snapshot_valid_q<=1;snapshot_busy_q<=0;
   end
  end
 end
`ifdef RV64_SCANOUT_CONTROL_FORMAL
 `include "formal/rv64/r103_scanout_control_properties.svh"
`endif
endmodule
