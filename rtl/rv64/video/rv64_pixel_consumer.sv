// R101 fixed-cadence pixel consumer. Raster timing is an INPUT and is never
// stalled by this module. Vendor-free; same common reset as the pixel FIFO.
module rv64_pixel_consumer #(
 parameter integer FRAME_PIXELS=480000,
 parameter [23:0] ERROR_RGB=24'hff00ff
)(
 input wire clk_i,aresetn_i,
 input wire de_i,frame_start_i,
 input wire pixel_valid_i,output wire pixel_ready_o,
 input wire [31:0] pixel_data_i,input wire pixel_first_i,pixel_last_i,
 output wire [23:0] rgb_o,
 output reg crc_valid_o,output reg [31:0] frame_crc_o,
 output reg [31:0] stat_started_o,stat_good_o,stat_bad_o,
 output reg [31:0] stat_underflow_o,stat_marker_o,stat_dropped_o,stat_pixels_o
);
 (* ASYNC_REG="TRUE" *) reg [1:0] release_q;
 (* ASYNC_REG="TRUE" *) reg pixel_active;
 always @(posedge clk_i or negedge aresetn_i)
  if(!aresetn_i)begin release_q<=0;pixel_active<=0;end
  else begin release_q<={release_q[0],1'b1};pixel_active<=release_q[1];end
 localparam integer POS_BITS=FRAME_PIXELS<2?1:$clog2(FRAME_PIXELS);
 localparam [POS_BITS-1:0] FINAL_POS=POS_BITS'(FRAME_PIXELS-1);
 reg running_q;
 reg [POS_BITS-1:0] pos_q;
 reg [31:0] crc_q;
 wire slot=de_i&&(frame_start_i||running_q);
 wire expected_last=frame_start_i?(FRAME_PIXELS==1):(pos_q==FINAL_POS);
 wire markers_ok=(pixel_first_i==frame_start_i)&&(pixel_last_i==expected_last);
 wire good_pixel=pixel_active&&slot&&pixel_valid_i&&markers_ok;
 // When searching, discard stale tail but HOLD the next first pixel. An
 // unexpected first in a running frame is also held for the next frame start.
 assign pixel_ready_o=pixel_active&&(slot?(!pixel_first_i||frame_start_i):(!running_q&&!pixel_first_i));
 assign rgb_o=!pixel_active||!de_i?24'h000000:
              good_pixel?pixel_data_i[23:0]:ERROR_RGB;
 function automatic [31:0] crc_word(input [31:0] prior,input [31:0] data);
  reg [31:0] x;integer i;
  begin
   x=prior^data;
   for(i=0;i<32;i=i+1)x=x[0]?((x>>1)^32'hedb88320):(x>>1);
   crc_word=x;
  end
 endfunction
 wire [31:0] next_crc=crc_word(frame_start_i?32'hffffffff:crc_q,pixel_data_i);
 always @(posedge clk_i or negedge pixel_active)begin
  if(!pixel_active)begin
   running_q<=0;pos_q<=0;crc_q<=32'hffffffff;
   crc_valid_o<=0;frame_crc_o<=0;
   stat_started_o<=0;stat_good_o<=0;stat_bad_o<=0;
   stat_underflow_o<=0;stat_marker_o<=0;stat_dropped_o<=0;stat_pixels_o<=0;
  end else begin
   crc_valid_o<=0;
   if(pixel_valid_i&&pixel_ready_o&&!slot)stat_dropped_o<=stat_dropped_o+1'b1;
   // An unaligned tail at the first active slot is a dropped word too.
   if(slot&&frame_start_i&&pixel_valid_i&&!pixel_first_i)
    stat_dropped_o<=stat_dropped_o+1'b1;
   if(de_i&&frame_start_i)stat_started_o<=stat_started_o+1'b1;
   if(slot)begin
    if(good_pixel)begin
     stat_pixels_o<=stat_pixels_o+1'b1;crc_q<=next_crc;
     if(expected_last)begin
      running_q<=0;pos_q<=0;stat_good_o<=stat_good_o+1'b1;
      frame_crc_o<=~next_crc;crc_valid_o<=1;
     end else begin
      running_q<=1;pos_q<=frame_start_i?POS_BITS'(1):pos_q+1'b1;
     end
    end else begin
     running_q<=0;pos_q<=0;crc_q<=32'hffffffff;
     stat_bad_o<=stat_bad_o+1'b1;
     if(!pixel_valid_i)stat_underflow_o<=stat_underflow_o+1'b1;
     else stat_marker_o<=stat_marker_o+1'b1;
    end
   end
  end
 end
`ifdef RV64_PIXEL_CONSUMER_FORMAL
 `include "formal/rv64/r101_pixel_consumer_properties.svh"
`endif
endmodule
