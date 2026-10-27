// Windows-only 7-series serializer. No clocks generated here.
// Preconditions: phase-related pixel40MHz / serial200MHz; reset held >=2
// pixel edges and released synchronously to pixel clock by caller.
// word_i lane0=data0(B),lane1=data1(G),lane2=data2(R),lane3=clock.
// Each lane sends bit0 first. Never use CPU stall/ready as a clock enable.
module rv64_tmds_serializer_7series (
 input wire pixel_clk_i,
 input wire serial_clk_i,
 input wire reset_i,
 input wire [39:0] word_i,
 output wire [3:0] tmds_p_o,
 output wire [3:0] tmds_n_o
);
 genvar lane;
 generate for(lane=0;lane<4;lane=lane+1) begin: lanes
  wire [9:0] w=word_i[lane*10+:10];
  wire shift1,shift2,serial;
  OSERDESE2 #(.DATA_RATE_OQ("DDR"),.DATA_RATE_TQ("SDR"),.DATA_WIDTH(10),
   .SERDES_MODE("MASTER"),.TRISTATE_WIDTH(1),.INIT_OQ(1'b0),.SRVAL_OQ(1'b0),
   .INIT_TQ(1'b0),.SRVAL_TQ(1'b0),.TBYTE_CTL("FALSE"),.TBYTE_SRC("FALSE")) master (
   .CLK(serial_clk_i),.CLKDIV(pixel_clk_i),.RST(reset_i),.OCE(1'b1),
   .D1(w[0]),.D2(w[1]),.D3(w[2]),.D4(w[3]),
   .D5(w[4]),.D6(w[5]),.D7(w[6]),.D8(w[7]),
   .SHIFTIN1(shift1),.SHIFTIN2(shift2),.SHIFTOUT1(),.SHIFTOUT2(),
   .OQ(serial),.OFB(),.TQ(),.TFB(),.TBYTEOUT(),
   .T1(1'b0),.T2(1'b0),.T3(1'b0),.T4(1'b0),.TCE(1'b0),.TBYTEIN(1'b0));
  OSERDESE2 #(.DATA_RATE_OQ("DDR"),.DATA_RATE_TQ("SDR"),.DATA_WIDTH(10),
   .SERDES_MODE("SLAVE"),.TRISTATE_WIDTH(1),.INIT_OQ(1'b0),.SRVAL_OQ(1'b0),
   .INIT_TQ(1'b0),.SRVAL_TQ(1'b0),.TBYTE_CTL("FALSE"),.TBYTE_SRC("FALSE")) slave (
   .CLK(serial_clk_i),.CLKDIV(pixel_clk_i),.RST(reset_i),.OCE(1'b1),
   .D1(1'b0),.D2(1'b0),.D3(w[8]),.D4(w[9]),
   .D5(1'b0),.D6(1'b0),.D7(1'b0),.D8(1'b0),
   .SHIFTIN1(1'b0),.SHIFTIN2(1'b0),.SHIFTOUT1(shift1),.SHIFTOUT2(shift2),
   .OQ(),.OFB(),.TQ(),.TFB(),.TBYTEOUT(),
   .T1(1'b0),.T2(1'b0),.T3(1'b0),.T4(1'b0),.TCE(1'b0),.TBYTEIN(1'b0));
  OBUFDS #(.IOSTANDARD("TMDS_33"),.SLEW("FAST")) output_buffer (
   .I(serial),.O(tmds_p_o[lane]),.OB(tmds_n_o[lane]));
 end endgenerate
endmodule
