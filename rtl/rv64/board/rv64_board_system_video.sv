// R105 structural CPU/control/scanout integration, independent CPU and display AXI ports.
// Two structural layers flattened mechanically; all functional children retained.
// Common synchronous domain and shared cold/quiescent reset for ALL endpoints.
// PS GP0/HP0 width/protocol/CDC IP belongs to the independent Windows design.
// sources_i are synchronous to clk_i. Board PS-to-PL CDC is outside this module.
// Sources 1..31 feed one M and one S PLIC context; no direct interrupt bypass.
module rv64_board_system_video #(parameter integer TICK_DIV=50) (
 input logic clk_i,
 input logic pixel_clk_i,
 input logic aresetn_i,
 input logic [31:1] sources_i,
 output logic irq_meip_o,irq_seip_o,
 output logic commit_valid_o,
 input logic commit_ready_i,
 output logic [63:0] commit_order_o,
 output logic [63:0] commit_pc_o,
 output logic [63:0] commit_next_pc_o,
 output logic [31:0] commit_insn_o,
 output logic [4:0] commit_rd_o,
 output logic [4:0] commit_rs1_o,
 output logic [4:0] commit_rs2_o,
 output logic [63:0] commit_wdata_o,
 output logic [63:0] commit_rs1_data_o,
 output logic [63:0] commit_rs2_data_o,
 output logic commit_trap_o,
 output logic commit_unsupported_o,
 output logic [63:0] commit_cause_o,
 output logic [63:0] commit_tval_o,
 output logic halted_o,
 output logic memory_fatal_o,
 output logic [1:0] commit_privilege_o,
 output logic memory_ptw_o,
 output logic bus_ptw_o,
 output logic [31:0] icache_req_o,
 output logic [31:0] icache_hit_o,
 output logic [31:0] icache_miss_o,
 output logic [31:0] icache_refill_o,
 output logic [31:0] icache_bypass_o,
 output logic [31:0] icache_inv_o,
 output logic [31:0] icache_error_o,
 output logic [31:0] fence_start_o,
 output logic [31:0] fence_clean_o,
 output logic [31:0] fence_inv_o,
 output logic [31:0] fence_complete_o,
 output logic [31:0] dcache_req_o,
 output logic [31:0] dcache_hit_o,
 output logic [31:0] dcache_miss_o,
 output logic [31:0] dcache_refill_o,
 output logic [31:0] dcache_writeback_o,
 output logic [31:0] dcache_bypass_o,
 output logic [31:0] dcache_clean_o,
 output logic [31:0] dcache_error_o,
 output logic [63:0] dcache_fault_addr_o,
 output logic [1:0] dcache_fault_resp_o,
 output logic dcache_fault_write_o,
 output logic [31:0] arb_i_req_o,
 output logic [31:0] arb_d_req_o,
 output logic [31:0] arb_error_o,
 output logic [31:0] arb_i_wait_o,
 output logic [31:0] arb_d_wait_o,
 output logic [2:0] stage_valid_o,
 output logic [63:0] fetch_pc_o,
 output logic [63:0] execute_pc_o,
 output logic [63:0] retire_pc_o,
 output logic [63:0] fetch_seq_o,
 output logic [63:0] execute_seq_o,
 output logic [63:0] retire_seq_o,
 output logic [63:0] epoch_o,
 output logic [63:0] stat_overlap_o,
 output logic [63:0] stat_prefetch_o,
 output logic [63:0] stat_issue_prefetched_o,
 output logic [63:0] stat_killed_o,
 output logic [63:0] stat_forward_o,
 output logic [63:0] stat_branch_o,
 output logic [63:0] stat_prediction_hit_o,
 output logic [63:0] stat_prediction_taken_o,
 output logic [63:0] stat_mispredict_o,
 output logic [63:0] execute_epoch_o,
 output logic [63:0] retire_epoch_o,
 output logic [3:0] frontend_valid_o,
 output logic [63:0] f0_seq_o,
 output logic [63:0] f1_seq_o,
 output logic [63:0] f2_seq_o,
 output logic [63:0] f3_seq_o,
 output logic [2:0] fetch_outstanding_o,
 output logic [5:0] backend_valid_o,
 output logic [63:0] resolve_pc_o,
 output logic [63:0] resolve_seq_o,
 output logic [63:0] decode_pc_o,
 output logic [63:0] issue_pc_o,
 output logic [63:0] alu_pc_o,
 output logic [63:0] decode_seq_o,
 output logic [63:0] issue_seq_o,
 output logic [63:0] alu_seq_o,
 output logic [63:0] stat_raw_stall_o,
 output logic [63:0] stat_issue_o,
 output logic [63:0] stat_consecutive_issue_o,
 output logic commit_second_valid_o,
 output logic [63:0] commit_second_order_o,
 output logic [63:0] commit_second_pc_o,
 output logic [63:0] commit_second_next_pc_o,
 output logic [31:0] commit_second_insn_o,
 output logic [4:0] commit_second_rd_o,
 output logic [4:0] commit_second_rs1_o,
 output logic [4:0] commit_second_rs2_o,
 output logic [63:0] commit_second_wdata_o,
 output logic [63:0] commit_second_rs1_data_o,
 output logic [63:0] commit_second_rs2_data_o,
 output logic [1:0] commit_second_privilege_o,
 output logic [63:0] stat_dual_issue_o,
 output logic [63:0] stat_dual_retire_o,
 output logic [5:0] backend_second_valid_o,
 output logic [63:0] stat_execute_retire_o,
 output logic [63:0] stat_execute_retire_fire_o,
 output logic ddr_arvalid_o,
 output logic ddr_arid_o,
 output logic [31:0] ddr_araddr_o,
 output logic [7:0] ddr_arlen_o,
 output logic [2:0] ddr_arsize_o,
 output logic [2:0] ddr_arprot_o,
 output logic [1:0] ddr_arburst_o,
 output logic ddr_arlock_o,
 output logic [3:0] ddr_arcache_o,
 output logic ddr_rready_o,
 output logic ddr_awvalid_o,
 output logic ddr_awid_o,
 output logic [31:0] ddr_awaddr_o,
 output logic [7:0] ddr_awlen_o,
 output logic [2:0] ddr_awsize_o,
 output logic [2:0] ddr_awprot_o,
 output logic [1:0] ddr_awburst_o,
 output logic ddr_awlock_o,
 output logic [3:0] ddr_awcache_o,
 output logic ddr_wvalid_o,
 output logic [63:0] ddr_wdata_o,
 output logic [7:0] ddr_wstrb_o,
 output logic ddr_wlast_o,
 output logic ddr_bready_o,
 input logic ddr_arready_i,
 input logic ddr_rvalid_i,
 input logic ddr_rid_i,
 input logic ddr_rlast_i,
 input logic [63:0] ddr_rdata_i,
 input logic [1:0] ddr_rresp_i,
 input logic ddr_awready_i,
 input logic ddr_wready_i,
 input logic ddr_bvalid_i,
 input logic ddr_bid_i,
 input logic [1:0] ddr_bresp_i,
 output logic ps_arvalid_o,
 output logic ps_arid_o,
 output logic [31:0] ps_araddr_o,
 output logic [7:0] ps_arlen_o,
 output logic [2:0] ps_arsize_o,
 output logic [2:0] ps_arprot_o,
 output logic [1:0] ps_arburst_o,
 output logic ps_arlock_o,
 output logic [3:0] ps_arcache_o,
 output logic ps_rready_o,
 output logic ps_awvalid_o,
 output logic ps_awid_o,
 output logic [31:0] ps_awaddr_o,
 output logic [7:0] ps_awlen_o,
 output logic [2:0] ps_awsize_o,
 output logic [2:0] ps_awprot_o,
 output logic [1:0] ps_awburst_o,
 output logic ps_awlock_o,
 output logic [3:0] ps_awcache_o,
 output logic ps_wvalid_o,
 output logic [63:0] ps_wdata_o,
 output logic [7:0] ps_wstrb_o,
 output logic ps_wlast_o,
 output logic ps_bready_o,
 input logic ps_arready_i,
 input logic ps_rvalid_i,
 input logic ps_rid_i,
 input logic ps_rlast_i,
 input logic [63:0] ps_rdata_i,
 input logic [1:0] ps_rresp_i,
 input logic ps_awready_i,
 input logic ps_wready_i,
 input logic ps_bvalid_i,
 input logic ps_bid_i,
 input logic [1:0] ps_bresp_i,
 output logic irq_msip_o,
 output logic irq_mtip_o,
 output logic [63:0] time_o,
 output logic [31:0] dma_maint_count_o,dma_maint_error_o,
 output logic dma_busy_o,dma_done_o,dma_error_o,dma_fatal_o,
 output logic scan_reader_busy_o,
 output logic scan_queued_done_o,
 output logic scan_queued_success_o,
 output logic [4:0] scan_reader_error_o,
 output logic scan_arvalid_o,
 input logic scan_arready_i,
 output logic scan_arid_o,
 output logic [31:0] scan_araddr_o,
 output logic [7:0] scan_arlen_o,
 output logic [2:0] scan_arsize_o,
 output logic [2:0] scan_arprot_o,
 output logic [1:0] scan_arburst_o,
 output logic scan_arlock_o,
 output logic [3:0] scan_arcache_o,
 input logic scan_rvalid_i,
 output logic scan_rready_o,
 input logic scan_rid_i,
 input logic scan_rlast_i,
 input logic [63:0] scan_rdata_i,
 input logic [1:0] scan_rresp_i,
 output logic [31:0] scan_bus_bursts_o,
 output logic [31:0] scan_bus_beats_o,
 output logic [31:0] scan_bus_pixels_o,
 output logic [31:0] scan_bus_frames_o,
 output logic [31:0] scan_bus_failed_o,
 output logic video_de_o,
 output logic video_hsync_o,
 output logic video_vsync_o,
 output logic video_frame_start_o,
 output logic [10:0] video_hpos_o,
 output logic [9:0] video_vpos_o,
 output logic [23:0] video_rgb_o,
 output logic [9:0] tmds_blue_o,
 output logic [9:0] tmds_green_o,
 output logic [9:0] tmds_red_o,
 output logic video_crc_valid_o,
 output logic [31:0] video_crc_o,
 output logic [31:0] video_started_o,
 output logic [31:0] video_good_o,
 output logic [31:0] video_bad_o,
 output logic [31:0] video_underflow_o,
 output logic [31:0] video_marker_o,
 output logic [31:0] video_dropped_o,
 output logic [31:0] video_pixels_o,
 output logic ctrl_run_o,ctrl_locked_o,ctrl_snapshot_busy_o,ctrl_snapshot_valid_o,
 output logic [31:0] ctrl_snapshot_sequence_o
);

 wire video_cmd_valid,video_cmd_ready; wire [31:0] video_cmd_base;
 logic dma_valid,dma_ready,dma_done,dma_ack;
 logic [63:0] dma_address;
 logic [1:0] dma_op,dma_response;
 logic cpu_arvalid_o;
 logic cpu_arready_i;
 logic cpu_arid_o;
 logic [63:0] cpu_araddr_o;
 logic [7:0] cpu_arlen_o;
 logic [2:0] cpu_arsize_o;
 logic [2:0] cpu_arprot_o;
 logic [1:0] cpu_arburst_o;
 logic cpu_arlock_o;
 logic [3:0] cpu_arcache_o;
 logic cpu_rvalid_i;
 logic cpu_rready_o;
 logic cpu_rid_i;
 logic cpu_rlast_i;
 logic [63:0] cpu_rdata_i;
 logic [1:0] cpu_rresp_i;
 logic cpu_awvalid_o;
 logic cpu_awready_i;
 logic cpu_awid_o;
 logic [63:0] cpu_awaddr_o;
 logic [7:0] cpu_awlen_o;
 logic [2:0] cpu_awsize_o;
 logic [2:0] cpu_awprot_o;
 logic [1:0] cpu_awburst_o;
 logic cpu_awlock_o;
 logic [3:0] cpu_awcache_o;
 logic cpu_wvalid_o;
 logic cpu_wready_i;
 logic [63:0] cpu_wdata_o;
 logic [7:0] cpu_wstrb_o;
 logic cpu_wlast_o;
 logic cpu_bvalid_i;
 logic cpu_bready_o;
 logic cpu_bid_i;
 logic [1:0] cpu_bresp_i;
   logic c__i_axi_arvalid_o;
  logic c__i_axi_arready_i;
  logic [63:0] c__i_axi_araddr_o;
  logic [2:0] c__i_axi_arprot_o;
  logic c__i_axi_rvalid_i;
  logic c__i_axi_rready_o;
  logic [63:0] c__i_axi_rdata_i;
  logic [1:0] c__i_axi_rresp_i;
  logic c__d_axi_arvalid_o;
  logic c__d_axi_arready_i;
  logic c__d_axi_arid_o;
  logic [63:0] c__d_axi_araddr_o;
  logic [7:0] c__d_axi_arlen_o;
  logic [2:0] c__d_axi_arsize_o, c__d_axi_arprot_o;
  logic [1:0] c__d_axi_arburst_o;
  logic c__d_axi_arlock_o;
  logic [3:0] c__d_axi_arcache_o;
  logic c__d_axi_rvalid_i;
  logic c__d_axi_rready_o;
  logic c__d_axi_rid_i, c__d_axi_rlast_i;
  logic [63:0] c__d_axi_rdata_i;
  logic [1:0] c__d_axi_rresp_i;
  logic c__d_axi_awvalid_o;
  logic c__d_axi_awready_i;
  logic c__d_axi_awid_o;
  logic [63:0] c__d_axi_awaddr_o;
  logic [7:0] c__d_axi_awlen_o;
  logic [2:0] c__d_axi_awsize_o, c__d_axi_awprot_o;
  logic [1:0] c__d_axi_awburst_o;
  logic c__d_axi_awlock_o;
  logic [3:0] c__d_axi_awcache_o;
  logic c__d_axi_wvalid_o;
  logic c__d_axi_wready_i;
  logic [63:0] c__d_axi_wdata_o;
  logic [7:0] c__d_axi_wstrb_o;
  logic c__d_axi_wlast_o;
  logic c__d_axi_bvalid_i;
  logic c__d_axi_bready_o;
  logic c__d_axi_bid_i;
  logic [1:0] c__d_axi_bresp_i;


  logic c__core_fatal, c__icache_fatal, c__dcache_fatal, c__arb_fatal;
  logic c__core_commit_valid, c__core_commit_ready;
  logic c__core_commit_second_valid;
  assign commit_second_valid_o=commit_valid_o && c__core_commit_second_valid;
  logic c__clean_valid, c__clean_ready, c__clean_done, c__clean_ack, c__inv_valid, c__inv_ready, c__inv_done, c__inv_ack;
  wire c__unused_i_rsp_error, c__unused_d_rsp_error;
  logic  c__raw_i_arready;
  logic  c__ci_req_valid;
  logic [63:0] c__ci_addr;
  logic [2:0] c__ci_prot;
  logic  c__ci_line;
  logic  c__ci_rsp_valid;
  logic  c__ci_rsp_ready;
  logic [255:0] c__ci_rsp_data;
  logic [1:0] c__ci_rsp_resp;
  logic  c__raw_d_arready;
  logic  c__raw_d_awready;
  logic  c__raw_d_wready;
  logic  c__cd_req_valid;
  logic  c__cd_req_write;
  logic  c__cd_req_lock;
  logic  c__cd_req_ptw;
  logic [63:0] c__cd_req_addr;
  logic [2:0] c__cd_req_size;
  logic [2:0] c__cd_req_prot;
  logic [7:0] c__cd_req_len;
  logic [3:0] c__cd_req_cache;
  logic [255:0] c__cd_req_wdata;
  logic [31:0] c__cd_req_wstrb;
  logic  c__cd_rsp_valid;
  logic  c__cd_rsp_ready;
  logic [255:0] c__cd_rsp_data;
  logic [1:0] c__cd_rsp_resp;
  logic  c__ci_req_ready;
  logic  c__cd_req_ready;
  assign memory_fatal_o=c__core_fatal || c__icache_fatal || c__dcache_fatal || c__arb_fatal;
  assign c__i_axi_arready_i=c__raw_i_arready && !memory_fatal_o;
  assign c__d_axi_arready_i=c__raw_d_arready && !memory_fatal_o;
  assign c__d_axi_awready_i=c__raw_d_awready && !memory_fatal_o;
  assign c__d_axi_wready_i=c__raw_d_wready && !memory_fatal_o;
  rv64_dual_core #(.ENABLE_C(1),.ENABLE_FP(1),.ENABLE_BP(1),.RESET_PC(64'h1000),.ENABLE_PRIV(1),.ENABLE_SU(1),.HAS_MMU(1),.ENABLE_A(1),.ATOMIC_RAM_BASE(64'h80000000),.ATOMIC_RAM_BYTES(64'h08000000)) core (
    .frontend_valid_o(frontend_valid_o),.f0_seq_o(f0_seq_o),.f1_seq_o(f1_seq_o),.f2_seq_o(f2_seq_o),.f3_seq_o(f3_seq_o),.fetch_outstanding_o(fetch_outstanding_o),
    .resolve_pc_o(resolve_pc_o),.resolve_seq_o(resolve_seq_o),.backend_valid_o(backend_valid_o),.decode_pc_o(decode_pc_o),.issue_pc_o(issue_pc_o),.alu_pc_o(alu_pc_o),
    .decode_seq_o(decode_seq_o),.issue_seq_o(issue_seq_o),.alu_seq_o(alu_seq_o),
    .stat_raw_stall_o(stat_raw_stall_o),.stat_issue_o(stat_issue_o),.stat_consecutive_issue_o(stat_consecutive_issue_o),
    .clk_i(clk_i),
    .aresetn_i(aresetn_i),
    .irq_msip_i(irq_msip_o),
    .irq_mtip_i(irq_mtip_o),
    .irq_meip_i(irq_meip_o),
    .irq_seip_i(irq_seip_o),
    .time_i(time_o),
    .m_axi_arvalid_o(c__i_axi_arvalid_o),
    .m_axi_arready_i(c__i_axi_arready_i),
    .m_axi_araddr_o(c__i_axi_araddr_o),
    .m_axi_arprot_o(c__i_axi_arprot_o),
    .m_axi_rvalid_i(c__i_axi_rvalid_i),
    .m_axi_rready_o(c__i_axi_rready_o),
    .m_axi_rdata_i(c__i_axi_rdata_i),
    .m_axi_rresp_i(c__i_axi_rresp_i),
    .commit_valid_o(c__core_commit_valid),
    .commit_second_valid_o(c__core_commit_second_valid),
    .commit_second_order_o(commit_second_order_o),
    .commit_second_pc_o(commit_second_pc_o),
    .commit_second_next_pc_o(commit_second_next_pc_o),
    .commit_second_insn_o(commit_second_insn_o),
    .commit_second_rd_o(commit_second_rd_o),
    .commit_second_rs1_o(commit_second_rs1_o),
    .commit_second_rs2_o(commit_second_rs2_o),
    .commit_second_wdata_o(commit_second_wdata_o),
    .commit_second_rs1_data_o(commit_second_rs1_data_o),
    .commit_second_rs2_data_o(commit_second_rs2_data_o),
    .commit_second_privilege_o(commit_second_privilege_o),
    .stat_dual_issue_o(stat_dual_issue_o),
    .stat_dual_retire_o(stat_dual_retire_o),
    .backend_second_valid_o(backend_second_valid_o),

    .commit_ready_i(c__core_commit_ready),
    .commit_order_o(commit_order_o),
    .commit_pc_o(commit_pc_o),
    .commit_next_pc_o(commit_next_pc_o),
    .commit_insn_o(commit_insn_o),
    .commit_rd_o(commit_rd_o),
    .commit_rs1_o(commit_rs1_o),
    .commit_rs2_o(commit_rs2_o),
    .commit_wdata_o(commit_wdata_o),
    .commit_rs1_data_o(commit_rs1_data_o),
    .commit_rs2_data_o(commit_rs2_data_o),
    .commit_trap_o(commit_trap_o),
    .commit_unsupported_o(commit_unsupported_o),
    .commit_cause_o(commit_cause_o),
    .commit_tval_o(commit_tval_o),
    .halted_o(halted_o),
    .d_axi_arvalid_o(c__d_axi_arvalid_o),
    .d_axi_arready_i(c__d_axi_arready_i),
    .d_axi_arid_o(c__d_axi_arid_o),
    .d_axi_araddr_o(c__d_axi_araddr_o),
    .d_axi_arlen_o(c__d_axi_arlen_o),
    .d_axi_arsize_o(c__d_axi_arsize_o),
    .d_axi_arprot_o(c__d_axi_arprot_o),
    .d_axi_arburst_o(c__d_axi_arburst_o),
    .d_axi_arlock_o(c__d_axi_arlock_o),
    .d_axi_arcache_o(c__d_axi_arcache_o),
    .d_axi_rvalid_i(c__d_axi_rvalid_i),
    .d_axi_rready_o(c__d_axi_rready_o),
    .d_axi_rid_i(c__d_axi_rid_i),
    .d_axi_rlast_i(c__d_axi_rlast_i),
    .d_axi_rdata_i(c__d_axi_rdata_i),
    .d_axi_rresp_i(c__d_axi_rresp_i),
    .d_axi_awvalid_o(c__d_axi_awvalid_o),
    .d_axi_awready_i(c__d_axi_awready_i),
    .d_axi_awid_o(c__d_axi_awid_o),
    .d_axi_awaddr_o(c__d_axi_awaddr_o),
    .d_axi_awlen_o(c__d_axi_awlen_o),
    .d_axi_awsize_o(c__d_axi_awsize_o),
    .d_axi_awprot_o(c__d_axi_awprot_o),
    .d_axi_awburst_o(c__d_axi_awburst_o),
    .d_axi_awlock_o(c__d_axi_awlock_o),
    .d_axi_awcache_o(c__d_axi_awcache_o),
    .d_axi_wvalid_o(c__d_axi_wvalid_o),
    .d_axi_wready_i(c__d_axi_wready_i),
    .d_axi_wdata_o(c__d_axi_wdata_o),
    .d_axi_wstrb_o(c__d_axi_wstrb_o),
    .d_axi_wlast_o(c__d_axi_wlast_o),
    .d_axi_bvalid_i(c__d_axi_bvalid_i),
    .d_axi_bready_o(c__d_axi_bready_o),
    .d_axi_bid_i(c__d_axi_bid_i),
    .d_axi_bresp_i(c__d_axi_bresp_i),
    .memory_fatal_o(c__core_fatal),
    .commit_privilege_o(commit_privilege_o),
    .memory_ptw_o(memory_ptw_o),
    .stage_valid_o(stage_valid_o),
    .fetch_pc_o(fetch_pc_o),
    .execute_pc_o(execute_pc_o),
    .retire_pc_o(retire_pc_o),
    .fetch_seq_o(fetch_seq_o),
    .execute_seq_o(execute_seq_o),
    .retire_seq_o(retire_seq_o),
    .epoch_o(epoch_o),
    .stat_overlap_o(stat_overlap_o),
    .stat_prefetch_o(stat_prefetch_o),
    .stat_issue_prefetched_o(stat_issue_prefetched_o),
    .stat_killed_o(stat_killed_o),
    .stat_forward_o(stat_forward_o),.stat_branch_o(stat_branch_o),.stat_prediction_hit_o(stat_prediction_hit_o),.stat_prediction_taken_o(stat_prediction_taken_o),.stat_mispredict_o(stat_mispredict_o),.execute_epoch_o(execute_epoch_o),.retire_epoch_o(retire_epoch_o),.stat_execute_retire_o(stat_execute_retire_o),.stat_execute_retire_fire_o(stat_execute_retire_fire_o)
  );
  rv64_cache_fence #(.ENABLE_D(1),.ENABLE_I(1)) fence_retirement (
    .clk_i(clk_i),
    .aresetn_i(aresetn_i),
    .fatal_i(memory_fatal_o),
    .core_valid_i(c__core_commit_valid),
    .core_ready_o(c__core_commit_ready),
    .core_insn_i(commit_insn_o),
    .core_trap_i(commit_trap_o),
    .core_unsupported_i(commit_unsupported_o),
    .commit_valid_o(commit_valid_o),
    .commit_ready_i(commit_ready_i),
    .clean_valid_o(c__clean_valid),
    .clean_ready_i(c__clean_ready),
    .clean_done_i(c__clean_done),
    .clean_ack_o(c__clean_ack),
    .inv_valid_o(c__inv_valid),
    .inv_ready_i(c__inv_ready),
    .inv_done_i(c__inv_done),
    .inv_ack_o(c__inv_ack),
    .stat_start_o(fence_start_o),
    .stat_clean_o(fence_clean_o),
    .stat_inv_o(fence_inv_o),
    .stat_complete_o(fence_complete_o)
  );

  rv64_dual_icache #(.ENABLE(1)) instruction_cache (
    .clk_i(clk_i),
    .aresetn_i(aresetn_i),
    .req_valid_i(c__i_axi_arvalid_o && !memory_fatal_o),
    .req_ready_o(c__raw_i_arready),
    .req_addr_i(c__i_axi_araddr_o),
    .req_prot_i(c__i_axi_arprot_o),
    .rsp_valid_o(c__i_axi_rvalid_i),
    .rsp_ready_i(c__i_axi_rready_o),
    .rsp_data_o(c__i_axi_rdata_i),
    .rsp_resp_o(c__i_axi_rresp_i),
    .inv_valid_i(c__inv_valid),
    .inv_ready_o(c__inv_ready),
    .inv_done_o(c__inv_done),
    .inv_ack_i(c__inv_ack),
    .mem_arvalid_o(c__ci_req_valid),
    .mem_arready_i(c__ci_req_ready && !memory_fatal_o),
    .mem_araddr_o(c__ci_addr),
    .mem_arprot_o(c__ci_prot),
    .mem_arline_o(c__ci_line),
    .mem_rvalid_i(c__ci_rsp_valid),
    .mem_rready_o(c__ci_rsp_ready),
    .mem_rline_i(c__ci_rsp_data),
    .mem_rresp_i(c__ci_rsp_resp),
    .fatal_o(c__icache_fatal),
    .stat_req_o(icache_req_o),
    .stat_hit_o(icache_hit_o),
    .stat_miss_o(icache_miss_o),
    .stat_refill_o(icache_refill_o),
    .stat_bypass_o(icache_bypass_o),
    .stat_inv_o(icache_inv_o),
    .stat_error_o(icache_error_o)
  );

  rv64_dcache #(.ENABLE(1),.NC_BASE(64'h87000000),.NC_BYTES(64'd8388608)) data_cache (
    .maint_valid_i(dma_valid),.maint_ready_o(dma_ready),.maint_done_o(dma_done),
    .maint_ack_i(dma_ack),.maint_addr_i(dma_address),.maint_op_i(dma_op),.maint_resp_o(dma_response),
    .stat_maint_o(dma_maint_count_o),.stat_maint_error_o(dma_maint_error_o),
    .clk_i(clk_i),
    .aresetn_i(aresetn_i),
    .d_ptw_i(memory_ptw_o),
    .d_axi_arvalid_i(c__d_axi_arvalid_o && !memory_fatal_o),
    .d_axi_arready_o(c__raw_d_arready),
    .d_axi_arid_i(c__d_axi_arid_o),
    .d_axi_araddr_i(c__d_axi_araddr_o),
    .d_axi_arlen_i(c__d_axi_arlen_o),
    .d_axi_arsize_i(c__d_axi_arsize_o),
    .d_axi_arprot_i(c__d_axi_arprot_o),
    .d_axi_arburst_i(c__d_axi_arburst_o),
    .d_axi_arlock_i(c__d_axi_arlock_o),
    .d_axi_arcache_i(c__d_axi_arcache_o),
    .d_axi_rvalid_o(c__d_axi_rvalid_i),
    .d_axi_rready_i(c__d_axi_rready_o),
    .d_axi_rid_o(c__d_axi_rid_i),
    .d_axi_rlast_o(c__d_axi_rlast_i),
    .d_axi_rdata_o(c__d_axi_rdata_i),
    .d_axi_rresp_o(c__d_axi_rresp_i),
    .d_axi_awvalid_i(c__d_axi_awvalid_o && !memory_fatal_o),
    .d_axi_awready_o(c__raw_d_awready),
    .d_axi_awid_i(c__d_axi_awid_o),
    .d_axi_awaddr_i(c__d_axi_awaddr_o),
    .d_axi_awlen_i(c__d_axi_awlen_o),
    .d_axi_awsize_i(c__d_axi_awsize_o),
    .d_axi_awprot_i(c__d_axi_awprot_o),
    .d_axi_awburst_i(c__d_axi_awburst_o),
    .d_axi_awlock_i(c__d_axi_awlock_o),
    .d_axi_awcache_i(c__d_axi_awcache_o),
    .d_axi_wvalid_i(c__d_axi_wvalid_o && !memory_fatal_o),
    .d_axi_wready_o(c__raw_d_wready),
    .d_axi_wdata_i(c__d_axi_wdata_o),
    .d_axi_wstrb_i(c__d_axi_wstrb_o),
    .d_axi_wlast_i(c__d_axi_wlast_o),
    .d_axi_bvalid_o(c__d_axi_bvalid_i),
    .d_axi_bready_i(c__d_axi_bready_o),
    .d_axi_bid_o(c__d_axi_bid_i),
    .d_axi_bresp_o(c__d_axi_bresp_i),
    .clean_valid_i(c__clean_valid),
    .clean_ready_o(c__clean_ready),
    .clean_done_o(c__clean_done),
    .clean_ack_i(c__clean_ack),
    .mem_req_valid_o(c__cd_req_valid),
    .mem_req_ready_i(c__cd_req_ready && !memory_fatal_o),
    .mem_req_write_o(c__cd_req_write),
    .mem_req_lock_o(c__cd_req_lock),
    .mem_req_ptw_o(c__cd_req_ptw),
    .mem_req_addr_o(c__cd_req_addr),
    .mem_req_size_o(c__cd_req_size),
    .mem_req_prot_o(c__cd_req_prot),
    .mem_req_len_o(c__cd_req_len),
    .mem_req_cache_o(c__cd_req_cache),
    .mem_req_wdata_o(c__cd_req_wdata),
    .mem_req_wstrb_o(c__cd_req_wstrb),
    .mem_rsp_valid_i(c__cd_rsp_valid),
    .mem_rsp_ready_o(c__cd_rsp_ready),
    .mem_rsp_data_i(c__cd_rsp_data),
    .mem_rsp_resp_i(c__cd_rsp_resp),
    .mem_fatal_i(c__arb_fatal),
    .fatal_o(c__dcache_fatal),
    .fault_addr_o(dcache_fault_addr_o),
    .fault_resp_o(dcache_fault_resp_o),
    .fault_write_o(dcache_fault_write_o),
    .stat_req_o(dcache_req_o),
    .stat_hit_o(dcache_hit_o),
    .stat_miss_o(dcache_miss_o),
    .stat_refill_o(dcache_refill_o),
    .stat_writeback_o(dcache_writeback_o),
    .stat_bypass_o(dcache_bypass_o),
    .stat_clean_o(dcache_clean_o),
    .stat_error_o(dcache_error_o)
  );

  rv64_dual_cache_arbiter #(.ENABLE_I_LINE(1)) physical_bus (
    .clk_i(clk_i),
    .aresetn_i(aresetn_i),
    .i_req_valid_i(c__ci_req_valid && !memory_fatal_o),
    .i_req_ready_o(c__ci_req_ready),
    .i_req_addr_i(c__ci_addr),
    .i_req_prot_i(c__ci_prot),
    .i_req_line_i(c__ci_line),
    .i_rsp_valid_o(c__ci_rsp_valid),
    .i_rsp_ready_i(c__ci_rsp_ready),
    .i_rsp_data_o(c__ci_rsp_data),
    .i_rsp_resp_o(c__ci_rsp_resp),
    .i_rsp_error_o(c__unused_i_rsp_error),
    .d_req_valid_i(c__cd_req_valid && !memory_fatal_o),
    .d_req_ready_o(c__cd_req_ready),
    .d_req_write_i(c__cd_req_write),
    .d_req_lock_i(c__cd_req_lock),
    .d_req_ptw_i(c__cd_req_ptw),
    .d_req_addr_i(c__cd_req_addr),
    .d_req_size_i(c__cd_req_size),
    .d_req_prot_i(c__cd_req_prot),
    .d_req_len_i(c__cd_req_len),
    .d_req_cache_i(c__cd_req_cache),
    .d_req_wdata_i(c__cd_req_wdata),
    .d_req_wstrb_i(c__cd_req_wstrb),
    .d_rsp_valid_o(c__cd_rsp_valid),
    .d_rsp_ready_i(c__cd_rsp_ready),
    .d_rsp_data_o(c__cd_rsp_data),
    .d_rsp_resp_o(c__cd_rsp_resp),
    .d_rsp_error_o(c__unused_d_rsp_error),
    .bus_ptw_o(bus_ptw_o),
    .fatal_o(c__arb_fatal),
    .stat_i_req_o(arb_i_req_o),
    .stat_d_req_o(arb_d_req_o),
    .stat_error_o(arb_error_o),
    .stat_i_wait_o(arb_i_wait_o),
    .stat_d_wait_o(arb_d_wait_o),
    .m_axi_arvalid_o(cpu_arvalid_o),
    .m_axi_arready_i(cpu_arready_i),
    .m_axi_arid_o(cpu_arid_o),
    .m_axi_araddr_o(cpu_araddr_o),
    .m_axi_arlen_o(cpu_arlen_o),
    .m_axi_arsize_o(cpu_arsize_o),
    .m_axi_arprot_o(cpu_arprot_o),
    .m_axi_arburst_o(cpu_arburst_o),
    .m_axi_arlock_o(cpu_arlock_o),
    .m_axi_arcache_o(cpu_arcache_o),
    .m_axi_rvalid_i(cpu_rvalid_i),
    .m_axi_rready_o(cpu_rready_o),
    .m_axi_rid_i(cpu_rid_i),
    .m_axi_rlast_i(cpu_rlast_i),
    .m_axi_rdata_i(cpu_rdata_i),
    .m_axi_rresp_i(cpu_rresp_i),
    .m_axi_awvalid_o(cpu_awvalid_o),
    .m_axi_awready_i(cpu_awready_i),
    .m_axi_awid_o(cpu_awid_o),
    .m_axi_awaddr_o(cpu_awaddr_o),
    .m_axi_awlen_o(cpu_awlen_o),
    .m_axi_awsize_o(cpu_awsize_o),
    .m_axi_awprot_o(cpu_awprot_o),
    .m_axi_awburst_o(cpu_awburst_o),
    .m_axi_awlock_o(cpu_awlock_o),
    .m_axi_awcache_o(cpu_awcache_o),
    .m_axi_wvalid_o(cpu_wvalid_o),
    .m_axi_wready_i(cpu_wready_i),
    .m_axi_wdata_o(cpu_wdata_o),
    .m_axi_wstrb_o(cpu_wstrb_o),
    .m_axi_wlast_o(cpu_wlast_o),
    .m_axi_bvalid_i(cpu_bvalid_i),
    .m_axi_bready_o(cpu_bready_o),
    .m_axi_bid_i(cpu_bid_i),
    .m_axi_bresp_i(cpu_bresp_i)
  );

  logic [31:0] f__ddr_read_address,f__ddr_write_address;
 logic f__clint_msip,f__clint_mtip;
 assign ddr_araddr_o=f__ddr_read_address;
 assign ddr_awaddr_o=f__ddr_write_address;
 assign irq_msip_o=f__clint_msip;
 assign irq_mtip_o=f__clint_mtip;
 logic [6:0] f__q_arvalid;
 logic f__q_arid;
 logic [63:0] f__q_araddr;
 logic [7:0] f__q_arlen;
 logic [2:0] f__q_arsize;
 logic [2:0] f__q_arprot;
 logic [1:0] f__q_arburst;
 logic f__q_arlock;
 logic [3:0] f__q_arcache;
 logic [6:0] f__q_rready;
 logic [6:0] f__q_awvalid;
 logic f__q_awid;
 logic [63:0] f__q_awaddr;
 logic [7:0] f__q_awlen;
 logic [2:0] f__q_awsize;
 logic [2:0] f__q_awprot;
 logic [1:0] f__q_awburst;
 logic f__q_awlock;
 logic [3:0] f__q_awcache;
 logic [6:0] f__q_wvalid;
 logic [63:0] f__q_wdata;
 logic [7:0] f__q_wstrb;
 logic f__q_wlast;
 logic [6:0] f__q_bready;
 logic [6:0] f__q_arready;
 logic [6:0] f__q_rvalid;
 logic [6:0] f__q_rid;
 logic [6:0] f__q_rlast;
 logic [447:0] f__q_rdata;
 logic [13:0] f__q_rresp;
 logic [6:0] f__q_awready;
 logic [6:0] f__q_wready;
 logic [6:0] f__q_bvalid;
 logic [6:0] f__q_bid;
 logic [13:0] f__q_bresp;
 rv64_board_decode_video decode (
  .clk_i(clk_i),
  .aresetn_i(aresetn_i),
  .s_arvalid_i(cpu_arvalid_o),
  .s_arid_i(cpu_arid_o),
  .s_araddr_i(cpu_araddr_o),
  .s_arlen_i(cpu_arlen_o),
  .s_arsize_i(cpu_arsize_o),
  .s_arprot_i(cpu_arprot_o),
  .s_arburst_i(cpu_arburst_o),
  .s_arlock_i(cpu_arlock_o),
  .s_arcache_i(cpu_arcache_o),
  .s_rready_i(cpu_rready_o),
  .s_awvalid_i(cpu_awvalid_o),
  .s_awid_i(cpu_awid_o),
  .s_awaddr_i(cpu_awaddr_o),
  .s_awlen_i(cpu_awlen_o),
  .s_awsize_i(cpu_awsize_o),
  .s_awprot_i(cpu_awprot_o),
  .s_awburst_i(cpu_awburst_o),
  .s_awlock_i(cpu_awlock_o),
  .s_awcache_i(cpu_awcache_o),
  .s_wvalid_i(cpu_wvalid_o),
  .s_wdata_i(cpu_wdata_o),
  .s_wstrb_i(cpu_wstrb_o),
  .s_wlast_i(cpu_wlast_o),
  .s_bready_i(cpu_bready_o),
  .s_arready_o(cpu_arready_i),
  .s_rvalid_o(cpu_rvalid_i),
  .s_rid_o(cpu_rid_i),
  .s_rlast_o(cpu_rlast_i),
  .s_rdata_o(cpu_rdata_i),
  .s_rresp_o(cpu_rresp_i),
  .s_awready_o(cpu_awready_i),
  .s_wready_o(cpu_wready_i),
  .s_bvalid_o(cpu_bvalid_i),
  .s_bid_o(cpu_bid_i),
  .s_bresp_o(cpu_bresp_i),
  .m_arvalid_o(f__q_arvalid),
  .m_arid_o(f__q_arid),
  .m_araddr_o(f__q_araddr),
  .m_arlen_o(f__q_arlen),
  .m_arsize_o(f__q_arsize),
  .m_arprot_o(f__q_arprot),
  .m_arburst_o(f__q_arburst),
  .m_arlock_o(f__q_arlock),
  .m_arcache_o(f__q_arcache),
  .m_rready_o(f__q_rready),
  .m_awvalid_o(f__q_awvalid),
  .m_awid_o(f__q_awid),
  .m_awaddr_o(f__q_awaddr),
  .m_awlen_o(f__q_awlen),
  .m_awsize_o(f__q_awsize),
  .m_awprot_o(f__q_awprot),
  .m_awburst_o(f__q_awburst),
  .m_awlock_o(f__q_awlock),
  .m_awcache_o(f__q_awcache),
  .m_wvalid_o(f__q_wvalid),
  .m_wdata_o(f__q_wdata),
  .m_wstrb_o(f__q_wstrb),
  .m_wlast_o(f__q_wlast),
  .m_bready_o(f__q_bready),
  .m_arready_i(f__q_arready),
  .m_rvalid_i(f__q_rvalid),
  .m_rid_i(f__q_rid),
  .m_rlast_i(f__q_rlast),
  .m_rdata_i(f__q_rdata),
  .m_rresp_i(f__q_rresp),
  .m_awready_i(f__q_awready),
  .m_wready_i(f__q_wready),
  .m_bvalid_i(f__q_bvalid),
  .m_bid_i(f__q_bid),
  .m_bresp_i(f__q_bresp)
 );
 rv64_ddr_window ddr_window (
  .clk_i(clk_i),
  .aresetn_i(aresetn_i),
  .s_arvalid_i(f__q_arvalid[0]),
  .s_arid_i(f__q_arid),
  .s_araddr_i(f__q_araddr),
  .s_arlen_i(f__q_arlen),
  .s_arsize_i(f__q_arsize),
  .s_arprot_i(f__q_arprot),
  .s_arburst_i(f__q_arburst),
  .s_arlock_i(f__q_arlock),
  .s_arcache_i(f__q_arcache),
  .s_rready_i(f__q_rready[0]),
  .s_awvalid_i(f__q_awvalid[0]),
  .s_awid_i(f__q_awid),
  .s_awaddr_i(f__q_awaddr),
  .s_awlen_i(f__q_awlen),
  .s_awsize_i(f__q_awsize),
  .s_awprot_i(f__q_awprot),
  .s_awburst_i(f__q_awburst),
  .s_awlock_i(f__q_awlock),
  .s_awcache_i(f__q_awcache),
  .s_wvalid_i(f__q_wvalid[0]),
  .s_wdata_i(f__q_wdata),
  .s_wstrb_i(f__q_wstrb),
  .s_wlast_i(f__q_wlast),
  .s_bready_i(f__q_bready[0]),
  .s_arready_o(f__q_arready[0]),
  .s_rvalid_o(f__q_rvalid[0]),
  .s_rid_o(f__q_rid[0]),
  .s_rlast_o(f__q_rlast[0]),
  .s_rdata_o(f__q_rdata[0+:64]),
  .s_rresp_o(f__q_rresp[0+:2]),
  .s_awready_o(f__q_awready[0]),
  .s_wready_o(f__q_wready[0]),
  .s_bvalid_o(f__q_bvalid[0]),
  .s_bid_o(f__q_bid[0]),
  .s_bresp_o(f__q_bresp[0+:2]),
  .m_arvalid_o(ddr_arvalid_o),
  .m_arid_o(ddr_arid_o),
  .m_araddr_o(f__ddr_read_address),
  .m_arlen_o(ddr_arlen_o),
  .m_arsize_o(ddr_arsize_o),
  .m_arprot_o(ddr_arprot_o),
  .m_arburst_o(ddr_arburst_o),
  .m_arlock_o(ddr_arlock_o),
  .m_arcache_o(ddr_arcache_o),
  .m_rready_o(ddr_rready_o),
  .m_awvalid_o(ddr_awvalid_o),
  .m_awid_o(ddr_awid_o),
  .m_awaddr_o(f__ddr_write_address),
  .m_awlen_o(ddr_awlen_o),
  .m_awsize_o(ddr_awsize_o),
  .m_awprot_o(ddr_awprot_o),
  .m_awburst_o(ddr_awburst_o),
  .m_awlock_o(ddr_awlock_o),
  .m_awcache_o(ddr_awcache_o),
  .m_wvalid_o(ddr_wvalid_o),
  .m_wdata_o(ddr_wdata_o),
  .m_wstrb_o(ddr_wstrb_o),
  .m_wlast_o(ddr_wlast_o),
  .m_bready_o(ddr_bready_o),
  .m_arready_i(ddr_arready_i),
  .m_rvalid_i(ddr_rvalid_i),
  .m_rid_i(ddr_rid_i),
  .m_rlast_i(ddr_rlast_i),
  .m_rdata_i(ddr_rdata_i),
  .m_rresp_i(ddr_rresp_i),
  .m_awready_i(ddr_awready_i),
  .m_wready_i(ddr_wready_i),
  .m_bvalid_i(ddr_bvalid_i),
  .m_bid_i(ddr_bid_i),
  .m_bresp_i(ddr_bresp_i)
 );
 rv64_boot_rom boot_rom (
  .clk_i(clk_i),
  .aresetn_i(aresetn_i),
  .s_arvalid_i(f__q_arvalid[1]),
  .s_arid_i(f__q_arid),
  .s_araddr_i(f__q_araddr),
  .s_arlen_i(f__q_arlen),
  .s_arsize_i(f__q_arsize),
  .s_arburst_i(f__q_arburst),
  .s_arlock_i(f__q_arlock),
  .s_rready_i(f__q_rready[1]),
  .s_awvalid_i(f__q_awvalid[1]),
  .s_awid_i(f__q_awid),
  .s_awaddr_i(f__q_awaddr),
  .s_awlen_i(f__q_awlen),
  .s_awsize_i(f__q_awsize),
  .s_awburst_i(f__q_awburst),
  .s_awlock_i(f__q_awlock),
  .s_wvalid_i(f__q_wvalid[1]),
  .s_wdata_i(f__q_wdata),
  .s_wstrb_i(f__q_wstrb),
  .s_wlast_i(f__q_wlast),
  .s_bready_i(f__q_bready[1]),
  .s_arready_o(f__q_arready[1]),
  .s_rvalid_o(f__q_rvalid[1]),
  .s_rid_o(f__q_rid[1]),
  .s_rlast_o(f__q_rlast[1]),
  .s_rdata_o(f__q_rdata[64+:64]),
  .s_rresp_o(f__q_rresp[2+:2]),
  .s_awready_o(f__q_awready[1]),
  .s_wready_o(f__q_wready[1]),
  .s_bvalid_o(f__q_bvalid[1]),
  .s_bid_o(f__q_bid[1]),
  .s_bresp_o(f__q_bresp[2+:2])
 );
 rv64_clint #(.TICK_DIV(TICK_DIV)) clint (
  .clk_i(clk_i),
  .aresetn_i(aresetn_i),
  .s_arvalid_i(f__q_arvalid[2]),
  .s_arid_i(f__q_arid),
  .s_araddr_i(f__q_araddr),
  .s_arlen_i(f__q_arlen),
  .s_arsize_i(f__q_arsize),
  .s_arburst_i(f__q_arburst),
  .s_arlock_i(f__q_arlock),
  .s_rready_i(f__q_rready[2]),
  .s_awvalid_i(f__q_awvalid[2]),
  .s_awid_i(f__q_awid),
  .s_awaddr_i(f__q_awaddr),
  .s_awlen_i(f__q_awlen),
  .s_awsize_i(f__q_awsize),
  .s_awburst_i(f__q_awburst),
  .s_awlock_i(f__q_awlock),
  .s_wvalid_i(f__q_wvalid[2]),
  .s_wdata_i(f__q_wdata),
  .s_wstrb_i(f__q_wstrb),
  .s_wlast_i(f__q_wlast),
  .s_bready_i(f__q_bready[2]),
  .s_arready_o(f__q_arready[2]),
  .s_rvalid_o(f__q_rvalid[2]),
  .s_rid_o(f__q_rid[2]),
  .s_rlast_o(f__q_rlast[2]),
  .s_rdata_o(f__q_rdata[128+:64]),
  .s_rresp_o(f__q_rresp[4+:2]),
  .s_awready_o(f__q_awready[2]),
  .s_wready_o(f__q_wready[2]),
  .s_bvalid_o(f__q_bvalid[2]),
  .s_bid_o(f__q_bid[2]),
  .s_bresp_o(f__q_bresp[4+:2]),
  .irq_msip_o(f__clint_msip),
  .irq_mtip_o(f__clint_mtip),
  .time_o(time_o)
 );
 assign ps_arvalid_o=f__q_arvalid[3];
 assign ps_arid_o=f__q_arid;
 assign ps_araddr_o=f__q_araddr[31:0];
 assign ps_arlen_o=f__q_arlen;
 assign ps_arsize_o=f__q_arsize;
 assign ps_arprot_o=f__q_arprot;
 assign ps_arburst_o=f__q_arburst;
 assign ps_arlock_o=f__q_arlock;
 assign ps_arcache_o=f__q_arcache;
 assign ps_rready_o=f__q_rready[3];
 assign ps_awvalid_o=f__q_awvalid[3];
 assign ps_awid_o=f__q_awid;
 assign ps_awaddr_o=f__q_awaddr[31:0];
 assign ps_awlen_o=f__q_awlen;
 assign ps_awsize_o=f__q_awsize;
 assign ps_awprot_o=f__q_awprot;
 assign ps_awburst_o=f__q_awburst;
 assign ps_awlock_o=f__q_awlock;
 assign ps_awcache_o=f__q_awcache;
 assign ps_wvalid_o=f__q_wvalid[3];
 assign ps_wdata_o=f__q_wdata;
 assign ps_wstrb_o=f__q_wstrb;
 assign ps_wlast_o=f__q_wlast;
 assign ps_bready_o=f__q_bready[3];
 assign f__q_arready[3]=ps_arready_i;
 assign f__q_rvalid[3]=ps_rvalid_i;
 assign f__q_rid[3]=ps_rid_i;
 assign f__q_rlast[3]=ps_rlast_i;
 assign f__q_rdata[192+:64]=ps_rdata_i;
 assign f__q_rresp[6+:2]=ps_rresp_i;
 assign f__q_awready[3]=ps_awready_i;
 assign f__q_wready[3]=ps_wready_i;
 assign f__q_bvalid[3]=ps_bvalid_i;
 assign f__q_bid[3]=ps_bid_i;
 assign f__q_bresp[6+:2]=ps_bresp_i;
rv64_dma_cache_control dma_control (
 .clk_i(clk_i),
 .aresetn_i(aresetn_i),
 .s_arvalid_i(f__q_arvalid[4]),
 .s_arready_o(f__q_arready[4]),
 .s_arid_i(f__q_arid),
 .s_araddr_i(f__q_araddr),
 .s_arlen_i(f__q_arlen),
 .s_arsize_i(f__q_arsize),
 .s_arburst_i(f__q_arburst),
 .s_arlock_i(f__q_arlock),
 .s_rvalid_o(f__q_rvalid[4]),
 .s_rready_i(f__q_rready[4]),
 .s_rid_o(f__q_rid[4]),
 .s_rlast_o(f__q_rlast[4]),
 .s_rdata_o(f__q_rdata[256+:64]),
 .s_rresp_o(f__q_rresp[8+:2]),
 .s_awvalid_i(f__q_awvalid[4]),
 .s_awready_o(f__q_awready[4]),
 .s_awid_i(f__q_awid),
 .s_awaddr_i(f__q_awaddr),
 .s_awlen_i(f__q_awlen),
 .s_awsize_i(f__q_awsize),
 .s_awburst_i(f__q_awburst),
 .s_awlock_i(f__q_awlock),
 .s_wvalid_i(f__q_wvalid[4]),
 .s_wready_o(f__q_wready[4]),
 .s_wdata_i(f__q_wdata),
 .s_wstrb_i(f__q_wstrb),
 .s_wlast_i(f__q_wlast),
 .s_bvalid_o(f__q_bvalid[4]),
 .s_bready_i(f__q_bready[4]),
 .s_bid_o(f__q_bid[4]),
 .s_bresp_o(f__q_bresp[8+:2]),
 .maint_valid_o(dma_valid),
 .maint_ready_i(dma_ready),
 .maint_addr_o(dma_address),
 .maint_op_o(dma_op),
 .maint_done_i(dma_done),
 .maint_ack_o(dma_ack),
 .maint_resp_i(dma_response),
 .cache_fatal_i(c__dcache_fatal),
 .busy_o(dma_busy_o),
 .done_o(dma_done_o),
 .error_o(dma_error_o),
 .fatal_o(dma_fatal_o)
);

rv64_plic plic (
 .clk_i(clk_i),
 .aresetn_i(aresetn_i),
 .sources_i(sources_i),
 .irq_meip_o(irq_meip_o),
 .irq_seip_o(irq_seip_o),
 .s_arvalid_i(f__q_arvalid[5]),
 .s_arready_o(f__q_arready[5]),
 .s_arid_i(f__q_arid),
 .s_araddr_i(f__q_araddr),
 .s_arlen_i(f__q_arlen),
 .s_arsize_i(f__q_arsize),
 .s_arburst_i(f__q_arburst),
 .s_arlock_i(f__q_arlock),
 .s_rvalid_o(f__q_rvalid[5]),
 .s_rready_i(f__q_rready[5]),
 .s_rid_o(f__q_rid[5]),
 .s_rlast_o(f__q_rlast[5]),
 .s_rdata_o(f__q_rdata[320+:64]),
 .s_rresp_o(f__q_rresp[10+:2]),
 .s_awvalid_i(f__q_awvalid[5]),
 .s_awready_o(f__q_awready[5]),
 .s_awid_i(f__q_awid),
 .s_awaddr_i(f__q_awaddr),
 .s_awlen_i(f__q_awlen),
 .s_awsize_i(f__q_awsize),
 .s_awburst_i(f__q_awburst),
 .s_awlock_i(f__q_awlock),
 .s_wvalid_i(f__q_wvalid[5]),
 .s_wready_o(f__q_wready[5]),
 .s_wdata_i(f__q_wdata),
 .s_wstrb_i(f__q_wstrb),
 .s_wlast_i(f__q_wlast),
 .s_bvalid_o(f__q_bvalid[5]),
 .s_bready_i(f__q_bready[5]),
 .s_bid_o(f__q_bid[5]),
 .s_bresp_o(f__q_bresp[10+:2])
);

rv64_scanout_control #(.MMIO_BASE(64'h04000000)) video_control (
 .bus_clk_i(clk_i),
 .pixel_clk_i(pixel_clk_i),
 .aresetn_i(aresetn_i),
 .cmd_valid_o(video_cmd_valid),
 .cmd_ready_i(video_cmd_ready),
 .cmd_base_o(video_cmd_base),
 .reader_busy_i(scan_reader_busy_o),
 .bus_stats_i({27'd0,scan_reader_error_o,scan_bus_failed_o,scan_bus_frames_o,scan_bus_pixels_o,scan_bus_beats_o,scan_bus_bursts_o}),
 .video_status_i({video_pixels_o,video_dropped_o,video_marker_o,video_underflow_o,video_bad_o,video_good_o,video_started_o,video_crc_o}),
 .run_o(ctrl_run_o),
 .base_locked_o(ctrl_locked_o),
 .snapshot_busy_o(ctrl_snapshot_busy_o),
 .snapshot_valid_o(ctrl_snapshot_valid_o),
 .snapshot_sequence_o(ctrl_snapshot_sequence_o),
 .s_arvalid_i(f__q_arvalid[6]),
 .s_arready_o(f__q_arready[6]),
 .s_arid_i(f__q_arid),
 .s_araddr_i(f__q_araddr),
 .s_arlen_i(f__q_arlen),
 .s_arsize_i(f__q_arsize),
 .s_arburst_i(f__q_arburst),
 .s_arlock_i(f__q_arlock),
 .s_rvalid_o(f__q_rvalid[6]),
 .s_rready_i(f__q_rready[6]),
 .s_rid_o(f__q_rid[6]),
 .s_rlast_o(f__q_rlast[6]),
 .s_rdata_o(f__q_rdata[384+:64]),
 .s_rresp_o(f__q_rresp[12+:2]),
 .s_awvalid_i(f__q_awvalid[6]),
 .s_awready_o(f__q_awready[6]),
 .s_awid_i(f__q_awid),
 .s_awaddr_i(f__q_awaddr),
 .s_awlen_i(f__q_awlen),
 .s_awsize_i(f__q_awsize),
 .s_awburst_i(f__q_awburst),
 .s_awlock_i(f__q_awlock),
 .s_wvalid_i(f__q_wvalid[6]),
 .s_wready_o(f__q_wready[6]),
 .s_wdata_i(f__q_wdata),
 .s_wstrb_i(f__q_wstrb),
 .s_wlast_i(f__q_wlast),
 .s_bvalid_o(f__q_bvalid[6]),
 .s_bready_i(f__q_bready[6]),
 .s_bid_o(f__q_bid[6]),
 .s_bresp_o(f__q_bresp[12+:2])
);

rv64_ddr_scanout #(.FIFO_ADDR_BITS(10)) scanout (
 .bus_clk_i(clk_i),
 .pixel_clk_i(pixel_clk_i),
 .aresetn_i(aresetn_i),
 .cmd_valid_i(video_cmd_valid),
 .cmd_ready_o(video_cmd_ready),
 .cmd_base_i(video_cmd_base),
 .reader_busy_o(scan_reader_busy_o),
 .queued_done_o(scan_queued_done_o),
 .queued_success_o(scan_queued_success_o),
 .reader_error_o(scan_reader_error_o),
 .m_arvalid_o(scan_arvalid_o),
 .m_arready_i(scan_arready_i),
 .m_arid_o(scan_arid_o),
 .m_araddr_o(scan_araddr_o),
 .m_arlen_o(scan_arlen_o),
 .m_arsize_o(scan_arsize_o),
 .m_arprot_o(scan_arprot_o),
 .m_arburst_o(scan_arburst_o),
 .m_arlock_o(scan_arlock_o),
 .m_arcache_o(scan_arcache_o),
 .m_rvalid_i(scan_rvalid_i),
 .m_rready_o(scan_rready_o),
 .m_rid_i(scan_rid_i),
 .m_rlast_i(scan_rlast_i),
 .m_rdata_i(scan_rdata_i),
 .m_rresp_i(scan_rresp_i),
 .bus_bursts_o(scan_bus_bursts_o),
 .bus_beats_o(scan_bus_beats_o),
 .bus_pixels_o(scan_bus_pixels_o),
 .bus_frames_o(scan_bus_frames_o),
 .bus_failed_o(scan_bus_failed_o),
 .video_de_o(video_de_o),
 .video_hsync_o(video_hsync_o),
 .video_vsync_o(video_vsync_o),
 .video_frame_start_o(video_frame_start_o),
 .video_hpos_o(video_hpos_o),
 .video_vpos_o(video_vpos_o),
 .video_rgb_o(video_rgb_o),
 .tmds_blue_o(tmds_blue_o),
 .tmds_green_o(tmds_green_o),
 .tmds_red_o(tmds_red_o),
 .video_crc_valid_o(video_crc_valid_o),
 .video_crc_o(video_crc_o),
 .video_started_o(video_started_o),
 .video_good_o(video_good_o),
 .video_bad_o(video_bad_o),
 .video_underflow_o(video_underflow_o),
 .video_marker_o(video_marker_o),
 .video_dropped_o(video_dropped_o),
 .video_pixels_o(video_pixels_o)
);

endmodule
