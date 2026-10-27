// R100 one-shot physical DDR AXI4 reader -> little-endian XRGB8888 words.
// One read burst outstanding. A fault drains to matching RID/RLAST; timeout
// NEVER withdraws ARVALID or invents transaction completion. Common bus reset
// is required if a faulty endpoint never completes. No vendor IP.
module rv64_frame_axi_reader #(
 parameter integer MAX_BURST_BEATS=16, // 1..16; AXI3-compatible burst length
 parameter integer TIMEOUT_CYCLES=4096,
 parameter [31:0] DDR_BASE=32'h00200000,
 parameter [31:0] DDR_LIMIT=32'h08000000 // exclusive, currently verified aperture
)(
 input wire clk_i,aresetn_i,
 input wire cmd_valid_i,output wire cmd_ready_o,
 input wire [31:0] cmd_base_i,cmd_bytes_i,
 output wire busy_o,output reg done_o,output wire success_o,
 output reg [4:0] error_o,
 output wire pixel_valid_o,input wire pixel_ready_i,
 output wire [31:0] pixel_data_o,output wire pixel_first_o,pixel_last_o,
 output wire m_arvalid_o,input wire m_arready_i,
 output wire m_arid_o,output wire [31:0] m_araddr_o,
 output wire [7:0] m_arlen_o,output wire [2:0] m_arsize_o,m_arprot_o,
 output wire [1:0] m_arburst_o,output wire m_arlock_o,output wire [3:0] m_arcache_o,
 input wire m_rvalid_i,output wire m_rready_o,
 input wire m_rid_i,m_rlast_i,input wire [63:0] m_rdata_i,input wire [1:0] m_rresp_i,
 output reg [31:0] stat_bursts_o,stat_beats_o,stat_pixels_o,stat_frames_o,stat_failed_o
);
 // Common bus reset asserts asynchronously, releases after three local edges.
 (* ASYNC_REG = "TRUE" *) reg [1:0] release_q;
 (* ASYNC_REG = "TRUE" *) reg bus_active;
 always @(posedge clk_i or negedge aresetn_i)
  if(!aresetn_i)begin release_q<=0;bus_active<=0;end
  else begin release_q<={release_q[0],1'b1};bus_active<=release_q[1];end
 localparam [2:0] IDLE=0,PLAN=1,ADDR=2,DATA=3,DRAIN=4,FINISH=5;
 localparam integer WAIT_BITS=TIMEOUT_CYCLES<2?1:$clog2(TIMEOUT_CYCLES);
 localparam [WAIT_BITS-1:0] WAIT_MAX=WAIT_BITS'(TIMEOUT_CYCLES-1);
 reg [2:0] state_q;
 reg [31:0] cursor_q,left_q,araddr_q;
 reg [4:0] burst_q,remaining_q;
 reg [WAIT_BITS-1:0] wait_q;
 reg [63:0] data_q;
 reg buffer_q,half_q,first_q,last_q,first_payload_q;
 wire [32:0] cmd_end={1'b0,cmd_base_i}+{1'b0,cmd_bytes_i};
 wire cmd_allowed=cmd_base_i>=DDR_BASE && cmd_end<={1'b0,DDR_LIMIT} &&
                   cmd_bytes_i!=0 && cmd_base_i[2:0]==0 && cmd_bytes_i[2:0]==0;
 wire [9:0] page_beats=10'd512-{1'b0,cursor_q[11:3]};
 reg [4:0] plan_beats;
 always @* begin
  plan_beats=5'(MAX_BURST_BEATS);
  if(left_q<{24'd0,plan_beats,3'b000}) plan_beats=left_q[7:3];
  if(page_beats<{5'd0,plan_beats}) plan_beats=page_beats[4:0];
 end
 wire cmd_fire=cmd_valid_i&&cmd_ready_o;
 wire ar_fire=m_arvalid_o&&m_arready_i;
 wire r_fire=m_rvalid_i&&m_rready_o;
 wire px_fire=pixel_valid_o&&pixel_ready_i;
 wire slot_free=!buffer_q||(half_q&&pixel_ready_i);
 wire r_end=!m_rid_i&&m_rlast_i;
 wire [4:0] r_errors={1'b0,m_rid_i,(!m_rid_i&&(m_rlast_i!=(remaining_q==1))),
                       (m_rresp_i!=2'b00),1'b0};
 wire r_good=(r_errors==0);
 wire waiting=(m_arvalid_o&&!m_arready_i)||
              ((state_q==DATA||state_q==DRAIN)&&m_rready_o&&!m_rvalid_i);
 wire timeout_hit=waiting&&wait_q==WAIT_MAX;
 assign cmd_ready_o=bus_active&&state_q==IDLE;
 assign busy_o=state_q!=IDLE;
 assign success_o=done_o&&error_o==0;
 assign pixel_valid_o=bus_active&&buffer_q;
 assign pixel_data_o=half_q ? data_q[63:32] : data_q[31:0];
 assign pixel_first_o=buffer_q&&first_q&&!half_q;
 assign pixel_last_o=buffer_q&&last_q&&half_q;
 assign m_arvalid_o=bus_active&&state_q==ADDR;
 assign m_araddr_o=araddr_q;
 assign m_arlen_o={3'b000,burst_q}-8'd1;
 assign m_arid_o=0;assign m_arsize_o=3;assign m_arprot_o=0;
 assign m_arburst_o=2'b01;assign m_arlock_o=0;assign m_arcache_o=4'b0011;
 assign m_rready_o=bus_active&&((state_q==DATA&&slot_free)||state_q==DRAIN);
 always @(posedge clk_i or negedge bus_active) begin
  if(!bus_active)begin
   state_q<=IDLE;cursor_q<=0;left_q<=0;araddr_q<=0;burst_q<=0;remaining_q<=0;wait_q<=0;
   data_q<=0;buffer_q<=0;half_q<=0;first_q<=0;last_q<=0;first_payload_q<=1;
   done_o<=0;error_o<=0;stat_bursts_o<=0;stat_beats_o<=0;stat_pixels_o<=0;
   stat_frames_o<=0;stat_failed_o<=0;
  end else begin
   done_o<=0;
   if(waiting)begin if(wait_q!=WAIT_MAX)wait_q<=wait_q+1'b1;end
   else wait_q<=0;
   if(timeout_hit)begin
    error_o<=error_o|5'b10000;
    if(state_q==DATA)state_q<=DRAIN;
   end
   if(ar_fire)stat_bursts_o<=stat_bursts_o+1'b1;
   if(r_fire)stat_beats_o<=stat_beats_o+1'b1;
   if(px_fire)begin
    stat_pixels_o<=stat_pixels_o+1'b1;
    if(half_q)begin buffer_q<=0;half_q<=0;end
    else half_q<=1;
   end
   case(state_q)
    IDLE:if(cmd_fire)begin
     error_o<=0;first_payload_q<=1;
     if(cmd_allowed)begin cursor_q<=cmd_base_i;left_q<=cmd_bytes_i;state_q<=PLAN;end
     else begin
      error_o<=5'b00001;done_o<=1;
      stat_frames_o<=stat_frames_o+1'b1;stat_failed_o<=stat_failed_o+1'b1;
     end
    end
    PLAN:begin araddr_q<=cursor_q;burst_q<=plan_beats;state_q<=ADDR;end
    ADDR:if(ar_fire)begin
     cursor_q<=cursor_q+{24'd0,burst_q,3'b000};
     left_q<=left_q-{24'd0,burst_q,3'b000};remaining_q<=burst_q;
     state_q<=error_o==0 ? DATA : DRAIN;
    end
    DATA:if(r_fire)begin
     if(!m_rid_i&&remaining_q!=0)remaining_q<=remaining_q-1'b1;
     if(!r_good)begin error_o<=error_o|r_errors;state_q<=r_end?FINISH:DRAIN;end
     else begin
      data_q<=m_rdata_i;buffer_q<=1;half_q<=0;
      first_q<=first_payload_q;first_payload_q<=0;
      last_q<=left_q==0&&remaining_q==1;
      if(m_rlast_i)state_q<=left_q==0?FINISH:PLAN;
     end
    end
    DRAIN:if(r_fire)begin
     error_o<=error_o|r_errors;
     if(!m_rid_i&&remaining_q!=0)remaining_q<=remaining_q-1'b1;
     if(r_end)state_q<=FINISH;
    end
    FINISH:if(!buffer_q||(px_fire&&half_q))begin
     done_o<=1;stat_frames_o<=stat_frames_o+1'b1;
     if(error_o!=0)stat_failed_o<=stat_failed_o+1'b1;
     state_q<=IDLE;
    end
    default:state_q<=IDLE;
   endcase
  end
 end
`ifdef RV64_FRAME_READER_FORMAL
`include "formal/rv64/r100_frame_reader_properties.svh"
`endif
endmodule
