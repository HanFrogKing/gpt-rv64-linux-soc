// DVI 1.0 Figure 3-5. One pixel-clock register stage, no clock enable.
// Parallel bus [9:0]; the separate serializer must transmit bit0 first.
module rv64_tmds_encoder (
 input wire clk_i,
 input wire aresetn_i,
 input wire [7:0] pixel_i,
 input wire de_i,
 input wire [1:0] control_i,
 output reg [9:0] symbol_o
);
 localparam [9:0] CTRL00=10'b1101010100;
 reg signed [5:0] disparity_q,disparity_d;
 reg [8:0] qm;
 reg [9:0] symbol_d;
 integer k;
 function automatic [3:0] ones8(input [7:0] d);
  integer j;
  begin ones8=0;for(j=0;j<8;j=j+1)ones8=ones8+{3'd0,d[j]};end
 endfunction
 wire [3:0] ones_data=ones8(pixel_i);
 wire xnor_select=ones_data>4||(ones_data==4&&!pixel_i[0]);
 always @* begin
  qm[0]=pixel_i[0];
  for(k=1;k<8;k=k+1)qm[k]=qm[k-1]^pixel_i[k]^xnor_select;
  qm[8]=!xnor_select;
 end
 wire signed [5:0] balance=$signed({1'b0,ones8(qm[7:0]),1'b0})-6'sd8;
 always @* begin
  disparity_d=6'sd0;
  case(control_i)
   2'b00:symbol_d=CTRL00;
   2'b01:symbol_d=10'b0010101011;
   2'b10:symbol_d=10'b0101010100;
   default:symbol_d=10'b1010101011;
  endcase
  if(de_i)begin
   if(disparity_q==0||balance==0)begin
    symbol_d={!qm[8],qm[8],qm[7:0]^{8{!qm[8]}}};
    disparity_d=disparity_q+(qm[8]?balance:-balance);
   end else if((disparity_q>0&&balance>0)||(disparity_q<0&&balance<0))begin
    symbol_d={1'b1,qm[8],~qm[7:0]};
    disparity_d=disparity_q+(qm[8]?6'sd2:6'sd0)-balance;
   end else begin
    symbol_d={1'b0,qm[8],qm[7:0]};
    disparity_d=disparity_q+balance-(qm[8]?6'sd0:6'sd2);
   end
  end
 end
 always @(posedge clk_i or negedge aresetn_i)begin
  if(!aresetn_i)begin symbol_o<=CTRL00;disparity_q<=6'sd0;end
  else begin symbol_o<=symbol_d;disparity_q<=disparity_d;end
 end
`ifdef RV64_TMDS_FORMAL
 `include "formal/rv64/r96_tmds_properties.svh"
`endif
endmodule
