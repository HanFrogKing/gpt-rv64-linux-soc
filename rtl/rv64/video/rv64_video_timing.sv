// Fixed 800x600 timing and diagnostic bars; one clock edge per pixel.
// No CPU/AXI backpressure may stop these counters. Clock generation and
// TMDS serialization belong to separate Windows board wrappers/modules.
module rv64_video_timing (
 input  wire        clk_i,
 input  wire        aresetn_i,
 output wire [10:0] hpos_o,
 output wire [9:0]  vpos_o,
 output wire        de_o,
 output wire        hsync_o,
 output wire        vsync_o,
 output wire        line_start_o,
 output wire        frame_start_o,
 output reg  [23:0] bars_rgb_o
);
 localparam [10:0] H_LAST=11'd1055;
 localparam [9:0] V_LAST=10'd627;
 reg [10:0] h_q;
 reg [9:0] v_q;

 // Park in the final blanking pixel. The first released rising edge
 // starts pixel (0,0), instead of truncating the first active line.
 always @(posedge clk_i or negedge aresetn_i) begin
  if(!aresetn_i) begin h_q<=H_LAST;v_q<=V_LAST;end
  else begin
   if(h_q==H_LAST) begin
    h_q<=0;
    v_q<=v_q==V_LAST?10'd0:v_q+10'd1;
   end else h_q<=h_q+11'd1;
  end
 end
 assign hpos_o=h_q;
 assign vpos_o=v_q;
 assign de_o=aresetn_i&&h_q<11'd800&&v_q<10'd600;
 assign hsync_o=aresetn_i&&h_q>=11'd840&&h_q<11'd968;
 assign vsync_o=aresetn_i&&v_q>=10'd601&&v_q<10'd605;
 assign line_start_o=aresetn_i&&h_q==0;
 assign frame_start_o=line_start_o&&v_q==0;
 always @* begin
  bars_rgb_o=24'h000000;
  if(de_o) begin
   if(h_q<11'd100) bars_rgb_o=24'hffffff;
   else if(h_q<11'd200) bars_rgb_o=24'hffff00;
   else if(h_q<11'd300) bars_rgb_o=24'h00ffff;
   else if(h_q<11'd400) bars_rgb_o=24'h00ff00;
   else if(h_q<11'd500) bars_rgb_o=24'hff00ff;
   else if(h_q<11'd600) bars_rgb_o=24'hff0000;
   else if(h_q<11'd700) bars_rgb_o=24'h0000ff;
  end
 end
`ifdef RV64_VIDEO_TIMING_FORMAL
 `include "formal/rv64/r95_video_timing_properties.svh"
`endif
endmodule
