// R102 structural DDR->34bit FIFO->fixed raster->TMDS scanout. No vendor IP.
// Raw statistics are explicitly domain-local, NOT safe unsynchronized MMIO.
module rv64_ddr_scanout #(
 parameter integer FIFO_ADDR_BITS=10
)(
 input wire bus_clk_i,pixel_clk_i,aresetn_i,
 input wire cmd_valid_i,output wire cmd_ready_o,input wire [31:0] cmd_base_i,
 output wire reader_busy_o,queued_done_o,queued_success_o,output wire [4:0] reader_error_o,
 output wire m_arvalid_o,input wire m_arready_i,
 output wire m_arid_o,output wire [31:0] m_araddr_o,
 output wire [7:0] m_arlen_o,output wire [2:0] m_arsize_o,m_arprot_o,
 output wire [1:0] m_arburst_o,output wire m_arlock_o,output wire [3:0] m_arcache_o,
 input wire m_rvalid_i,output wire m_rready_o,
 input wire m_rid_i,m_rlast_i,input wire [63:0] m_rdata_i,input wire [1:0] m_rresp_i,
 output wire [31:0] bus_bursts_o,bus_beats_o,bus_pixels_o,bus_frames_o,bus_failed_o,
 output wire video_de_o,video_hsync_o,video_vsync_o,video_frame_start_o,
 output wire [10:0] video_hpos_o,output wire [9:0] video_vpos_o,
 output wire [23:0] video_rgb_o,
 output wire [9:0] tmds_blue_o,tmds_green_o,tmds_red_o,
 output wire video_crc_valid_o,output wire [31:0] video_crc_o,
 output wire [31:0] video_started_o,video_good_o,video_bad_o,
 output wire [31:0] video_underflow_o,video_marker_o,video_dropped_o,video_pixels_o
);
 (* ASYNC_REG="TRUE" *) reg [1:0] video_release_q;
 // Intentional mixed use: async raster/TMDS flush, synchronous elastic-stage
 // initialization, matching the established R99 common-reset release contract.
 /* verilator lint_off SYNCASYNCNET */
 (* ASYNC_REG="TRUE" *) reg video_resetn;
 /* verilator lint_on SYNCASYNCNET */
 always @(posedge pixel_clk_i or negedge aresetn_i)
  if(!aresetn_i)begin video_release_q<=0;video_resetn<=0;end
  else begin video_release_q<={video_release_q[0],1'b1};video_resetn<=video_release_q[1];end
 // Synchronously reset elastic interfaces keep asynchronous control out of
 // the inferred BRAM enables. Old staged data during common reset is invalid;
 // all three local release edges initialize these stages before fresh traffic.
 (* ASYNC_REG="TRUE" *) reg [1:0] bus_release_q;
 (* ASYNC_REG="TRUE" *) reg bus_pipe_active;
 always @(posedge bus_clk_i or negedge aresetn_i)
  if(!aresetn_i)begin bus_release_q<=0;bus_pipe_active<=0;end
  else begin bus_release_q<={bus_release_q[0],1'b1};bus_pipe_active<=bus_release_q[1];end
 wire reader_pixel_valid,reader_pixel_ready,reader_first,reader_last;
 wire [31:0] reader_pixel_data;
 wire fifo_valid,fifo_ready,fifo_write_ready;
 wire [33:0] fifo_data;
 reg write_valid_q;
 reg [33:0] write_data_q;
 wire write_slot=!write_valid_q||fifo_write_ready;
 assign reader_pixel_ready=write_slot;
 always @(posedge bus_clk_i)
  if(!bus_pipe_active)write_valid_q<=0;
  else if(write_slot)begin
   write_valid_q<=reader_pixel_valid;
   if(reader_pixel_valid)write_data_q<={reader_last,reader_first,reader_pixel_data};
  end
 // Two read-side words sustain one pixel/edge without a combinational path
 // from consumer_ready (asynchronously reset logic) to RAM read enable.
 reg [1:0] read_count_q;
 reg read_head_q,read_tail_q;
 reg [33:0] read_data_q [0:1];
 wire consumer_valid=read_count_q!=0;
 wire consumer_ready;
 wire [33:0] consumer_data=read_data_q[read_head_q];
 assign fifo_ready=read_count_q<2;
 wire read_push=fifo_valid&&fifo_ready;
 wire read_pop=consumer_valid&&consumer_ready;
 always @(posedge pixel_clk_i)begin
  if(!video_resetn)begin read_count_q<=0;read_head_q<=0;read_tail_q<=0;end
  else begin
   case({read_push,read_pop})
    2'b10:read_count_q<=read_count_q+1'b1;
    2'b01:read_count_q<=read_count_q-1'b1;
    default:begin end
   endcase
   if(read_push)begin read_data_q[read_tail_q]<=fifo_data;read_tail_q<=!read_tail_q;end
   if(read_pop)read_head_q<=!read_head_q;
  end
 end
 wire unused_line;wire [23:0] unused_bars;
 rv64_frame_axi_reader #(.MAX_BURST_BEATS(16),.TIMEOUT_CYCLES(4096),
  .DDR_BASE(32'h00200000),.DDR_LIMIT(32'h08000000)) reader (
 .clk_i(bus_clk_i),.aresetn_i(aresetn_i),
 .cmd_valid_i(cmd_valid_i),.cmd_ready_o(cmd_ready_o),.cmd_base_i(cmd_base_i),.cmd_bytes_i(32'd1920000),
 .busy_o(reader_busy_o),.done_o(queued_done_o),.success_o(queued_success_o),.error_o(reader_error_o),
 .pixel_valid_o(reader_pixel_valid),.pixel_ready_i(reader_pixel_ready),
 .pixel_data_o(reader_pixel_data),.pixel_first_o(reader_first),.pixel_last_o(reader_last),
 .m_arvalid_o(m_arvalid_o),.m_arready_i(m_arready_i),.m_arid_o(m_arid_o),.m_araddr_o(m_araddr_o),
 .m_arlen_o(m_arlen_o),.m_arsize_o(m_arsize_o),.m_arprot_o(m_arprot_o),.m_arburst_o(m_arburst_o),
 .m_arlock_o(m_arlock_o),.m_arcache_o(m_arcache_o),.m_rvalid_i(m_rvalid_i),.m_rready_o(m_rready_o),
 .m_rid_i(m_rid_i),.m_rlast_i(m_rlast_i),.m_rdata_i(m_rdata_i),.m_rresp_i(m_rresp_i),
 .stat_bursts_o(bus_bursts_o),.stat_beats_o(bus_beats_o),.stat_pixels_o(bus_pixels_o),
 .stat_frames_o(bus_frames_o),.stat_failed_o(bus_failed_o));
 rv64_pixel_async_fifo #(.DATA_WIDTH(34),.ADDR_BITS(FIFO_ADDR_BITS)) fifo (
 .aresetn_i(aresetn_i),.wr_clk_i(bus_clk_i),.wr_valid_i(write_valid_q),
 .wr_data_i(write_data_q),.wr_ready_o(fifo_write_ready),
 .rd_clk_i(pixel_clk_i),.rd_valid_o(fifo_valid),.rd_data_o(fifo_data),.rd_ready_i(fifo_ready));
 rv64_video_timing timing (
 .clk_i(pixel_clk_i),.aresetn_i(video_resetn),.hpos_o(video_hpos_o),.vpos_o(video_vpos_o),
 .de_o(video_de_o),.hsync_o(video_hsync_o),.vsync_o(video_vsync_o),
 .line_start_o(unused_line),.frame_start_o(video_frame_start_o),.bars_rgb_o(unused_bars));
 rv64_pixel_consumer #(.FRAME_PIXELS(480000),.ERROR_RGB(24'hff00ff)) consumer (
 .clk_i(pixel_clk_i),.aresetn_i(aresetn_i),.de_i(video_de_o),.frame_start_i(video_frame_start_o),
 .pixel_valid_i(consumer_valid),.pixel_ready_o(consumer_ready),.pixel_data_i(consumer_data[31:0]),
 .pixel_first_i(consumer_data[32]),.pixel_last_i(consumer_data[33]),.rgb_o(video_rgb_o),
 .crc_valid_o(video_crc_valid_o),.frame_crc_o(video_crc_o),.stat_started_o(video_started_o),
 .stat_good_o(video_good_o),.stat_bad_o(video_bad_o),.stat_underflow_o(video_underflow_o),
 .stat_marker_o(video_marker_o),.stat_dropped_o(video_dropped_o),.stat_pixels_o(video_pixels_o));
 rv64_tmds_encoder blue (
 .clk_i(pixel_clk_i),.aresetn_i(video_resetn),.pixel_i(video_rgb_o[7:0]),.de_i(video_de_o),
 .control_i({video_vsync_o,video_hsync_o}),.symbol_o(tmds_blue_o));
 rv64_tmds_encoder green (
 .clk_i(pixel_clk_i),.aresetn_i(video_resetn),.pixel_i(video_rgb_o[15:8]),.de_i(video_de_o),
 .control_i(2'b00),.symbol_o(tmds_green_o));
 rv64_tmds_encoder red (
 .clk_i(pixel_clk_i),.aresetn_i(video_resetn),.pixel_i(video_rgb_o[23:16]),.de_i(video_de_o),
 .control_i(2'b00),.symbol_o(tmds_red_o));
 wire unused=&{1'b0,unused_line,unused_bars};
`ifdef RV64_SCANOUT_FORMAL
 `include "formal/rv64/r102_scanout_properties.svh"
`endif
endmodule
