// R90 standalone core candidate: hardware SEIP + commit-preserved raw CSR operand.
// R64 DEVELOPMENT: serializing integrated F/D/LSU/FCSR/FS; not Linux acceptance.
// R63 DEVELOPMENT: conservative C frontend, one fetched instruction at a time.
// C mode disables BP, dual issue and X-stage early loads until correctness acceptance.
// R50 DEVELOPMENT: static registered N-packet memory guard; R49 remains frozen.
// R31 DEVELOPMENT: 8-byte fetch; ordered complex+simple pairs.
// Shared ready atomically consumes both valid commit slots. Not RVFI.
// R21: direct effective-M/BARE data addresses and registered-result forwarding.
// R20: system instructions drain X as well as M/N/C before operand issue.
`timescale 1ns/1ps
// R18 development: F0/F1/F2/F3 elastic frontend and D/I/X/M/N/C ordered backend.
// Ordered read-only instruction channel, 64-bit byte addresses / 32-bit data, metadata credits. Not a general AXI multi-ID master.
// aresetn_i is COMMON with the responder and must span a rising clock edge.
// commit_* is a project diagnostic/acceptance interface, not complete RVFI.
module rv64_dual_core #(
  parameter bit ENABLE_FP=0,
  parameter bit ENABLE_C=0,
  parameter bit ENABLE_BP=1,
  parameter logic [63:0] RESET_PC = 64'h0000000080000000,
  parameter bit ENABLE_PRIV = 0, // R07 bare EEI remains an explicit regression configuration.
  parameter bit ENABLE_SU = 0,
  parameter bit HAS_MMU = 0,
  parameter bit ENABLE_A = 0,
  parameter logic [63:0] ATOMIC_RAM_BASE = 64'h80000000,
  parameter logic [63:0] ATOMIC_RAM_BYTES = 64'h08000000
) (
  input  logic clk_i, aresetn_i,
  input logic irq_msip_i, irq_mtip_i, irq_meip_i, irq_seip_i,
  input logic [63:0] time_i,
  output logic m_axi_arvalid_o,
  input  logic m_axi_arready_i,
  output logic [63:0] m_axi_araddr_o,
  output logic [2:0] m_axi_arprot_o,
  input  logic m_axi_rvalid_i,
  output logic m_axi_rready_o,
  input  logic [63:0] m_axi_rdata_i,
  input  logic [1:0] m_axi_rresp_i,
  output logic commit_valid_o,
  input  logic commit_ready_i,
  output logic [63:0] commit_order_o, commit_pc_o, commit_next_pc_o,
  output logic [31:0] commit_insn_o,
  output logic [4:0] commit_rd_o, commit_rs1_o, commit_rs2_o,
  output logic [63:0] commit_wdata_o, commit_rs1_data_o, commit_rs2_data_o,
  output logic commit_trap_o, commit_unsupported_o,
  output logic [63:0] commit_cause_o, commit_tval_o,
  output logic halted_o,
  output logic d_axi_arvalid_o,
  input logic d_axi_arready_i,
  output logic d_axi_arid_o,
  output logic [63:0] d_axi_araddr_o,
  output logic [7:0] d_axi_arlen_o,
  output logic [2:0] d_axi_arsize_o, d_axi_arprot_o,
  output logic [1:0] d_axi_arburst_o,
  output logic d_axi_arlock_o,
  output logic [3:0] d_axi_arcache_o,
  input logic d_axi_rvalid_i,
  output logic d_axi_rready_o,
  input logic d_axi_rid_i, d_axi_rlast_i,
  input logic [63:0] d_axi_rdata_i,
  input logic [1:0] d_axi_rresp_i,
  output logic d_axi_awvalid_o,
  input logic d_axi_awready_i,
  output logic d_axi_awid_o,
  output logic [63:0] d_axi_awaddr_o,
  output logic [7:0] d_axi_awlen_o,
  output logic [2:0] d_axi_awsize_o, d_axi_awprot_o,
  output logic [1:0] d_axi_awburst_o,
  output logic d_axi_awlock_o,
  output logic [3:0] d_axi_awcache_o,
  output logic d_axi_wvalid_o,
  input logic d_axi_wready_i,
  output logic [63:0] d_axi_wdata_o,
  output logic [7:0] d_axi_wstrb_o,
  output logic d_axi_wlast_o,
  input logic d_axi_bvalid_i,
  output logic d_axi_bready_o,
  input logic d_axi_bid_i,
  input logic [1:0] d_axi_bresp_i,
  output logic memory_fatal_o,
  output logic [1:0] commit_privilege_o,
  output logic memory_ptw_o // Diagnostic owner tag, not a functional bus channel.
,
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
  output logic [63:0] f0_seq_o,f1_seq_o,f2_seq_o,f3_seq_o,
  output logic [2:0] fetch_outstanding_o,
  output logic [5:0] backend_valid_o,
  output logic [63:0] resolve_pc_o,resolve_seq_o,
  output logic [63:0] decode_pc_o, issue_pc_o, alu_pc_o,
  output logic [63:0] decode_seq_o, issue_seq_o, alu_seq_o,
  output logic [63:0] stat_raw_stall_o, stat_issue_o, stat_consecutive_issue_o,
  output logic commit_second_valid_o,
  output logic [63:0] commit_second_order_o,commit_second_pc_o,commit_second_next_pc_o,
  output logic [31:0] commit_second_insn_o,
  output logic [4:0] commit_second_rd_o,commit_second_rs1_o,commit_second_rs2_o,
  output logic [63:0] commit_second_wdata_o,commit_second_rs1_data_o,commit_second_rs2_data_o,
  output logic [1:0] commit_second_privilege_o,
  output logic [63:0] stat_dual_issue_o,stat_dual_retire_o,
  output logic [5:0] backend_second_valid_o,
  output logic [63:0] stat_execute_retire_o,stat_execute_retire_fire_o
);

  localparam logic [2:0] S_EXEC=2, S_BOUNDARY=4, S_IRQ=5;
  logic [2:0] state_q;
  typedef struct packed {
    logic [63:0] pc,seq,epoch,pred_next;
    logic [31:0] insn,raw_insn;
    logic [2:0] length;
    logic [63:0] fetch_va;
    logic c_tail,rvc_illegal;
    logic if_error,if_page_fault,pred_hit,pred_taken;
    logic second_valid,second_pred_hit,second_pred_taken;
    logic [31:0] second_insn;
    logic [63:0] second_pred_next;
  } fetch_packet_t;
  typedef struct packed {
    logic [63:0] pc,seq,epoch,pred_next;
    logic [31:0] insn,raw_insn;
    logic [2:0] length;
    logic [63:0] fetch_va;
    logic c_tail,rvc_illegal;
    logic if_error,if_page_fault,pred_hit,pred_taken;
    logic illegal,write_rd,use1,use2;
    logic [3:0] kind;
    logic [4:0] rd,rs1,rs2,alu;
    logic [63:0] imm,r1,r2;
    logic a_pc,a_zero,b_imm;
    logic [2:0] branch_op;
    logic [1:0] size;
    logic unsigned_load;
    logic [3:0] md_op;
    logic atomic_op,atomic_word,csr,mret,sret,sfence,wfi,sys;
    logic fp_op,fp_exec,fp_load,fp_store,fp_ls_bad;
    logic [63:0] fp_a,fp_b,fp_c;
  } uop_t;
  // Completed execution is registered before redirect and architectural selection.
  typedef struct packed {
    logic [63:0] pc,next_pc,seq,epoch;
    logic [31:0] insn;
    logic [4:0] rd,rs1,rs2;
    logic [63:0] wdata,rs1_data,rs2_data,cause,tval,csr_wdata,csr_operand;
    logic [1:0] privilege;
    logic trap,unsupported,write_rd,csr_write,mret,sret,sfence,irq,serialize;
    logic branch,pred_hit,pred_taken,taken,push,pop;
    logic [1:0] kind;
    logic [63:0] target,pred_next;
    logic redirect;
    logic fp_op,fp_write,fp_single;
    logic [4:0] fp_rd,fp_flags;
    logic [63:0] fp_data;
  } resolve_t;
  resolve_t n_q,n_b_q,ret_b_q,n_b_resolved;
  // R49: B conditional reads the registered primary result in N. No live
  // D-cache/MDU result is cascaded through a second comparator in M.
  // R53: register dependency selection with the M->N packet. Actual A data
  // remains registered in n_q.wdata; no live cache result enters B comparison.
  logic n_b_forward1_q,n_b_forward2_q;
  wire [63:0] n_b_r1=n_b_forward1_q?n_q.wdata:n_b_q.rs1_data;
  wire [63:0] n_b_r2=n_b_forward2_q?n_q.wdata:n_b_q.rs2_data;
  logic n_b_taken;
  always_comb begin
    case(n_b_q.insn[14:12])
      0:n_b_taken=n_b_r1==n_b_r2;
      1:n_b_taken=n_b_r1!=n_b_r2;
      4:n_b_taken=$signed(n_b_r1)<$signed(n_b_r2);
      5:n_b_taken=$signed(n_b_r1)>=$signed(n_b_r2);
      6:n_b_taken=n_b_r1<n_b_r2;
      7:n_b_taken=n_b_r1>=n_b_r2;
      default:n_b_taken=0;
    endcase
    n_b_resolved=n_b_q;
    if(n_b_q.branch)begin
      n_b_resolved.rs1_data=n_b_r1;n_b_resolved.rs2_data=n_b_r2;
      n_b_resolved.taken=n_b_taken;
      n_b_resolved.next_pc=n_b_taken?n_b_q.target:n_b_q.next_pc;
      n_b_resolved.redirect=n_b_q.pred_next!=n_b_resolved.next_pc;
    end
  end
  logic n_b_valid_q,ret_b_valid_q;
  logic [63:0] dual_issue_q,dual_retire_q;
  wire commit_second_fire=commit_fire&&ret_b_valid_q;
  wire [63:0] committed_next_pc=ret_b_valid_q?ret_b_q.next_pc:ret_next_pc_q;
  wire [63:0] resolved_next_pc=n_b_valid_q?n_b_resolved.next_pc:n_q.next_pc;
  logic n_valid_q,n_redirected_q;
  wire n_forward=n_valid_q&&n_q.write_rd&&!n_q.trap&&n_q.rd!=0;
  wire n_redirect_fire=n_valid_q&&(n_q.redirect||(n_b_valid_q&&n_b_resolved.redirect))&&!n_redirected_q&&!retirement_redirect;
  wire n_to_c=aresetn_i&&n_valid_q&&!retirement_redirect&&(!ret_valid_q||(commit_fire&&!n_q.trap));
  fetch_packet_t f_q,d0_q;
  fetch_packet_t f0_q,f1_q,f2_q,returned_packet,debug_fetch,request_head_packet;
  logic [$bits(f0_q)-1:0] f3_q [0:1];
  logic [$bits(f0_q)-1:0] request_q [0:3];
  assign request_head_packet=request_q[request_head_q];
  logic f0_valid_q,f1_valid_q,f1_ready_q,f1_killed_q,f2_valid_q,f2_killed_q;
  logic [63:0] f1_pa_q,f2_pa_q;
  logic [2:0] f1_prot_q,f2_prot_q;
  logic f3_head_q,f3_tail_q;
  logic [1:0] f3_count_q,request_head_q,request_tail_q;
  logic [2:0] request_count_q;
  wire unused_front_debug=^{d0_q.second_valid,d0_q.second_insn,d0_q.second_pred_next,d0_q.second_pred_hit,d0_q.second_pred_taken,debug_fetch.second_valid,debug_fetch.second_insn,debug_fetch.second_pred_next,debug_fetch.second_pred_hit,debug_fetch.second_pred_taken,f2_pa_q[2:0],debug_fetch.epoch,debug_fetch.pred_next,debug_fetch.insn,debug_fetch.if_error,debug_fetch.if_page_fault,debug_fetch.pred_hit,debug_fetch.pred_taken};
  uop_t d1_q,x_q,m_q,decoded;
  uop_t d1_b_q,x_b_q,m_b_q,decoded_b;
  fetch_packet_t d0_b_q;
  logic d0_b_valid_q,d1_b_valid_q,x_b_valid_q,m_b_valid_q;
  logic [63:0] raw_b_rf_r1,raw_b_rf_r2,x_b_alu_result,m_b_alu_q;
  logic x_b_alu_illegal,x_b_eq,x_b_lt,x_b_ltu;
  wire unused_second_metadata=^{d0_b_q,x_b_q,m_b_q,n_b_q,ret_b_q,x_b_eq,x_b_lt,x_b_ltu};
  logic [63:0] bp_b_next;
  logic bp_b_ready,bp_b_hit,bp_b_taken,bp_b_ras_used;
  logic [1:0] bp_b_kind;
  wire unused_second_prediction=^{bp_b_ready,bp_b_ras_used,bp_b_kind};
  logic d0_valid_q,d1_valid_q,x_valid_q,m_valid_q;
  logic [63:0] m_alu_q;
  // R42: registered I-stage address; early requests never carry a live X ALU result.
  logic [63:0] x_load_addr_q;
  logic m_early_safe_q,m_load_early_safe_q;
  logic m_alu_illegal_q,m_eq_q,m_lt_q,m_ltu_q;
  logic ret_valid_q,ret_serialize_q;
  logic [63:0] ret_seq_q,ret_epoch_q,epoch_q,fetch_seq_q;
  logic ret_branch_q,ret_pred_hit_q,ret_pred_taken_q,ret_taken_q,ret_push_q,ret_pop_q;
  logic [1:0] ret_kind_q;
  logic [63:0] ret_target_q,ret_pred_next_q;
  logic [63:0] branches_q,pred_hits_q,pred_taken_q,mispredicts_q;
  logic bp_ready,bp_hit,bp_taken,bp_ras_used;
  logic [1:0] bp_kind;
  logic [63:0] bp_next;
  logic [63:0] front_pc_q,page_va_q;
  logic c_fetch_busy_q;
  logic [51:0] page_ppn_q;
  logic page_valid_q,front_block_q,irq_wait_q;
  logic [63:0] architectural_pc_q,irq_pc_q;
  logic halted_q;
  wire backend_empty=!d0_valid_q&&!d1_valid_q&&!x_valid_q&&!m_valid_q&&!n_valid_q&&!ret_valid_q;
  wire unused_m_controls=^{m_q.alu,m_q.imm,m_q.a_pc,m_q.a_zero,m_q.b_imm};
  wire m_simple=m_q.kind==1&&!m_q.illegal&&!m_q.if_error&&!m_alu_illegal_q;
  wire m_load_ready=m_q.kind==2&&mem_result_ready&&!mem_result_error&&!m_q.illegal&&!m_q.if_error&&
    !m_alu_illegal_q&&!data_pre_fault&&!data_xlate_fault;
  wire m_md_ready=m_q.kind==11&&md_result_ready&&!md_result_error&&!m_q.illegal&&!m_q.if_error&&!m_alu_illegal_q;
  wire m_forward=m_valid_q&&(m_simple||m_load_ready||m_md_ready)&&m_q.write_rd&&m_q.rd!=0;
  wire [63:0] m_forward_data=m_simple?m_alu_q:m_load_ready?mem_result_data:md_result_data;
  wire ret_forward=ret_valid_q&&ret_write_q&&!ret_trap_q&&ret_rd_q!=0;
  // One ALU to operand-register path; no second ALU is cascaded in this cycle.
  wire x_forward=x_valid_q&&x_q.kind==1&&x_q.write_rd&&x_q.rd!=0&&
    !x_q.illegal&&!x_q.if_error&&!x_alu_illegal;
  wire x_dep=x_valid_q&&x_q.write_rd&&x_q.rd!=0&&!x_forward&&
    ((d1_q.use1&&d1_q.rs1==x_q.rd)||(d1_q.use2&&d1_q.rs2==x_q.rd));
  wire m_dep=m_valid_q&&m_q.write_rd&&m_q.rd!=0&&!m_forward&&
    ((d1_q.use1&&d1_q.rs1==m_q.rd)||(d1_q.use2&&d1_q.rs2==m_q.rd));
  wire x_b_forward=x_b_valid_q&&x_b_q.write_rd&&x_b_q.rd!=0&&!x_b_alu_illegal;
  wire m_b_forward=m_b_valid_q&&m_b_q.write_rd&&m_b_q.rd!=0;
  wire n_b_forward=n_b_valid_q&&n_b_q.write_rd&&n_b_q.rd!=0;
  wire ret_b_forward=ret_b_valid_q&&ret_b_q.write_rd&&ret_b_q.rd!=0;
  wire primary_dep_b=x_b_valid_q&&!x_b_forward&&x_b_q.rd!=0&&x_b_q.write_rd&&
    ((d1_q.use1&&d1_q.rs1==x_b_q.rd)||(d1_q.use2&&d1_q.rs2==x_b_q.rd));
  wire pair_raw=d1_q.write_rd&&d1_q.rd!=0&&
    ((d1_b_q.use1&&d1_b_q.rs1==d1_q.rd)||(d1_b_q.use2&&d1_b_q.rs2==d1_q.rd));
  wire pair_waw=d1_q.write_rd&&d1_b_q.write_rd&&d1_q.rd!=0&&d1_q.rd==d1_b_q.rd;
  wire second_x_dep=x_valid_q&&x_q.write_rd&&x_q.rd!=0&&!x_forward&&
    ((d1_b_q.use1&&d1_b_q.rs1==x_q.rd)||(d1_b_q.use2&&d1_b_q.rs2==x_q.rd));
  wire second_m_dep=m_valid_q&&m_q.write_rd&&m_q.rd!=0&&!m_forward&&
    ((d1_b_q.use1&&d1_b_q.rs1==m_q.rd)||(d1_b_q.use2&&d1_b_q.rs2==m_q.rd));
  wire second_conditional=d1_b_q.kind==4&&d1_b_q.imm[1:0]==0&&d1_q.kind!=4;
  wire pair_allowed=!ENABLE_C&&d1_b_valid_q&&d1_b_q.pc==d1_q.pc+64'd4&&
    !d1_q.illegal&&!d1_q.if_error&&!d1_q.sys&&!d1_q.atomic_op&&
    (d1_q.kind==1||d1_q.kind==2||d1_q.kind==3||d1_q.kind==11||
      (d1_q.kind==4&&d1_q.pred_next==d1_q.pc+64'd4))&&
    (d1_b_q.kind==1||second_conditional)&&!d1_b_q.illegal&&!d1_b_q.if_error&&!d1_b_q.sys&&!d1_b_q.atomic_op&&
    (!pair_raw||second_conditional)&&!pair_waw&&!second_x_dep&&!second_m_dep;
  wire issue_second_fire=issue_fire&&pair_allowed;
  wire issue_bundle_drain=issue_fire&&(!d1_b_valid_q||issue_second_fire);
  // After issuing only the lower I head, retain its upper head and append the
  // next D block's lower instruction. RF reads still occur next cycle in I.
  // The next block retains its own upper instruction; neither is duplicated.
  wire compact_fire=!ENABLE_C&&issue_fire&&d1_b_valid_q&&!issue_second_fire&&d0_valid_q&&
    d0_q.pc==d1_b_q.pc+64'd4&&d0_q.seq==d1_b_q.seq+64'd1&&d0_q.epoch==d1_b_q.epoch;
  wire decode_bundle_drain=decode_fire||(compact_fire&&!d0_b_valid_q);
  wire m_serial=m_q.sys||m_q.atomic_op||m_q.kind==7||m_q.kind==8;
  wire x_serial=x_q.sys||x_q.atomic_op||x_q.kind==7||x_q.kind==8;
  wire i_serial=d1_q.sys||d1_q.atomic_op||d1_q.kind==7||d1_q.kind==8;
  wire serial_hazard=(m_valid_q&&m_serial)||(x_valid_q&&x_serial)||(n_valid_q&&(n_q.serialize||n_q.trap||n_q.irq))||(ret_valid_q&&(ret_serialize_q||ret_trap_q||ret_irq_q));
  // A younger non-speculative memory effect must finish before taking an
  // asynchronous interrupt at an older retirement boundary. Its response owner
  // remains live; pending IRQ prevents another early memory request behind it.
  wire retirement_irq=ENABLE_PRIV&&ENABLE_SU&&irq_pending&&!n_valid_q&&
    (!m_valid_q||(!mem_started_q&&!md_started_q&&!dx_started_q));
  wire retirement_redirect=commit_fire&&(ret_trap_q||ret_serialize_q||ret_irq_q||retirement_irq);
  wire execute_complete=aresetn_i&&state_q==S_EXEC&&!retirement_redirect&&
    (!n_valid_q||n_to_c)&&!n_redirect_fire&&
    (!access_op||if_error_q||system_illegal||sys_permission_error||data_pre_fault||data_xlate_fault||alu_illegal||mem_result_ready)&&
    (!md_op||if_error_q||d_illegal||alu_illegal||md_result_ready)&&
    (!fp_execute_op||if_error_q||system_illegal||sys_permission_error||fp_result_ready)&&
    (!sys_csr||sys_done_q)&&(!fence_op||(lsu_ready&&md_ready));
  wire m_redirect=n_redirect_fire;
  wire flush_young=retirement_redirect||m_redirect;
  // Local elastic handshakes permit simultaneous drain/refill. The X result is registered before M control.
  wire x_to_m=aresetn_i&&x_valid_q&&(!m_valid_q||execute_complete)&&!flush_young&&!irq_wait_q&&
    !(ENABLE_PRIV&&ENABLE_SU&&irq_pending&&(m_valid_q||n_valid_q||ret_valid_q));
  wire issue_fire=aresetn_i&&d1_valid_q&&(!x_valid_q||x_to_m)&&!flush_young&&!irq_wait_q&&
    !x_dep&&!m_dep&&!primary_dep_b&&!serial_hazard&&(!i_serial||(!x_valid_q&&!m_valid_q&&!n_valid_q&&!ret_valid_q));
  wire decode_fire=aresetn_i&&d0_valid_q&&(!d1_valid_q||issue_bundle_drain)&&!flush_young&&!irq_wait_q;
  // Registered response credit breaks the backend ready chain to cache R/AR.
  wire f_to_d=aresetn_i&&f3_count_q!=0&&(!d0_valid_q||decode_bundle_drain)&&!flush_young&&!front_block_q&&!irq_wait_q&&!retirement_irq;
  wire f3_space=f3_count_q<2;
  wire irq_boundary=backend_empty&&!irq_wait_q&&retirement_irq&&!halted_q;
  wire frontend_flush=flush_young||irq_boundary;
  wire response_live=request_count_q!=0&&request_head_packet.epoch==epoch_q&&!frontend_flush;
  wire frontend_older_empty=!f2_valid_q&&request_count_q==0&&f3_count_q==0;
  wire f2_fault_fire=aresetn_i&&f2_valid_q&&f2_q.if_error&&!f2_killed_q&&request_count_q==0&&f3_space&&!flush_young;
  wire f2_available=!f2_valid_q||ar_fire||f2_fault_fire;
  wire [3:0] request_reserved={1'b0,request_count_q}+4'(ar_fire)-4'(r_fire);
  wire f1_physical_ram=f1_pa_q>=64'h80000000&&f1_pa_q<64'h88000000;
  // First-page translation and non-RAM instruction reads are architectural-boundary operations.
  wire f1_safe=f1_q.if_error||f1_physical_ram||(backend_empty&&frontend_older_empty);
  wire f1_to_f2=aresetn_i&&f1_valid_q&&f1_ready_q&&!f1_killed_q&&f2_available&&request_reserved<4&&f1_safe&&!flush_young&&!front_block_q&&!irq_wait_q&&!retirement_irq;
  wire f0_to_f1=aresetn_i&&f0_valid_q&&(!f1_valid_q||f1_to_f2)&&!flush_young&&!front_block_q&&!irq_wait_q&&!retirement_irq;
  wire f0_allocate=aresetn_i&&(!ENABLE_C||!c_fetch_busy_q)&&(!f0_valid_q||f0_to_f1)&&!front_block_q&&!irq_wait_q&&state_q!=S_IRQ&&!(ret_valid_q&&ret_irq_q)&&!retirement_irq&&!halted_q&&!flush_young;
  wire c_split=ENABLE_C&&r_fire&&response_live&&!request_head_packet.c_tail&&
    request_head_packet.pc[2:0]==6&&m_axi_rresp_i==0&&m_axi_rdata_i[49:48]==3;
  wire f3_push=(r_fire&&response_live&&!c_split)||f2_fault_fire;
  logic [31:0] c_window,c_expanded;
  logic c_compressed,c_illegal;
  logic [2:0] c_length;
  wire [63:0] c_shifted=m_axi_rdata_i >> {request_head_packet.fetch_va[2:0],3'b000};
  assign c_window=request_head_packet.c_tail ? {m_axi_rdata_i[15:0],request_head_packet.raw_insn[15:0]} : c_shifted[31:0];
  rv64_rvc_decode c_decoder(.insn_i(c_window),.enable_d_i(ENABLE_FP),.expanded_o(c_expanded),
    .compressed_o(c_compressed),.illegal_o(c_illegal),.length_o(c_length));
  wire ar_fire=m_axi_arvalid_o&&m_axi_arready_i;
  wire r_fire=m_axi_rvalid_i&&m_axi_rready_o;
  wire commit_fire=commit_valid_o&&commit_ready_i;
  wire bp_train=ENABLE_BP&&commit_fire&&ret_branch_q&&!ret_trap_q;
  wire bp_flush=retirement_redirect||mmu_flush;
  wire branch_x=d_kind==4||d_kind==5||d_kind==6;
  wire link_rd=gpr_rd==1||gpr_rd==5;
  wire link_rs1=gpr_rs1==1||gpr_rs1==5;
  wire hint_push=(d_kind==5||d_kind==6)&&link_rd;
  wire hint_pop=d_kind==6&&link_rs1&&(!link_rd||gpr_rd!=gpr_rs1);
  wire [1:0] branch_kind=d_kind==4?2'd0:hint_pop?2'd3:hint_push?2'd2:2'd1;
  wire unused_prediction_metadata=bp_ready^bp_ras_used^^bp_kind;
  logic [63:0] overlap_q,prefetch_q,issued_q,killed_q,forward_q,raw_stall_q,issue_q,consecutive_q;
  logic prev_issue_q;
  // A stable retirement packet separates execute logic from architectural writeback.
  logic [63:0] ret_order_q;
  logic [63:0] ret_pc_q;
  logic [63:0] ret_next_pc_q;
  logic [31:0] ret_insn_q;
  logic [4:0] ret_rd_q;
  logic [4:0] ret_rs1_q;
  logic [4:0] ret_rs2_q;
  logic [63:0] ret_wdata_q;
  logic [63:0] ret_rs1_data_q;
  logic [63:0] ret_rs2_data_q;
  logic ret_trap_q;
  logic ret_unsupported_q;
  logic [63:0] ret_cause_q;
  logic [63:0] ret_tval_q;
  logic [1:0] ret_privilege_q;
  logic ret_write_q;
  logic ret_csr_write_q;
  logic [63:0] ret_csr_wdata_q,ret_csr_operand_q;
  logic ret_mret_q;
  logic ret_sret_q;
  logic ret_sfence_q;
  logic ret_irq_q;

  // D0 owns decode. D1 owns RF addresses; operands are captured independently in X.
  logic raw_d_illegal;
  logic raw_d_write;
  logic raw_d_use1;
  logic raw_d_use2;
  logic [3:0] raw_d_kind;
  logic [4:0] raw_d_rd;
  logic [4:0] raw_d_rs1;
  logic [4:0] raw_d_rs2;
  logic [4:0] raw_d_alu;
  logic [63:0] raw_d_imm;
  logic raw_d_a_pc;
  logic raw_d_a_zero;
  logic raw_d_b_imm;
  logic [2:0] raw_d_branch;
  logic [1:0] raw_d_size;
  logic raw_d_unsigned;
  logic [3:0] raw_d_md_op;
  logic raw_atomic_encoded;
  logic raw_atomic_word;
  logic raw_sys_csr;
  logic raw_sys_mret;
  logic raw_sys_sret;
  logic raw_sys_sfence;
  logic raw_sys_wfi;
  logic raw_sys_encoded;
  logic raw_gpr_write;
  logic [4:0] raw_gpr_rd;
  logic [4:0] raw_gpr_rs1;
  logic [4:0] raw_gpr_rs2;
  logic raw_gpr_use1;
  logic raw_gpr_use2;
  logic [63:0] raw_rf_r1;
  logic [63:0] raw_rf_r2;

  logic [63:0] pc_q, order_q;
  logic [31:0] insn_q;
  logic if_error_q;
  logic if_page_fault_q;
  logic dx_started_q, dx_done_q, dx_error_q;
  logic [63:0] dx_pa_q, dx_cause_q;
  logic mmu_inflight_q, mmu_for_if_q;
  logic mmu_ready, mmu_valid, mmu_error, unused_mmu_hit;
  logic [63:0] mmu_pa, mmu_cause, unused_mmu_tval;
  logic ptw_valid, ptw_write, ptw_exclusive, ptw_rsp_ready;
  logic [1:0] ptw_size;
  logic [63:0] ptw_addr, ptw_data;
  logic d_illegal;
  logic [3:0] d_kind;
  logic [2:0] d_branch;
  logic [1:0] d_size;
  logic d_unsigned;
  logic [3:0] unused_pred, unused_succ;
  logic [3:0] d_md_op;
  logic [63:0] rf_r1, rf_r2, alu_a, alu_b, alu_result;
  logic alu_illegal, unused_eq, unused_lt, unused_ltu;
  logic branch_taken, branch_lt, branch_ltu;
  logic [63:0] target, next_pc, wb_data;
  logic trap, unsupported;
  logic [63:0] cause, tval;
  logic mem_started_q, mem_done_q, mem_error_q;
  logic [63:0] mem_data_q, mem_cause_q, mem_tval_q;
  logic lsu_req, lsu_ready, lsu_valid, lsu_rsp_ready, lsu_error;
  logic [63:0] lsu_data, lsu_cause, lsu_tval;
  logic lsu_bus_valid, lsu_exokay;
  logic atom_legal, atom_req, atom_ready, atom_valid, atom_rsp_ready, atom_error;
  logic abus_valid, abus_write, abus_exclusive, abus_rsp_ready;
  logic [1:0] abus_size;
  logic [63:0] abus_addr, abus_data, atom_data, atom_cause, atom_tval;
  logic atomic_encoded;
  assign raw_atomic_encoded=ENABLE_A && atom_legal && d0_q.insn[6:0]==7'h2f &&
    (d0_q.insn[14:12]==2 || d0_q.insn[14:12]==3) && (d0_q.insn[31:27]!=2 || d0_q.insn[24:20]==0);
  wire access_op=memory_op || atomic_encoded;
  logic atomic_word;
  assign raw_atomic_word=d0_q.insn[14:12]==2;
  wire [63:0] access_va=atomic_encoded ? rf_r1 : alu_result;
  // Effective privilege already applies MPRV/MPP in the CSR module. S/U with
  // Sv39 must use the translator, even while the architectural core is in M.
  wire instruction_translation_bypass=!HAS_MMU || privilege==3 || satp_value[63:60]==0;
  wire data_translation_bypass=!HAS_MMU || data_privilege==3 || satp_value[63:60]==0;
  wire [63:0] cpu_data_pa=data_translation_bypass ? access_va : dx_pa_q;
  wire [1:0] access_size=atomic_encoded ? (atomic_word ? 2'd2 : 2'd3) : d_size;
  wire access_store=d_kind==3 || (atomic_encoded && insn_q[31:27]!=2);
  wire access_unaligned=access_size==3 ? |access_va[2:0] : access_size==2 ? |access_va[1:0] : access_size==1 ? access_va[0] : 1'b0;
  wire data_pre_fault=HAS_MMU && access_op && access_unaligned;
  wire data_xlate_fault=HAS_MMU && !data_translation_bypass && dx_done_q && dx_error_q;
  wire data_usable=(data_translation_bypass || (dx_done_q && !dx_error_q)) && !data_pre_fault;
  wire atomic_allowed=ATOMIC_RAM_BYTES>=8 && cpu_data_pa>=ATOMIC_RAM_BASE &&
    (cpu_data_pa-ATOMIC_RAM_BASE)<=ATOMIC_RAM_BYTES-(atomic_word ? 64'd4 : 64'd8);
  always_comb begin
    case(d0_q.insn[31:27])
      5'h00,5'h01,5'h02,5'h03,5'h04,5'h08,5'h0c,5'h10,5'h14,5'h18,5'h1c: atom_legal=1;
      default: atom_legal=0;
    endcase
  end
  wire memory_op=(d_kind==2 || d_kind==3);
  wire md_op=(d_kind==11);
  wire fence_op=(d_kind==7 || d_kind==8);
  logic md_started_q, md_done_q, md_error_q, md_req, md_ready, md_valid, md_rsp_ready, md_error;
  logic [63:0] md_data_q, md_data;
  // Fall-through results are captured only if the current M packet remains.
  wire lsu_result_fire=lsu_valid&&lsu_rsp_ready;
  wire atom_result_fire=atom_valid&&atom_rsp_ready;
  wire mem_result_ready=mem_done_q||lsu_result_fire||atom_result_fire;
  wire mem_result_error=mem_done_q?mem_error_q:atomic_encoded?atom_error:lsu_error;
  wire [63:0] mem_result_data=mem_done_q?mem_data_q:atomic_encoded?atom_data:lsu_data;
  wire [63:0] mem_result_cause=mem_done_q?mem_cause_q:atomic_encoded?atom_cause:lsu_cause;
  wire [63:0] mem_result_tval=mem_done_q?mem_tval_q:HAS_MMU?access_va:atomic_encoded?atom_tval:lsu_tval;
  wire md_result_fire=md_valid&&md_rsp_ready;
  wire md_result_ready=md_done_q||md_result_fire;
  wire md_result_error=md_done_q?md_error_q:md_error;
  wire [63:0] md_result_data=md_done_q?md_data_q:md_data;
  // Only known non-trapping, non-serializing older packets may overlap requests.
  // Redirect recovery and interrupt retirement suppress requests immediately.
  // R50: use registered older-packet metadata for memory issue. A B branch
  // in N blocks younger requests for the entire resolve cycle, including a
  // correct prediction. The late comparator/next-PC equality cannot enter
  // LSU VALID or D-cache RAM enable. Redirect still flushes D/I/X/M normally.
  wire n_memory_safe=!n_valid_q||(!n_q.trap&&!n_q.irq&&!n_q.serialize&&
    !n_q.redirect&&!(n_b_valid_q&&n_b_q.branch));
  wire older_request_safe=n_memory_safe&&
    (!ret_valid_q||(!ret_trap_q&&!ret_irq_q&&!ret_serialize_q))&&!retirement_redirect&&
    !(ENABLE_PRIV&&ENABLE_SU&&irq_pending&&(n_valid_q||ret_valid_q));
  wire raw_fp_load=ENABLE_FP&&d0_q.insn[6:0]==7'h07;
  wire raw_fp_store=ENABLE_FP&&d0_q.insn[6:0]==7'h27;
  wire raw_fp_exec=ENABLE_FP&&(d0_q.insn[6:0]==7'h53||d0_q.insn[6:0]==7'h43||d0_q.insn[6:0]==7'h47||d0_q.insn[6:0]==7'h4b||d0_q.insn[6:0]==7'h4f);
  wire raw_fp_op=raw_fp_load||raw_fp_store||raw_fp_exec;
  wire raw_fp_mem_valid=d0_q.insn[14:12]==2||d0_q.insn[14:12]==3;
  wire raw_fp_int_write=raw_fp_exec&&d0_q.insn[6:0]==7'h53&&(d0_q.insn[31:27]==5'h14||d0_q.insn[31:27]==5'h18||d0_q.insn[31:27]==5'h1c)&&d0_q.insn[11:7]!=0;
  wire raw_fp_int_read=raw_fp_exec&&d0_q.insn[6:0]==7'h53&&(d0_q.insn[31:27]==5'h1a||d0_q.insn[31:27]==5'h1e);
  logic fp_enabled,fp_sd;logic [1:0] fp_fs;logic [2:0] fp_frm;logic [4:0] fp_fflags;
  logic [63:0] fp_r1,fp_r2,fp_r3,fp_csr_rdata;
  logic fp_csr_illegal;
  logic fp_started_q,fp_done_q,fp_error_q,fp_integer_q;
  logic [63:0] fp_data_q;logic [4:0] fp_flags_q;
  logic fp_req_ready,fp_rsp_valid,fp_rsp_ready,fp_rsp_integer,fp_rsp_illegal;
  logic [63:0] fp_rsp_data;logic [4:0] fp_rsp_flags;
  wire fp_execute_op=ENABLE_FP&&m_q.fp_exec;
  wire fp_req=aresetn_i&&state_q==S_EXEC&&older_request_safe&&!flush_young&&fp_execute_op&&fp_enabled&&!if_error_q&&!m_q.rvc_illegal&&!fp_started_q;
  wire fp_rsp_fire=fp_rsp_valid&&fp_rsp_ready;
  wire fp_result_ready=fp_done_q||fp_rsp_fire;
  wire fp_result_error=fp_done_q?fp_error_q:fp_rsp_illegal;
  wire fp_result_integer=fp_done_q?fp_integer_q:fp_rsp_integer;
  wire [63:0] fp_result_data=fp_done_q?fp_data_q:fp_rsp_data;
  wire [4:0] fp_result_flags=fp_done_q?fp_flags_q:fp_rsp_flags;
  assign fp_rsp_ready=aresetn_i&&state_q==S_EXEC&&fp_started_q&&!fp_done_q;
  logic sys_csr;
  assign raw_sys_csr=ENABLE_PRIV && d0_q.insn[6:0]==7'h73 && d0_q.insn[14:12]!=0 && d0_q.insn[14:12]!=4;
  logic sys_mret;
  assign raw_sys_mret=ENABLE_PRIV && d0_q.insn==32'h30200073;
  logic sys_sret;
  assign raw_sys_sret=ENABLE_PRIV && ENABLE_SU && d0_q.insn==32'h10200073;
  logic sys_sfence;
  assign raw_sys_sfence=ENABLE_PRIV && ENABLE_SU && (d0_q.insn&32'hfe007fff)==32'h12000073;
  logic sys_wfi;
  assign raw_sys_wfi=ENABLE_PRIV && d0_q.insn==32'h10500073; // WFI may legally act as a NOP.
  logic sys_encoded;
  assign raw_sys_encoded=raw_sys_csr || raw_sys_mret || raw_sys_sret || raw_sys_sfence || raw_sys_wfi;
  wire system_illegal=m_q.rvc_illegal||m_q.fp_ls_bad || (d_illegal && !sys_encoded && !atomic_encoded);
  logic gpr_write;
  assign raw_gpr_write=raw_d_write || raw_fp_int_write || ((raw_sys_csr || raw_atomic_encoded) && d0_q.insn[11:7]!=0);
  logic [4:0] gpr_rd;
  assign raw_gpr_rd=(raw_sys_csr || raw_atomic_encoded || raw_fp_int_write) ? d0_q.insn[11:7] : raw_d_rd;
  logic [4:0] gpr_rs1;
  assign raw_gpr_rs1=((raw_sys_csr && !d0_q.insn[14]) || raw_sys_sfence || raw_atomic_encoded || raw_fp_load || raw_fp_store || raw_fp_int_read) ? d0_q.insn[19:15] : raw_d_rs1;
  logic [4:0] gpr_rs2;
  assign raw_gpr_rs2=(raw_sys_sfence || raw_atomic_encoded) ? d0_q.insn[24:20] : raw_d_rs2;
  logic gpr_use1;
  assign raw_gpr_use1=raw_fp_load||raw_fp_store||raw_fp_int_read||(raw_sys_csr && !d0_q.insn[14]) || raw_sys_sfence || raw_atomic_encoded || raw_d_use1;
  logic gpr_use2;
  assign raw_gpr_use2=raw_sys_sfence || (raw_atomic_encoded && d0_q.insn[31:27]!=2) || raw_d_use2;
  wire rf_we=commit_fire && !ret_trap_q && ret_write_q;
  logic sys_done_q, sys_error_q;
  logic [63:0] sys_data_q, csr_rdata, unused_csr_wdata, trap_target, return_pc;
  logic csr_illegal,csr_base_illegal;
  logic [63:0] csr_base_rdata;
  wire [11:0] csr_query_addr=ret_valid_q?ret_insn_q[31:20]:n_valid_q?n_q.insn[31:20]:insn_q[31:20];
  wire fp_csr_query=ENABLE_FP&&(csr_query_addr==1||csr_query_addr==2||csr_query_addr==3);
  wire fp_status_query=csr_query_addr==12'h300||csr_query_addr==12'h100;
  assign csr_rdata=fp_csr_query?fp_csr_rdata:csr_base_rdata|((ENABLE_FP&&fp_status_query)?((64'(fp_fs)<<13)|(64'(fp_sd)<<63)):64'b0)|((ENABLE_FP&&csr_query_addr==12'h301)?64'h28:64'b0);
  assign csr_illegal=fp_csr_query?fp_csr_illegal:csr_base_illegal;
  logic [1:0] privilege, data_privilege;
  logic mret_illegal, sret_illegal, irq_pending;
  logic [63:0] priv_status, satp_value, irq_cause, irq_cause_q;
  logic adue;
  wire unused_status_bits=^{priv_status[63:22],priv_status[17:0]};
  wire unused_external_interrupts=^{irq_msip_i,irq_mtip_i,irq_meip_i,irq_seip_i,time_i};
  wire sys_permission_error=(ENABLE_FP&&m_q.fp_op&&!fp_enabled)||(sys_mret && mret_illegal) || (sys_sret && sret_illegal) ||
    (sys_wfi && (privilege==0 || (privilege==1 && priv_status[21]))) ||
    (sys_sfence && (privilege==0 || (privilege==1 && priv_status[20])));
  wire [2:0] unused_lsu_arprot, unused_lsu_awprot;
  wire unused_csr_write_intent=sys_csr && (insn_q[13:12]==1 || insn_q[19:15]!=0);
  wire [63:0] csr_operand=insn_q[14] ? {59'b0,insn_q[19:15]} : rf_r1;
  wire mmu_owner=HAS_MMU && mmu_inflight_q;
  wire mmu_req_if=HAS_MMU && f1_valid_q && !f1_ready_q && !f1_killed_q && !mmu_inflight_q && backend_empty && frontend_older_empty && !front_block_q && !irq_wait_q && !retirement_irq && !halted_q && !flush_young;
  wire mmu_req_data=HAS_MMU && !data_translation_bypass && state_q==S_EXEC && !ret_valid_q && !n_valid_q && !flush_young && access_op && !if_error_q && !system_illegal && !sys_permission_error &&
    !alu_illegal && !data_pre_fault && !dx_started_q && !dx_done_q;
  wire mmu_req=aresetn_i && (mmu_req_if || mmu_req_data);
  wire mmu_rsp_ready=aresetn_i && mmu_owner;
  wire mmu_req_fire=mmu_req && mmu_ready;
  wire mmu_rsp_fire=mmu_valid && mmu_rsp_ready;

  wire mmu_flush=HAS_MMU && commit_fire && !ret_trap_q && (ret_sfence_q ||
    (ret_csr_write_q && (ret_insn_q[31:20]==12'h180 || ret_insn_q[31:20]==12'h30a)));
  assign memory_ptw_o=mmu_owner;
  always_comb begin
    case(insn_q[13:12])
      1: unused_csr_wdata=csr_operand;
      2: unused_csr_wdata=sys_data_q | csr_operand;
      3: unused_csr_wdata=sys_data_q & ~csr_operand;
      default: unused_csr_wdata=0;
    endcase
  end
  generate if(ENABLE_PRIV) begin: privileged
    rv64_dual_csr #(.ENABLE_C(ENABLE_C),.ENABLE_SU(ENABLE_SU),.HAS_MMU(HAS_MMU),.ENABLE_A(ENABLE_A)) csrs (
      .clk_i(clk_i),.aresetn_i(aresetn_i),.addr_i(ret_valid_q ? ret_insn_q[31:20] : n_valid_q ? n_q.insn[31:20] : insn_q[31:20]),
      .write_intent_i(ret_valid_q ? ret_csr_write_q : n_valid_q ? n_q.csr_write : unused_csr_write_intent),.rdata_o(csr_base_rdata),.illegal_o(csr_base_illegal),
      .csr_commit_i(commit_fire && !ret_trap_q && ret_csr_write_q),.wdata_i(ret_csr_wdata_q),
      .csr_op_i(ret_insn_q[13:12]),.csr_operand_i(ret_csr_operand_q),
      .trap_i(commit_fire && ret_trap_q && !memory_fatal_o),
      .mret_i(commit_fire && !ret_trap_q && ret_mret_q),.retire_i(commit_fire && !ret_trap_q),
      .retire_second_i(commit_second_fire),
      .sret_i(commit_fire && !ret_trap_q && ret_sret_q),
      .return_s_i(ret_valid_q ? ret_sret_q : n_valid_q ? n_q.sret : sys_sret),
      .irq_msip_i(irq_msip_i),.irq_mtip_i(irq_mtip_i),.irq_meip_i(irq_meip_i),.irq_seip_i(irq_seip_i),.time_i(time_i),
      .trap_pc_i(ret_pc_q),.trap_cause_i(ret_valid_q ? ret_cause_q : n_valid_q ? n_q.cause : cause),.trap_tval_i(ret_tval_q),
      .trap_target_o(trap_target),.return_pc_o(return_pc),.status_o(priv_status),
      .privilege_o(privilege),.data_privilege_o(data_privilege),
      .mret_illegal_o(mret_illegal),.sret_illegal_o(sret_illegal),
      .irq_pending_o(irq_pending),.irq_cause_o(irq_cause),.satp_o(satp_value),.adue_o(adue)
    );
  end else begin: bare_eei
    assign csr_base_rdata=0;
    assign csr_base_illegal=0;
    assign trap_target=0;
    assign return_pc=0;
    assign priv_status=0;assign privilege=3;assign data_privilege=3;
    assign mret_illegal=0;assign sret_illegal=1;assign irq_pending=0;assign irq_cause=0;assign satp_value=0;assign adue=0;
  end endgenerate

  logic ret_fp_op_q,ret_fp_write_q,ret_fp_single_q;
  logic [4:0] ret_fp_rd_q,ret_fp_flags_q;logic [63:0] ret_fp_data_q;
  generate if(ENABLE_FP)begin: floating_point
    rv64_fp_state fp_state(
      .clk_i(clk_i),.rst_ni(aresetn_i),
      .fs_write_i(commit_fire&&!ret_trap_q&&ret_csr_write_q&&(ret_insn_q[31:20]==12'h300||ret_insn_q[31:20]==12'h100)),
      .fs_wdata_i(ret_csr_wdata_q[14:13]),.fs_o(fp_fs),.sd_o(fp_sd),.fp_enabled_o(fp_enabled),
      .rs1_i(d1_q.insn[19:15]),.rs2_i(d1_q.insn[24:20]),.rs3_i(d1_q.insn[31:27]),
      .rs1_o(fp_r1),.rs2_o(fp_r2),.rs3_o(fp_r3),
      .retire_i(commit_fire&&!ret_trap_q&&ret_fp_op_q),.retire_write_i(ret_fp_write_q),.retire_single_i(ret_fp_single_q),
      .retire_rd_i(ret_fp_rd_q),.retire_flags_i(ret_fp_flags_q),.retire_data_i(ret_fp_data_q),
      .csr_addr_i(csr_query_addr),.csr_op_i(2'd1),.csr_wdata_i(ret_csr_wdata_q),
      .csr_retire_i(commit_fire&&!ret_trap_q&&ret_csr_write_q&&fp_csr_query),
      .csr_rdata_o(fp_csr_rdata),.csr_illegal_o(fp_csr_illegal),.frm_o(fp_frm),.fflags_o(fp_fflags));
    rv64_fp_execute fpu(.clk_i(clk_i),.rst_ni(aresetn_i),.kill_i(flush_young),
      .req_valid_i(fp_req),.req_ready_o(fp_req_ready),.req_insn_i(insn_q),
      .req_a_i(m_q.fp_a),.req_b_i(m_q.fp_b),.req_c_i(m_q.fp_c),.req_integer_i(rf_r1),.req_frm_i(fp_frm),
      .rsp_valid_o(fp_rsp_valid),.rsp_ready_i(fp_rsp_ready),.rsp_result_o(fp_rsp_data),.rsp_flags_o(fp_rsp_flags),
      .rsp_integer_o(fp_rsp_integer),.rsp_illegal_o(fp_rsp_illegal));
  end else begin: no_floating_point
    assign fp_fs=0;assign fp_sd=0;assign fp_enabled=0;assign fp_frm=0;assign fp_fflags=0;
    assign fp_r1=0;assign fp_r2=0;assign fp_r3=0;assign fp_csr_rdata=0;assign fp_csr_illegal=1;
    assign fp_req_ready=0;assign fp_rsp_valid=0;assign fp_rsp_data=0;assign fp_rsp_flags=0;assign fp_rsp_integer=0;assign fp_rsp_illegal=1;
  end endgenerate
  always_ff @(posedge clk_i or negedge aresetn_i)begin
    if(!aresetn_i)begin fp_started_q<=0;fp_done_q<=0;fp_error_q<=0;fp_integer_q<=0;fp_data_q<=0;fp_flags_q<=0;end
    else begin
      if(x_to_m||flush_young)begin fp_started_q<=0;fp_done_q<=0;end
      else begin
        if(fp_req&&fp_req_ready)fp_started_q<=1;
        if(fp_rsp_fire)begin fp_done_q<=1;fp_error_q<=fp_rsp_illegal;fp_integer_q<=fp_rsp_integer;fp_data_q<=fp_rsp_data;fp_flags_q<=fp_rsp_flags;end
      end
    end
  end
  always_ff @(posedge clk_i or negedge aresetn_i)begin
    if(!aresetn_i)begin ret_fp_op_q<=0;ret_fp_write_q<=0;ret_fp_single_q<=0;ret_fp_rd_q<=0;ret_fp_flags_q<=0;ret_fp_data_q<=0;end
    else if(n_to_c)begin ret_fp_op_q<=n_q.fp_op;ret_fp_write_q<=n_q.fp_write;ret_fp_single_q<=n_q.fp_single;ret_fp_rd_q<=n_q.fp_rd;ret_fp_flags_q<=n_q.fp_flags;ret_fp_data_q<=n_q.fp_data;end
  end
  generate if(HAS_MMU) begin: virtual_memory
    rv64_mmu translate (
      .clk_i(clk_i),.aresetn_i(aresetn_i),.flush_i(mmu_flush),
      .req_valid_i(mmu_req),.req_ready_o(mmu_ready),
      .req_vaddr_i(mmu_req_if ? f1_q.fetch_va : access_va),.req_satp_i(satp_value),
      .req_access_i(mmu_req_if ? 2'd0 : access_store ? 2'd2 : 2'd1),
      .req_priv_i(mmu_req_if ? privilege : data_privilege),.req_sum_i(priv_status[18]),.req_mxr_i(priv_status[19]),.req_adue_i(adue),
      .rsp_valid_o(mmu_valid),.rsp_ready_i(mmu_rsp_ready),.rsp_paddr_o(mmu_pa),
      .rsp_cause_o(mmu_cause),.rsp_tval_o(unused_mmu_tval),.rsp_error_o(mmu_error),.rsp_hit_o(unused_mmu_hit),
      .bus_valid_o(ptw_valid),.bus_ready_i(lsu_ready && mmu_owner),
      .bus_write_o(ptw_write),.bus_exclusive_o(ptw_exclusive),.bus_size_o(ptw_size),.bus_addr_o(ptw_addr),.bus_data_o(ptw_data),
      .bus_rsp_valid_i(lsu_bus_valid && mmu_owner),.bus_rsp_ready_o(ptw_rsp_ready),
      .bus_rsp_data_i(lsu_data),.bus_rsp_error_i(lsu_error),.bus_rsp_exokay_i(lsu_exokay)
    );
  end else begin: physical_memory
    assign mmu_ready=1;assign mmu_valid=0;assign mmu_pa=0;assign mmu_cause=0;assign mmu_error=0;
    assign unused_mmu_tval=0;assign unused_mmu_hit=0;
    assign ptw_valid=0;assign ptw_write=0;assign ptw_exclusive=0;assign ptw_size=0;
    assign ptw_addr=0;assign ptw_data=0;assign ptw_rsp_ready=0;
    wire unused_translation_configuration=^{satp_value,adue,priv_status[19:18],mmu_flush,if_page_fault_q,
      dx_started_q,dx_done_q,dx_error_q,dx_pa_q,dx_cause_q};
  end endgenerate

  rv64_decode decode (
    .insn_i(d0_q.insn),.illegal_o(raw_d_illegal),.kind_o(raw_d_kind),
    .rd_o(raw_d_rd),.rs1_o(raw_d_rs1),.rs2_o(raw_d_rs2),
    .write_rd_o(raw_d_write),.use_rs1_o(raw_d_use1),.use_rs2_o(raw_d_use2),
    .imm_o(raw_d_imm),.alu_op_o(raw_d_alu),.alu_a_pc_o(raw_d_a_pc),
    .alu_a_zero_o(raw_d_a_zero),.alu_b_imm_o(raw_d_b_imm),.branch_op_o(raw_d_branch),
    .mem_size_o(raw_d_size),.mem_unsigned_o(raw_d_unsigned),
    .fence_pred_o(unused_pred),.fence_succ_o(unused_succ),.md_op_o(raw_d_md_op)
  );
  rv64_dual_regfile registers (
    .clk_i(clk_i),.rst_i(!aresetn_i),.we0_i(rf_we),.we1_i(commit_second_fire&&ret_b_q.write_rd),
    .waddr0_i(ret_rd_q),.waddr1_i(ret_b_q.rd),.wdata0_i(ret_wdata_q),.wdata1_i(ret_b_q.wdata),
    .raddr0_i(d1_q.rs1),.raddr1_i(d1_q.rs2),.raddr2_i(d1_b_q.rs1),.raddr3_i(d1_b_q.rs2),
    .rdata0_o(raw_rf_r1),.rdata1_o(raw_rf_r2),.rdata2_o(raw_b_rf_r1),.rdata3_o(raw_b_rf_r2)
  );
  rv64_alu second_alu (
    .op_i(x_b_q.alu),.a_i(x_b_q.a_zero?64'b0:x_b_q.a_pc?x_b_q.pc:x_b_q.r1),
    .b_i(x_b_q.b_imm?x_b_q.imm:x_b_q.r2),.result_o(x_b_alu_result),
    .illegal_o(x_b_alu_illegal),.eq_o(x_b_eq),.lt_o(x_b_lt),.ltu_o(x_b_ltu)
  );
  assign alu_a=x_q.a_zero ? 64'b0 : x_q.a_pc ? x_q.pc : x_q.r1;
  assign alu_b=x_q.b_imm ? x_q.imm : x_q.r2;
  logic [63:0] x_alu_result;
  logic x_alu_illegal, x_unused_eq, x_unused_lt, x_unused_ltu;
  rv64_alu execute_alu (
    .op_i(x_q.alu),.a_i(alu_a),.b_i(alu_b),.result_o(x_alu_result),
    .illegal_o(x_alu_illegal),.eq_o(x_unused_eq),.lt_o(x_unused_lt),.ltu_o(x_unused_ltu)
  );
  assign alu_result=m_alu_q;
  assign alu_illegal=m_alu_illegal_q;
  assign unused_eq=0;assign unused_lt=0;assign unused_ltu=0;
  assign md_req=aresetn_i && state_q==S_EXEC && older_request_safe && !retirement_redirect && md_op && !if_error_q &&
    !d_illegal && !alu_illegal && !md_started_q && !md_done_q;
  assign md_rsp_ready=aresetn_i && state_q==S_EXEC && md_started_q && !md_done_q;
  rv64_muldiv multiply_divide (
    .clk_i(clk_i),.aresetn_i(aresetn_i),.req_valid_i(md_req),.req_ready_o(md_ready),
    .req_op_i(d_md_op),.req_a_i(rf_r1),.req_b_i(rf_r2),.rsp_valid_o(md_valid),
    .rsp_ready_i(md_rsp_ready),.rsp_data_o(md_data),.rsp_illegal_o(md_error)
  );
  // R48 development: ordinary physical Load may follow a successfully completed
  // ordinary Load using independently accepted R44 LSU/R46 cache turnover.
  // No old response error or unresolved older packet may launch the younger read.
  // Only ordinary physical-RAM loads may launch with X->M ownership transfer.
  // Older M must be a completed, nonredirecting ALU or ordinary Load; N/C and IRQ guards
  // remain authoritative. MMIO, stores, atomics and translated data use M.
  wire x_load_aligned=x_q.size==3 ? !(|x_load_addr_q[2:0]) :
    x_q.size==2 ? !(|x_load_addr_q[1:0]) : x_q.size==1 ? !x_load_addr_q[0] : 1'b1;
  wire x_load_ram=ATOMIC_RAM_BYTES>=8 && x_load_addr_q>=ATOMIC_RAM_BASE &&
    x_load_addr_q-ATOMIC_RAM_BASE<=ATOMIC_RAM_BYTES-64'd8;
  // R45: capture the older legal ALU/fallthrough contract on X->M.
  // Do not feed cache R-valid -> generic execute_complete -> early cache AR.
  // A safe ALU has no variable-latency execution condition. N/C/IRQ still gate it.
  wire early_load_slot=!m_valid_q || ((m_early_safe_q||
    (m_load_early_safe_q&&mem_started_q&&m_load_ready))&&state_q==S_EXEC&&
    (!n_valid_q||n_to_c)&&n_memory_safe&&!retirement_redirect);
  wire early_load_handoff=aresetn_i&&x_valid_q&&early_load_slot&&n_memory_safe&&!retirement_redirect&&!irq_wait_q;
  wire early_lsu_req=!ENABLE_C&&early_load_handoff&&x_q.kind==2&&!x_q.illegal&&!x_q.if_error&&!x_q.atomic_op&&
    !x_alu_illegal&&x_load_aligned&&x_load_ram&&data_translation_bypass&&
    older_request_safe&&!irq_pending&&!mmu_owner&&!mmu_inflight_q;
  // R47 select the X payload before late IRQ/N/C request suppression.
  // Empty M / legal ALU owns no request; an ordinary Load with mem_started_q
  // already transferred its request into the LSU and owns only its old response. Request VALID keeps every original precise guard.
  wire early_lsu_payload=x_valid_q&&x_q.kind==2&&
    (!m_valid_q||m_early_safe_q||(m_load_early_safe_q&&mem_started_q));
  wire early_lsu_fire=early_lsu_req&&lsu_ready;
  wire lsu_selected_exclusive=mmu_owner ? ptw_exclusive : early_lsu_payload ? 1'b0 : (atomic_encoded&&abus_exclusive);
  assign lsu_req=aresetn_i && state_q==S_EXEC && older_request_safe && !retirement_redirect && memory_op && data_usable && !sys_permission_error &&
    !if_error_q && !d_illegal && !alu_illegal && !mem_started_q && !mem_done_q;
  assign lsu_rsp_ready=aresetn_i && state_q==S_EXEC && mem_started_q && !mem_done_q;
  assign atom_req=aresetn_i && state_q==S_EXEC && !ret_valid_q && !n_valid_q && !retirement_redirect && atomic_encoded && data_usable && !if_error_q &&
    !mem_started_q && !mem_done_q;
  assign atom_rsp_ready=aresetn_i && state_q==S_EXEC && atomic_encoded && mem_started_q && !mem_done_q;
  generate if(ENABLE_A) begin: atomics
    rv64_atomic atomic_access (
      .clk_i(clk_i),.aresetn_i(aresetn_i),.req_valid_i(atom_req),.req_ready_o(atom_ready),
      .req_op_i(insn_q[31:27]),.req_word_i(atomic_word),.req_allowed_i(atomic_allowed),
      .req_addr_i(cpu_data_pa),.req_operand_i(rf_r2),
      .kill_reservation_i((commit_fire && (ret_trap_q || ret_mret_q || ret_sret_q || ret_sfence_q)) ||
        (lsu_req && lsu_ready && d_kind==3)),
      .rsp_valid_o(atom_valid),.rsp_ready_i(atom_rsp_ready),.rsp_data_o(atom_data),
      .rsp_cause_o(atom_cause),.rsp_tval_o(atom_tval),.rsp_error_o(atom_error),
      .bus_valid_o(abus_valid),.bus_ready_i(lsu_ready && !mmu_owner),.bus_write_o(abus_write),
      .bus_exclusive_o(abus_exclusive),.bus_size_o(abus_size),.bus_addr_o(abus_addr),.bus_data_o(abus_data),
      .bus_rsp_valid_i(lsu_bus_valid && atomic_encoded && !mmu_owner),.bus_rsp_ready_o(abus_rsp_ready),
      .bus_rsp_data_i(lsu_data),.bus_rsp_error_i(lsu_error),.bus_rsp_exokay_i(lsu_exokay)
    );
  end else begin: no_atomics
    assign atom_ready=1;assign atom_valid=0;assign atom_data=0;assign atom_cause=0;assign atom_tval=0;assign atom_error=0;
    assign abus_valid=0;assign abus_write=0;assign abus_exclusive=0;assign abus_size=0;
    assign abus_addr=0;assign abus_data=0;assign abus_rsp_ready=0;
    wire unused_atomic_configuration=^{atomic_word,atomic_allowed,atom_req,atom_rsp_ready,lsu_exokay};
  end endgenerate
  assign lsu_valid=lsu_bus_valid && !atomic_encoded && !mmu_owner;
  rv64_lsu #(.ENABLE_EXCLUSIVE(ENABLE_A || HAS_MMU)) memory_access (
    .clk_i(clk_i),.aresetn_i(aresetn_i),.req_valid_i(mmu_owner ? ptw_valid : (lsu_req || early_lsu_req || abus_valid)),.req_ready_o(lsu_ready),
    .req_write_i(mmu_owner ? ptw_write : early_lsu_payload ? 1'b0 : atomic_encoded ? abus_write : d_kind==3),
    .req_unsigned_i(mmu_owner ? 1'b0 : early_lsu_payload ? x_q.unsigned_load : atomic_encoded ? 1'b0 : d_unsigned),
    .req_exclusive_i(lsu_selected_exclusive),
    .req_size_i(mmu_owner ? ptw_size : early_lsu_payload ? x_q.size : atomic_encoded ? abus_size : d_size),
    .req_addr_i(mmu_owner ? ptw_addr : early_lsu_payload ? x_load_addr_q : atomic_encoded ? abus_addr : cpu_data_pa),
    .req_wdata_i(mmu_owner ? ptw_data : early_lsu_payload ? 64'b0 : atomic_encoded ? abus_data : rf_r2),.rsp_valid_o(lsu_bus_valid),
    .rsp_ready_i(mmu_owner ? ptw_rsp_ready : atomic_encoded ? abus_rsp_ready : lsu_rsp_ready),.rsp_data_o(lsu_data),.rsp_cause_o(lsu_cause),
    .rsp_tval_o(lsu_tval),.rsp_error_o(lsu_error),.rsp_exokay_o(lsu_exokay),.fatal_o(memory_fatal_o),
    .m_axi_arvalid_o(d_axi_arvalid_o),.m_axi_arready_i(d_axi_arready_i),
    .m_axi_arid_o(d_axi_arid_o),.m_axi_araddr_o(d_axi_araddr_o),.m_axi_arlen_o(d_axi_arlen_o),
    .m_axi_arsize_o(d_axi_arsize_o),.m_axi_arprot_o(unused_lsu_arprot),.m_axi_arburst_o(d_axi_arburst_o),
    .m_axi_arlock_o(d_axi_arlock_o),.m_axi_arcache_o(d_axi_arcache_o),
    .m_axi_rvalid_i(d_axi_rvalid_i),.m_axi_rready_o(d_axi_rready_o),.m_axi_rid_i(d_axi_rid_i),
    .m_axi_rlast_i(d_axi_rlast_i),.m_axi_rdata_i(d_axi_rdata_i),.m_axi_rresp_i(d_axi_rresp_i),
    .m_axi_awvalid_o(d_axi_awvalid_o),.m_axi_awready_i(d_axi_awready_i),
    .m_axi_awid_o(d_axi_awid_o),.m_axi_awaddr_o(d_axi_awaddr_o),.m_axi_awlen_o(d_axi_awlen_o),
    .m_axi_awsize_o(d_axi_awsize_o),.m_axi_awprot_o(unused_lsu_awprot),.m_axi_awburst_o(d_axi_awburst_o),
    .m_axi_awlock_o(d_axi_awlock_o),.m_axi_awcache_o(d_axi_awcache_o),
    .m_axi_wvalid_o(d_axi_wvalid_o),.m_axi_wready_i(d_axi_wready_i),.m_axi_wdata_o(d_axi_wdata_o),
    .m_axi_wstrb_o(d_axi_wstrb_o),.m_axi_wlast_o(d_axi_wlast_o),
    .m_axi_bvalid_i(d_axi_bvalid_i),.m_axi_bready_o(d_axi_bready_o),.m_axi_bid_i(d_axi_bid_i),.m_axi_bresp_i(d_axi_bresp_i)
  );
  // The ALU computes branch targets from PC+imm; comparisons use GPRs, not ALU inputs.
  assign branch_lt=m_lt_q;
  assign branch_ltu=m_ltu_q;
  always_comb begin
    case(d_branch)
      0: branch_taken=m_eq_q;
      1: branch_taken=!m_eq_q;
      4: branch_taken=branch_lt;
      5: branch_taken=!branch_lt;
      6: branch_taken=branch_ltu;
      7: branch_taken=!branch_ltu;
      default: branch_taken=1'b0;
    endcase
    target=alu_result;
    if(d_kind==6) target=alu_result & ~64'd1; // JALR clears bit 0 before alignment check.
    next_pc=pc_q+64'(m_q.length);
    wb_data=alu_result;
    if(d_kind==2 || atomic_encoded) wb_data=mem_result_data;
    if(md_op) wb_data=md_result_data;
    if(fp_execute_op)wb_data=fp_result_data;
    if(sys_csr) wb_data=sys_data_q;
    trap=1'b0;unsupported=1'b0;cause=0;tval=0;
    if(d_kind==5 || d_kind==6) begin
      next_pc=target;wb_data=pc_q+64'(m_q.length); // C.JALR link is PC+2.
    end else if(d_kind==4 && branch_taken) next_pc=target;
    if(sys_mret || sys_sret) next_pc=return_pc;

    // Standard exception records; the selected EEI either stops or enters a trap.
    if(if_error_q) begin trap=1;cause=(HAS_MMU && if_page_fault_q) ? 64'd12 : 64'd1;tval=m_q.fetch_va; end
    else if(system_illegal || alu_illegal || sys_permission_error || (sys_csr && sys_done_q && sys_error_q)) begin trap=1;cause=2;tval={32'b0,m_q.raw_insn}; end
    else if(fp_execute_op&&fp_result_ready&&fp_result_error)begin trap=1;cause=2;tval={32'b0,m_q.raw_insn};end
    else if(d_kind==9) begin trap=1;cause=privilege==3 ? 64'd11 : privilege==1 ? 64'd9 : 64'd8; end
    else if(d_kind==10) begin trap=1;cause=3;tval=pc_q; end
    else if(data_pre_fault) begin trap=1;cause=access_store ? 64'd6 : 64'd4;tval=access_va;end
    else if(data_xlate_fault) begin trap=1;cause=dx_cause_q;tval=access_va;end
    else if(access_op && mem_result_ready && mem_result_error) begin
      trap=1;cause=mem_result_cause;tval=mem_result_tval;
    end
    else if(md_op && md_result_ready && md_result_error) begin trap=1;cause=2;tval={32'b0,m_q.raw_insn}; end
    else if(d_kind!=1 && !memory_op && !md_op && !fp_execute_op && !fence_op && !sys_encoded && !atomic_encoded && d_kind!=4 && d_kind!=5 && d_kind!=6) begin
      trap=1;unsupported=1;cause=2;tval={32'b0,m_q.raw_insn};
    end else if((d_kind==5 || d_kind==6 || (d_kind==4 && branch_taken)) && (target[0] || (!ENABLE_C && target[1]))) begin
      trap=1;cause=0;tval=target;
    end
    if(state_q==S_IRQ) begin trap=1;unsupported=0;cause=irq_cause_q;tval=0;end
    // Trap target is selected from the registered N packet, never in M control.
  end


  assign pc_q=m_q.pc;assign insn_q=m_q.insn;
  assign if_error_q=m_q.if_error;assign if_page_fault_q=m_q.if_page_fault;
  assign d_illegal=m_q.illegal;assign d_kind=m_q.kind;
  assign d_branch=m_q.branch_op;assign d_size=m_q.size;assign d_unsigned=m_q.unsigned_load;assign d_md_op=m_q.md_op;
  assign atomic_encoded=m_q.atomic_op;assign atomic_word=m_q.atomic_word;
  assign sys_csr=m_q.csr;assign sys_mret=m_q.mret;assign sys_sret=m_q.sret;
  assign sys_sfence=m_q.sfence;assign sys_wfi=m_q.wfi;assign sys_encoded=m_q.sys;
  assign gpr_write=m_q.write_rd;assign gpr_rd=m_q.rd;assign gpr_rs1=m_q.rs1;assign gpr_rs2=m_q.rs2;
  assign gpr_use1=m_q.use1;assign gpr_use2=m_q.use2;assign rf_r1=m_q.r1;assign rf_r2=m_q.r2;
  always_comb begin
    decoded='0;
    decoded.pc=d0_q.pc;decoded.seq=d0_q.seq;decoded.epoch=d0_q.epoch;decoded.pred_next=d0_q.pred_next;
    decoded.raw_insn=d0_q.raw_insn;decoded.length=d0_q.length;decoded.fetch_va=d0_q.fetch_va;decoded.rvc_illegal=d0_q.rvc_illegal;
    decoded.insn=d0_q.insn;decoded.if_error=d0_q.if_error;decoded.if_page_fault=d0_q.if_page_fault;
    decoded.pred_hit=d0_q.pred_hit;decoded.pred_taken=d0_q.pred_taken;
    decoded.illegal=raw_d_illegal;decoded.kind=raw_d_kind;decoded.alu=raw_d_alu;decoded.imm=raw_d_imm;
    decoded.write_rd=raw_gpr_write;decoded.rd=raw_gpr_rd;decoded.rs1=raw_gpr_rs1;decoded.rs2=raw_gpr_rs2;
    decoded.use1=raw_gpr_use1;decoded.use2=raw_gpr_use2;
    decoded.a_pc=raw_d_a_pc;decoded.a_zero=raw_d_a_zero;decoded.b_imm=raw_d_b_imm;
    decoded.branch_op=raw_d_branch;decoded.size=raw_d_size;decoded.unsigned_load=raw_d_unsigned;decoded.md_op=raw_d_md_op;
    decoded.atomic_op=raw_atomic_encoded;decoded.atomic_word=raw_atomic_word;
    decoded.csr=raw_sys_csr;decoded.mret=raw_sys_mret;decoded.sret=raw_sys_sret;
    decoded.sfence=raw_sys_sfence;decoded.wfi=raw_sys_wfi;decoded.sys=raw_sys_encoded||raw_fp_op;
    decoded.fp_op=raw_fp_op;decoded.fp_exec=raw_fp_exec;decoded.fp_load=raw_fp_load;decoded.fp_store=raw_fp_store;
    decoded.fp_ls_bad=(raw_fp_load||raw_fp_store)&&!raw_fp_mem_valid;
    if(raw_fp_op)begin
      decoded.illegal=0;decoded.kind=raw_fp_exec?4'd12:raw_fp_load?4'd2:4'd3;
      if(raw_fp_load||raw_fp_store)begin
        decoded.alu=0;decoded.a_pc=0;decoded.a_zero=0;decoded.b_imm=1;
        decoded.size=d0_q.insn[13:12];decoded.unsigned_load=1;
        decoded.imm=raw_fp_load?{{52{d0_q.insn[31]}},d0_q.insn[31:20]}:{{52{d0_q.insn[31]}},d0_q.insn[31:25],d0_q.insn[11:7]};
      end
    end
  end

  // Full second decode survives fallback to single issue.
  logic raw_b_d_illegal;
  logic raw_b_d_write;
  logic raw_b_d_use1;
  logic raw_b_d_use2;
  logic [3:0] raw_b_d_kind;
  logic [4:0] raw_b_d_rd;
  logic [4:0] raw_b_d_rs1;
  logic [4:0] raw_b_d_rs2;
  logic [4:0] raw_b_d_alu;
  logic [63:0] raw_b_d_imm;
  logic raw_b_d_a_pc;
  logic raw_b_d_a_zero;
  logic raw_b_d_b_imm;
  logic [2:0] raw_b_d_branch;
  logic [1:0] raw_b_d_size;
  logic raw_b_d_unsigned;
  logic [3:0] raw_b_d_md_op;
  logic raw_b_atomic_encoded;
  logic raw_b_atomic_word;
  logic raw_b_sys_csr;
  logic raw_b_sys_mret;
  logic raw_b_sys_sret;
  logic raw_b_sys_sfence;
  logic raw_b_sys_wfi;
  logic raw_b_sys_encoded;
  logic raw_b_gpr_write;
  logic [4:0] raw_b_gpr_rd;
  logic [4:0] raw_b_gpr_rs1;
  logic [4:0] raw_b_gpr_rs2;
  logic raw_b_gpr_use1;
  logic raw_b_gpr_use2;
  logic atom_legal_b;
  logic [3:0] unused_b_pred,unused_b_succ;
  wire unused_second_fence=^{unused_b_pred,unused_b_succ};
  assign raw_b_atomic_encoded=ENABLE_A && atom_legal_b && d0_b_q.insn[6:0]==7'h2f &&
    (d0_b_q.insn[14:12]==2 || d0_b_q.insn[14:12]==3) && (d0_b_q.insn[31:27]!=2 || d0_b_q.insn[24:20]==0);
  assign raw_b_atomic_word=d0_b_q.insn[14:12]==2;
  assign raw_b_sys_csr=ENABLE_PRIV && d0_b_q.insn[6:0]==7'h73 && d0_b_q.insn[14:12]!=0 && d0_b_q.insn[14:12]!=4;
  assign raw_b_sys_mret=ENABLE_PRIV && d0_b_q.insn==32'h30200073;
  assign raw_b_sys_sret=ENABLE_PRIV && ENABLE_SU && d0_b_q.insn==32'h10200073;
  assign raw_b_sys_sfence=ENABLE_PRIV && ENABLE_SU && (d0_b_q.insn&32'hfe007fff)==32'h12000073;
  assign raw_b_sys_wfi=ENABLE_PRIV && d0_b_q.insn==32'h10500073;
  assign raw_b_sys_encoded=raw_b_sys_csr || raw_b_sys_mret || raw_b_sys_sret || raw_b_sys_sfence || raw_b_sys_wfi;
  assign raw_b_gpr_write=raw_b_d_write || ((raw_b_sys_csr || raw_b_atomic_encoded) && d0_b_q.insn[11:7]!=0);
  assign raw_b_gpr_rd=(raw_b_sys_csr || raw_b_atomic_encoded) ? d0_b_q.insn[11:7] : raw_b_d_rd;
  assign raw_b_gpr_rs1=((raw_b_sys_csr && !d0_b_q.insn[14]) || raw_b_sys_sfence || raw_b_atomic_encoded) ? d0_b_q.insn[19:15] : raw_b_d_rs1;
  assign raw_b_gpr_rs2=(raw_b_sys_sfence || raw_b_atomic_encoded) ? d0_b_q.insn[24:20] : raw_b_d_rs2;
  assign raw_b_gpr_use1=(raw_b_sys_csr && !d0_b_q.insn[14]) || raw_b_sys_sfence || raw_b_atomic_encoded || raw_b_d_use1;
  assign raw_b_gpr_use2=raw_b_sys_sfence || (raw_b_atomic_encoded && d0_b_q.insn[31:27]!=2) || raw_b_d_use2;
  always_comb begin
    case(d0_b_q.insn[31:27])
      5'h00,5'h01,5'h02,5'h03,5'h04,5'h08,5'h0c,5'h10,5'h14,5'h18,5'h1c: atom_legal_b=1;
      default: atom_legal_b=0;
    endcase
  end
  rv64_decode second_decode (
    .insn_i(d0_b_q.insn),.illegal_o(raw_b_d_illegal),.kind_o(raw_b_d_kind),
    .rd_o(raw_b_d_rd),.rs1_o(raw_b_d_rs1),.rs2_o(raw_b_d_rs2),
    .write_rd_o(raw_b_d_write),.use_rs1_o(raw_b_d_use1),.use_rs2_o(raw_b_d_use2),
    .imm_o(raw_b_d_imm),.alu_op_o(raw_b_d_alu),.alu_a_pc_o(raw_b_d_a_pc),
    .alu_a_zero_o(raw_b_d_a_zero),.alu_b_imm_o(raw_b_d_b_imm),.branch_op_o(raw_b_d_branch),
    .mem_size_o(raw_b_d_size),.mem_unsigned_o(raw_b_d_unsigned),
    .fence_pred_o(unused_b_pred),.fence_succ_o(unused_b_succ),.md_op_o(raw_b_d_md_op)
  );

  always_comb begin
    decoded_b='0;
    decoded_b.pc=d0_b_q.pc;decoded_b.seq=d0_b_q.seq;decoded_b.epoch=d0_b_q.epoch;decoded_b.pred_next=d0_b_q.pred_next;
    decoded_b.raw_insn=d0_b_q.raw_insn;decoded_b.length=4;decoded_b.fetch_va=d0_b_q.pc;
    decoded_b.insn=d0_b_q.insn;decoded_b.if_error=d0_b_q.if_error;decoded_b.if_page_fault=d0_b_q.if_page_fault;
    decoded_b.pred_hit=d0_b_q.pred_hit;decoded_b.pred_taken=d0_b_q.pred_taken;
    decoded_b.illegal=raw_b_d_illegal;decoded_b.kind=raw_b_d_kind;decoded_b.alu=raw_b_d_alu;decoded_b.imm=raw_b_d_imm;
    decoded_b.write_rd=raw_b_gpr_write;decoded_b.rd=raw_b_gpr_rd;decoded_b.rs1=raw_b_gpr_rs1;decoded_b.rs2=raw_b_gpr_rs2;
    decoded_b.use1=raw_b_gpr_use1;decoded_b.use2=raw_b_gpr_use2;
    decoded_b.a_pc=raw_b_d_a_pc;decoded_b.a_zero=raw_b_d_a_zero;decoded_b.b_imm=raw_b_d_b_imm;
    decoded_b.branch_op=raw_b_d_branch;decoded_b.size=raw_b_d_size;decoded_b.unsigned_load=raw_b_d_unsigned;decoded_b.md_op=raw_b_d_md_op;
    decoded_b.atomic_op=raw_b_atomic_encoded;decoded_b.atomic_word=raw_b_atomic_word;
    decoded_b.csr=raw_b_sys_csr;decoded_b.mret=raw_b_sys_mret;decoded_b.sret=raw_b_sys_sret;
    decoded_b.sfence=raw_b_sys_sfence;decoded_b.wfi=raw_b_sys_wfi;decoded_b.sys=raw_b_sys_encoded;
  end
  wire [63:0] issue_r1=
    (x_b_forward&&x_b_q.rd==d1_q.rs1)?x_b_alu_result:
    (x_forward&&x_q.rd==d1_q.rs1)?x_alu_result:
    (m_b_forward&&m_b_q.rd==d1_q.rs1)?m_b_alu_q:
    (m_forward&&m_q.rd==d1_q.rs1)?m_forward_data:
    (n_b_forward&&n_b_q.rd==d1_q.rs1)?n_b_q.wdata:
    (n_forward&&n_q.rd==d1_q.rs1)?n_q.wdata:
    (ret_b_forward&&ret_b_q.rd==d1_q.rs1)?ret_b_q.wdata:
    (ret_forward&&ret_rd_q==d1_q.rs1)?ret_wdata_q:raw_rf_r1;
  wire [63:0] issue_r2=
    (x_b_forward&&x_b_q.rd==d1_q.rs2)?x_b_alu_result:
    (x_forward&&x_q.rd==d1_q.rs2)?x_alu_result:
    (m_b_forward&&m_b_q.rd==d1_q.rs2)?m_b_alu_q:
    (m_forward&&m_q.rd==d1_q.rs2)?m_forward_data:
    (n_b_forward&&n_b_q.rd==d1_q.rs2)?n_b_q.wdata:
    (n_forward&&n_q.rd==d1_q.rs2)?n_q.wdata:
    (ret_b_forward&&ret_b_q.rd==d1_q.rs2)?ret_b_q.wdata:
    (ret_forward&&ret_rd_q==d1_q.rs2)?ret_wdata_q:raw_rf_r2;
  wire [63:0] issue_b_r1=
    (x_b_forward&&x_b_q.rd==d1_b_q.rs1)?x_b_alu_result:
    (x_forward&&x_q.rd==d1_b_q.rs1)?x_alu_result:
    (m_b_forward&&m_b_q.rd==d1_b_q.rs1)?m_b_alu_q:
    (m_forward&&m_q.rd==d1_b_q.rs1)?m_forward_data:
    (n_b_forward&&n_b_q.rd==d1_b_q.rs1)?n_b_q.wdata:
    (n_forward&&n_q.rd==d1_b_q.rs1)?n_q.wdata:
    (ret_b_forward&&ret_b_q.rd==d1_b_q.rs1)?ret_b_q.wdata:
    (ret_forward&&ret_rd_q==d1_b_q.rs1)?ret_wdata_q:raw_b_rf_r1;
  wire [63:0] issue_b_r2=
    (x_b_forward&&x_b_q.rd==d1_b_q.rs2)?x_b_alu_result:
    (x_forward&&x_q.rd==d1_b_q.rs2)?x_alu_result:
    (m_b_forward&&m_b_q.rd==d1_b_q.rs2)?m_b_alu_q:
    (m_forward&&m_q.rd==d1_b_q.rs2)?m_forward_data:
    (n_b_forward&&n_b_q.rd==d1_b_q.rs2)?n_b_q.wdata:
    (n_forward&&n_q.rd==d1_b_q.rs2)?n_q.wdata:
    (ret_b_forward&&ret_b_q.rd==d1_b_q.rs2)?ret_b_q.wdata:
    (ret_forward&&ret_rd_q==d1_b_q.rs2)?ret_wdata_q:raw_b_rf_r2;
  // A presented F2 request survives redirects until AR is accepted. Its old epoch
  // then drains through the metadata FIFO without entering the returned packet bank.
  assign m_axi_arvalid_o=aresetn_i&&f2_valid_q&&!f2_q.if_error;
  assign m_axi_araddr_o={f2_pa_q[63:3],3'b000};assign m_axi_arprot_o=f2_prot_q;
  assign m_axi_rready_o=aresetn_i&&request_count_q!=0&&(!response_live||f3_space);
  assign d_axi_arprot_o=mmu_owner?3'b001:{2'b00,data_privilege!=0};
  assign d_axi_awprot_o=mmu_owner?3'b001:{2'b00,data_privilege!=0};
  assign commit_valid_o=aresetn_i && ret_valid_q;
  assign commit_order_o=ret_order_q;
  assign commit_pc_o=ret_pc_q;
  assign commit_next_pc_o=ret_next_pc_q;
  assign commit_insn_o=ret_insn_q;
  assign commit_rd_o=ret_rd_q;
  assign commit_rs1_o=ret_rs1_q;
  assign commit_rs2_o=ret_rs2_q;
  assign commit_wdata_o=ret_wdata_q;
  assign commit_rs1_data_o=ret_rs1_data_q;
  assign commit_rs2_data_o=ret_rs2_data_q;
  assign commit_trap_o=ret_trap_q;
  assign commit_unsupported_o=ret_unsupported_q;
  assign commit_cause_o=ret_cause_q;
  assign commit_tval_o=ret_tval_q;
  assign commit_privilege_o=ret_privilege_q;
  assign halted_o=aresetn_i && halted_q;


  always_comb begin
    f_q=f3_q[f3_head_q];
    returned_packet=request_head_packet;
    returned_packet.insn=m_axi_rresp_i==0?(request_head_packet.pc[2]?m_axi_rdata_i[63:32]:m_axi_rdata_i[31:0]):32'b0;
    returned_packet.raw_insn=returned_packet.insn;
    returned_packet.length=4;
    if(ENABLE_C)begin
      returned_packet.insn=c_expanded;
      returned_packet.raw_insn=c_compressed?{16'b0,c_window[15:0]}:c_window;
      returned_packet.length=c_length;
      returned_packet.rvc_illegal=c_illegal;
      returned_packet.pred_next=request_head_packet.pc+64'(c_length);
      returned_packet.pred_hit=0;returned_packet.pred_taken=0;
    end
    returned_packet.second_insn=m_axi_rdata_i[63:32];
    returned_packet.second_valid=!ENABLE_C&&request_head_packet.second_valid&&m_axi_rresp_i==0;
    returned_packet.if_error=m_axi_rresp_i!=0;
    returned_packet.if_page_fault=0;
    if(f2_fault_fire) returned_packet=f2_q;
    debug_fetch=f0_q;
    if(f1_valid_q)debug_fetch=f1_q;
    if(f2_valid_q)debug_fetch=f2_q;
    if(request_count_q!=0)debug_fetch=request_head_packet;
    if(f3_count_q!=0)debug_fetch=f3_q[f3_head_q];
  end
  // Four independent frontend banks. F3 is a two-entry ordered elastic buffer;
  // request_q carries only metadata for accepted cache requests, never fake data.
  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin
      f0_q<='0;f1_q<='0;f2_q<='0;
      f0_valid_q<=0;f1_valid_q<=0;f1_ready_q<=0;f1_killed_q<=0;f2_valid_q<=0;f2_killed_q<=0;
      f1_pa_q<=0;f2_pa_q<=0;f1_prot_q<=0;f2_prot_q<=0;
      for(integer j=0;j<2;j=j+1)f3_q[j]<='0;
      for(integer j=0;j<4;j=j+1)request_q[j]<='0;
      f3_head_q<=0;f3_tail_q<=0;f3_count_q<=0;
      request_head_q<=0;request_tail_q<=0;request_count_q<=0;
      front_pc_q<=RESET_PC;c_fetch_busy_q<=0;front_block_q<=0;page_valid_q<=0;page_va_q<=0;page_ppn_q<=0;
      fetch_seq_q<=0;epoch_q<=0;
    end else begin
      case({ar_fire,r_fire})
        2'b10:request_count_q<=request_count_q+1'b1;
        2'b01:request_count_q<=request_count_q-1'b1;
        default:begin end
      endcase
      if(ar_fire)begin request_q[request_tail_q]<=f2_q;request_tail_q<=request_tail_q+1'b1;end
      if(r_fire)request_head_q<=request_head_q+1'b1;
      case({f3_push,f_to_d})
        2'b10:f3_count_q<=f3_count_q+1'b1;
        2'b01:f3_count_q<=f3_count_q-1'b1;
        default:begin end
      endcase
      if(f3_push)begin f3_q[f3_tail_q]<=returned_packet;f3_tail_q<=!f3_tail_q;end
      if(f_to_d)f3_head_q<=!f3_head_q;
      if(f0_to_f1)f0_valid_q<=0;
      if(f1_to_f2)f1_valid_q<=0;
      if(ar_fire||f2_fault_fire)f2_valid_q<=0;
      if(f0_allocate)begin
        f0_valid_q<=1;f0_q<='0;f0_q.pc<=front_pc_q;f0_q.seq<=fetch_seq_q;f0_q.epoch<=epoch_q;
        f0_q.fetch_va<=front_pc_q;f0_q.length<=4;
        f0_q.pred_next<=bp_next;f0_q.pred_hit<=bp_hit;f0_q.pred_taken<=bp_taken;
        f0_q.second_valid<=!ENABLE_C&&!front_pc_q[2]&&!bp_taken;
        f0_q.second_pred_next<=bp_b_next;f0_q.second_pred_hit<=bp_b_hit;f0_q.second_pred_taken<=bp_b_taken;
        if(ENABLE_C)c_fetch_busy_q<=1;
        else front_pc_q<=(!front_pc_q[2]&&!bp_taken)?bp_b_next:bp_next;
        fetch_seq_q<=fetch_seq_q+(ENABLE_C?64'd1:64'd2);
      end
      if(ENABLE_C&&f3_push)begin
        c_fetch_busy_q<=0;
        front_pc_q<=returned_packet.pred_next;
      end
      if(c_split)begin
        f0_q<=request_head_packet;f0_valid_q<=1;
        f0_q.fetch_va<=request_head_packet.pc+64'd2;
        f0_q.c_tail<=1;f0_q.raw_insn<={16'b0,m_axi_rdata_i[63:48]};
      end
      if(state_q==S_IRQ)fetch_seq_q<=fetch_seq_q+1'b1;
      if(f0_to_f1)begin
        f1_valid_q<=1;f1_q<=f0_q;f1_killed_q<=0;f1_prot_q<={2'b10,privilege!=0};
        f1_ready_q<=0;f1_pa_q<=0;
        if(instruction_translation_bypass)begin f1_pa_q<=f0_q.fetch_va;f1_ready_q<=1;end
        else if(page_valid_q&&page_va_q=={f0_q.fetch_va[63:12],12'b0})begin
          f1_pa_q<={page_ppn_q,f0_q.fetch_va[11:0]};f1_ready_q<=1;
        end
      end
      if(f1_valid_q&&f1_killed_q&&!mmu_inflight_q)f1_valid_q<=0;
      if(mmu_rsp_fire&&mmu_for_if_q)begin
        if(f1_killed_q||flush_young)f1_valid_q<=0;
        else begin
          f1_ready_q<=1;f1_pa_q<=mmu_pa;
          f1_q.if_error<=mmu_error;f1_q.if_page_fault<=mmu_error&&mmu_cause==12;
          if(mmu_error)begin f1_q.insn<=0;page_valid_q<=0;end
          else begin
            page_va_q<={f1_q.fetch_va[63:12],12'b0};page_ppn_q<=mmu_pa[63:12];
            page_valid_q<=mmu_pa>=64'h80000000&&mmu_pa<64'h88000000;
          end
        end
      end
      if(f1_to_f2)begin
        f2_valid_q<=1;f2_q<=f1_q;f2_pa_q<=f1_pa_q;f2_prot_q<=f1_prot_q;f2_killed_q<=0;
      end
      if(frontend_flush)begin
        c_fetch_busy_q<=0;
        epoch_q<=epoch_q+1'b1;f0_valid_q<=0;
        f1_killed_q<=1;
        if(!(f1_valid_q&&mmu_inflight_q&&mmu_for_if_q))f1_valid_q<=0;
        f2_killed_q<=1;
        if(f2_q.if_error||ar_fire)f2_valid_q<=0;
        f3_count_q<=0;f3_head_q<=0;f3_tail_q<=0;
        if(irq_boundary)front_block_q<=1;
        if(m_redirect)begin front_pc_q<=resolved_next_pc;if(n_q.trap||n_q.serialize)front_block_q<=1;end
        if(retirement_redirect)begin front_pc_q<=committed_next_pc;front_block_q<=0;page_valid_q<=0;end
      end
      if(mmu_flush)page_valid_q<=0;
    end
  end

  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin
      d0_valid_q<=0;d1_valid_q<=0;x_valid_q<=0;d0_b_valid_q<=0;d1_b_valid_q<=0;x_b_valid_q<=0;m_valid_q<=0;
      d0_q<='0;d1_q<='0;x_q<='0;m_q<='0;
      d0_b_q<='0;d1_b_q<='0;x_b_q<='0;m_b_q<='0;
      d0_b_valid_q<=0;d1_b_valid_q<=0;x_b_valid_q<=0;m_b_valid_q<=0;m_b_alu_q<=0;
      m_alu_q<=0;m_alu_illegal_q<=0;m_eq_q<=0;m_lt_q<=0;m_ltu_q<=0;x_load_addr_q<=0;m_early_safe_q<=0;m_load_early_safe_q<=0;
      state_q<=S_BOUNDARY;order_q<=0;architectural_pc_q<=RESET_PC;halted_q<=0;
      mem_started_q<=0;mem_done_q<=0;mem_error_q<=0;mem_data_q<=0;mem_cause_q<=0;mem_tval_q<=0;
      md_started_q<=0;md_done_q<=0;md_error_q<=0;md_data_q<=0;sys_done_q<=0;sys_error_q<=0;sys_data_q<=0;
      dx_started_q<=0;dx_done_q<=0;dx_error_q<=0;dx_pa_q<=0;dx_cause_q<=0;
      mmu_inflight_q<=0;mmu_for_if_q<=0;irq_wait_q<=0;irq_pc_q<=RESET_PC;irq_cause_q<=0;
    end else begin
      if(decode_fire) begin d0_valid_q<=0;d0_b_valid_q<=0;end
      if(compact_fire) begin
        d0_valid_q<=d0_b_valid_q;d0_b_valid_q<=0;
        if(d0_b_valid_q)begin d0_q<=d0_b_q;d0_q.second_valid<=0;end
      end
      if(issue_fire) begin
        d1_valid_q<=0;d1_b_valid_q<=0;
        if(d1_b_valid_q&&!issue_second_fire)begin d1_q<=d1_b_q;d1_valid_q<=1;end
      end
      if(x_to_m) begin x_valid_q<=0;x_b_valid_q<=0;end
      if(execute_complete||state_q==S_IRQ) begin m_early_safe_q<=0;m_load_early_safe_q<=0;m_valid_q<=0;m_b_valid_q<=0;state_q<=S_BOUNDARY;end
      if(f_to_d) begin
        d0_q<=f_q;d0_valid_q<=1;d0_b_q<=f_q;d0_b_valid_q<=f_q.second_valid;
        d0_b_q.pc<=f_q.pc+64'd4;d0_b_q.seq<=f_q.seq+64'd1;
        d0_b_q.insn<=f_q.second_insn;d0_b_q.raw_insn<=f_q.second_insn;d0_b_q.length<=4;d0_b_q.pred_next<=f_q.second_pred_next;
        d0_b_q.pred_hit<=f_q.second_pred_hit;d0_b_q.pred_taken<=f_q.second_pred_taken;
        d0_b_q.second_valid<=0;
      end
      if(decode_fire) begin d1_q<=decoded;d1_valid_q<=1;d1_b_q<=decoded_b;d1_b_valid_q<=d0_b_valid_q;end
      if(compact_fire)begin d1_b_q<=decoded;d1_b_valid_q<=1;end
      if(issue_fire) begin
        x_q<=d1_q;x_q.r1<=issue_r1;x_q.r2<=d1_q.fp_store?fp_r2:issue_r2;
        x_q.fp_a<=fp_r1;x_q.fp_b<=fp_r2;x_q.fp_c<=fp_r3;x_valid_q<=1;
        x_load_addr_q<=issue_r1+d1_q.imm;
        x_b_q<=d1_b_q;x_b_q.r1<=issue_b_r1;x_b_q.r2<=issue_b_r2;x_b_valid_q<=issue_second_fire;
      end
      if(x_to_m) begin
        m_valid_q<=1;m_q<=x_q;m_alu_q<=x_alu_result;m_alu_illegal_q<=x_alu_illegal;
        m_early_safe_q<=x_q.kind==1&&!x_q.illegal&&!x_q.if_error&&!x_alu_illegal&&!x_serial&&
          x_q.pred_next==x_q.pc+64'd4&&(!x_b_valid_q||(x_b_q.kind!=4&&x_b_q.pred_next==x_b_q.pc+64'd4));
        m_load_early_safe_q<=x_q.kind==2&&!x_q.illegal&&!x_q.if_error&&!x_alu_illegal&&!x_serial&&!x_q.atomic_op&&
          x_q.pred_next==x_q.pc+64'd4&&(!x_b_valid_q||(x_b_q.kind!=4&&x_b_q.pred_next==x_b_q.pc+64'd4));
        m_b_valid_q<=x_b_valid_q;m_b_q<=x_b_q;m_b_alu_q<=x_b_alu_result;
        m_eq_q<=x_q.r1==x_q.r2;m_lt_q<=$signed(x_q.r1)<$signed(x_q.r2);m_ltu_q<=x_q.r1<x_q.r2;
        state_q<=S_EXEC;mem_started_q<=early_lsu_fire;mem_done_q<=0;md_started_q<=0;md_done_q<=0;sys_done_q<=0;
        dx_started_q<=0;dx_done_q<=0;dx_error_q<=0;
      end
      if(state_q==S_EXEC) begin
        if(sys_csr&&!sys_done_q&&!ret_valid_q&&!n_valid_q) begin sys_data_q<=csr_rdata;sys_error_q<=csr_illegal;sys_done_q<=1;end
        if(md_req&&md_ready) md_started_q<=1;
        if(md_result_fire&&!x_to_m) begin md_done_q<=1;md_error_q<=md_error;md_data_q<=md_data;end
        if(lsu_req&&lsu_ready) mem_started_q<=1;
        if(atom_req&&atom_ready) mem_started_q<=1;
        if(lsu_result_fire&&!x_to_m) begin
          mem_done_q<=1;mem_error_q<=lsu_error;mem_data_q<=lsu_data;mem_cause_q<=lsu_cause;mem_tval_q<=HAS_MMU?access_va:lsu_tval;
        end
        if(atom_result_fire&&!x_to_m) begin
          mem_done_q<=1;mem_error_q<=atom_error;mem_data_q<=atom_data;mem_cause_q<=atom_cause;mem_tval_q<=HAS_MMU?access_va:atom_tval;
        end
      end
      if(mmu_req_fire) begin mmu_inflight_q<=1;mmu_for_if_q<=mmu_req_if;if(!mmu_req_if) dx_started_q<=1;end
      if(mmu_rsp_fire) begin
        mmu_inflight_q<=0;
        if(!mmu_for_if_q) begin dx_pa_q<=mmu_pa;dx_error_q<=mmu_error;dx_cause_q<=mmu_cause;dx_done_q<=1;end
      end
      if(commit_fire) begin
        order_q<=order_q+64'd1+64'(ret_b_valid_q);architectural_pc_q<=committed_next_pc;
        if(ret_trap_q&&(!ENABLE_PRIV||memory_fatal_o)) halted_q<=1;
      end
      if(flush_young) begin
        d0_valid_q<=0;d1_valid_q<=0;x_valid_q<=0;d0_b_valid_q<=0;d1_b_valid_q<=0;x_b_valid_q<=0;
        if(retirement_redirect||n_redirect_fire) begin m_early_safe_q<=0;m_load_early_safe_q<=0;m_valid_q<=0;m_b_valid_q<=0;state_q<=S_BOUNDARY;end
      end
      if(retirement_redirect&&!ret_trap_q&&!ret_serialize_q&&!ret_irq_q&&retirement_irq) begin
        irq_wait_q<=1;irq_pc_q<=committed_next_pc;irq_cause_q<=irq_cause;
      end
      if(backend_empty&&!irq_wait_q&&retirement_irq&&!halted_q) begin
        irq_wait_q<=1;irq_pc_q<=architectural_pc_q;irq_cause_q<=irq_cause;
      end
      if(irq_wait_q&&!m_valid_q&&!n_valid_q&&!ret_valid_q&&!mmu_inflight_q) begin
        m_q<='0;m_q.pc<=irq_pc_q;m_q.seq<=fetch_seq_q;m_q.epoch<=epoch_q;
        m_early_safe_q<=0;m_load_early_safe_q<=0;m_valid_q<=1;state_q<=S_IRQ;irq_wait_q<=0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin n_q<='0;n_valid_q<=0;n_redirected_q<=0;end
    else begin
      if(n_redirect_fire) n_redirected_q<=1;
      if(n_to_c) n_valid_q<=0;
      if(execute_complete||state_q==S_IRQ) begin
        n_valid_q<=1;n_redirected_q<=0;
        n_q.fp_op<=m_q.fp_op;n_q.fp_write<=m_q.fp_load||(m_q.fp_exec&&!fp_result_integer);
        n_q.fp_single<=m_q.fp_load&&m_q.size==2;n_q.fp_rd<=insn_q[11:7];
        n_q.fp_flags<=m_q.fp_exec?fp_result_flags:5'b0;n_q.fp_data<=m_q.fp_load?mem_result_data:fp_result_data;
        n_q.pc<=pc_q;n_q.next_pc<=next_pc;n_q.seq<=m_q.seq;n_q.epoch<=m_q.epoch;n_q.insn<=m_q.raw_insn;
        n_q.rd<=(!trap&&gpr_write)?gpr_rd:5'b0;n_q.rs1<=gpr_rs1;n_q.rs2<=gpr_rs2;
        n_q.wdata<=(!trap&&gpr_write)?wb_data:64'b0;n_q.rs1_data<=gpr_use1?rf_r1:64'b0;n_q.rs2_data<=gpr_use2?rf_r2:64'b0;
        n_q.trap<=trap;n_q.unsupported<=unsupported;n_q.cause<=cause;n_q.tval<=tval;n_q.privilege<=privilege;
        n_q.write_rd<=gpr_write;n_q.csr_write<=sys_csr&&unused_csr_write_intent;n_q.csr_wdata<=unused_csr_wdata;n_q.csr_operand<=csr_operand;
        n_q.mret<=sys_mret;n_q.sret<=sys_sret;n_q.sfence<=sys_sfence;n_q.irq<=state_q==S_IRQ;n_q.serialize<=m_serial;
        n_q.branch<=state_q==S_EXEC&&branch_x&&!trap;n_q.kind<=branch_kind;n_q.target<=target;n_q.taken<=d_kind!=4||branch_taken;
        n_q.push<=hint_push;n_q.pop<=hint_pop;n_q.pred_hit<=m_q.pred_hit;n_q.pred_taken<=m_q.pred_taken;n_q.pred_next<=m_q.pred_next;
        n_q.redirect<=trap||m_serial||m_q.pred_next!=next_pc||
          (m_b_valid_q&&m_b_q.kind!=4&&m_b_q.pred_next!=m_b_q.pc+64'd4);
      end
      if(retirement_redirect) begin n_valid_q<=0;n_redirected_q<=0;end
    end
  end
  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin
      ret_order_q<='0;
      ret_pc_q<='0;
      ret_next_pc_q<='0;
      ret_insn_q<='0;
      ret_rd_q<='0;
      ret_rs1_q<='0;
      ret_rs2_q<='0;
      ret_wdata_q<='0;
      ret_rs1_data_q<='0;
      ret_rs2_data_q<='0;
      ret_trap_q<='0;
      ret_unsupported_q<='0;
      ret_cause_q<='0;
      ret_tval_q<='0;
      ret_privilege_q<='0;
      ret_write_q<='0;
      ret_csr_write_q<='0;
      ret_csr_wdata_q<='0;ret_csr_operand_q<='0;
      ret_mret_q<='0;
      ret_sret_q<='0;
      ret_sfence_q<='0;
      ret_irq_q<='0;
    end else if(n_to_c) begin
      ret_order_q<=order_q+(commit_fire ? 64'd1+64'(ret_b_valid_q) : 64'd0);
      ret_pc_q<=n_q.pc;
      ret_next_pc_q<=n_q.trap ? ((ENABLE_PRIV&&!memory_fatal_o)?trap_target:n_q.pc) : n_q.next_pc;
      ret_insn_q<=n_q.insn;ret_rd_q<=n_q.rd;ret_rs1_q<=n_q.rs1;ret_rs2_q<=n_q.rs2;
      ret_wdata_q<=n_q.wdata;ret_rs1_data_q<=n_q.rs1_data;ret_rs2_data_q<=n_q.rs2_data;
      ret_trap_q<=n_q.trap;ret_unsupported_q<=n_q.unsupported;ret_cause_q<=n_q.cause;ret_tval_q<=n_q.tval;
      ret_privilege_q<=n_q.privilege;ret_write_q<=n_q.write_rd;
      ret_csr_write_q<=n_q.csr_write;ret_csr_wdata_q<=n_q.csr_wdata;ret_csr_operand_q<=n_q.csr_operand;
      ret_mret_q<=n_q.mret;ret_sret_q<=n_q.sret;ret_sfence_q<=n_q.sfence;ret_irq_q<=n_q.irq;
    end
  end

  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin
      ret_valid_q<=0;ret_serialize_q<=0;ret_seq_q<=0;ret_epoch_q<=0;
      ret_branch_q<=0;ret_pred_hit_q<=0;ret_pred_taken_q<=0;ret_taken_q<=0;ret_push_q<=0;ret_pop_q<=0;
      ret_kind_q<=0;ret_target_q<=0;ret_pred_next_q<=0;
      branches_q<=0;pred_hits_q<=0;pred_taken_q<=0;mispredicts_q<=0;
      overlap_q<=0;prefetch_q<=0;issued_q<=0;killed_q<=0;forward_q<=0;raw_stall_q<=0;issue_q<=0;consecutive_q<=0;prev_issue_q<=0;
    end else begin
      if(commit_fire) ret_valid_q<=0;
      if(n_to_c) begin
        ret_valid_q<=1;ret_serialize_q<=n_q.serialize;ret_seq_q<=n_q.seq;ret_epoch_q<=n_q.epoch;
        ret_branch_q<=n_q.branch||(n_b_valid_q&&n_b_resolved.branch);
        ret_kind_q<=(n_b_valid_q&&n_b_resolved.branch)?n_b_resolved.kind:n_q.kind;
        ret_target_q<=(n_b_valid_q&&n_b_resolved.branch)?n_b_resolved.target:n_q.target;
        ret_taken_q<=(n_b_valid_q&&n_b_resolved.branch)?n_b_resolved.taken:n_q.taken;
        ret_push_q<=n_q.push;ret_pop_q<=n_q.pop;
        ret_pred_hit_q<=(n_b_valid_q&&n_b_resolved.branch)?n_b_resolved.pred_hit:n_q.pred_hit;
        ret_pred_taken_q<=(n_b_valid_q&&n_b_resolved.branch)?n_b_resolved.pred_taken:n_q.pred_taken;
        ret_pred_next_q<=(n_b_valid_q&&n_b_resolved.branch)?n_b_resolved.pred_next:n_q.pred_next;
      end
      if(commit_fire&&ret_branch_q&&!ret_trap_q) begin
        branches_q<=branches_q+1'b1;
        if(ret_pred_hit_q) pred_hits_q<=pred_hits_q+1'b1;
        if(ret_pred_taken_q) pred_taken_q<=pred_taken_q+1'b1;
        if(ret_pred_next_q!=((ret_b_valid_q&&ret_b_q.branch)?ret_b_q.next_pc:ret_next_pc_q)) mispredicts_q<=mispredicts_q+1'b1;
      end
      if(d1_valid_q&&(x_valid_q||m_valid_q||ret_valid_q)) overlap_q<=overlap_q+1'b1;
      if(ar_fire) prefetch_q<=prefetch_q+1'b1;
      if(f_to_d) issued_q<=issued_q+1'b1;
      if(flush_young) killed_q<=killed_q+64'(d0_valid_q)+64'(d1_valid_q)+64'(x_valid_q);
      if(d1_valid_q&&(x_dep||m_dep)) raw_stall_q<=raw_stall_q+1'b1;
      prev_issue_q<=issue_fire;
      if(issue_fire) begin
        issue_q<=issue_q+1'b1;if(prev_issue_q) consecutive_q<=consecutive_q+1'b1;
        if((d1_q.use1&&((m_forward&&m_q.rd==d1_q.rs1)||(n_forward&&n_q.rd==d1_q.rs1)||(ret_forward&&ret_rd_q==d1_q.rs1)))||
           (d1_q.use2&&((m_forward&&m_q.rd==d1_q.rs2)||(n_forward&&n_q.rd==d1_q.rs2)||(ret_forward&&ret_rd_q==d1_q.rs2)))) forward_q<=forward_q+1'b1;
      end
    end
  end
  assign commit_second_valid_o=commit_valid_o&&ret_b_valid_q;
  assign commit_second_order_o=ret_order_q+64'd1;
  assign commit_second_pc_o=ret_b_q.pc;assign commit_second_next_pc_o=ret_b_q.next_pc;
  assign commit_second_insn_o=ret_b_q.insn;assign commit_second_rd_o=ret_b_q.rd;
  assign commit_second_rs1_o=ret_b_q.rs1;assign commit_second_rs2_o=ret_b_q.rs2;
  assign commit_second_wdata_o=ret_b_q.wdata;
  assign commit_second_rs1_data_o=ret_b_q.rs1_data;assign commit_second_rs2_data_o=ret_b_q.rs2_data;
  assign commit_second_privilege_o=ret_b_q.privilege;
  assign stat_dual_issue_o=dual_issue_q;assign stat_dual_retire_o=dual_retire_q;
  assign backend_second_valid_o={ret_b_valid_q,n_b_valid_q,m_b_valid_q,x_b_valid_q,d1_b_valid_q,d0_b_valid_q};
  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i)begin
      n_b_q<='0;n_b_valid_q<=0;ret_b_q<='0;ret_b_valid_q<=0;dual_issue_q<=0;dual_retire_q<=0;n_b_forward1_q<=0;n_b_forward2_q<=0;
    end else begin
      if(issue_second_fire)dual_issue_q<=dual_issue_q+64'd1;
      if(commit_second_fire)dual_retire_q<=dual_retire_q+64'd1;
      if(n_to_c)n_b_valid_q<=0;
      if(execute_complete||state_q==S_IRQ)begin
        n_b_valid_q<=m_b_valid_q&&!trap&&state_q==S_EXEC&&!(d_kind==4&&branch_taken);
        n_b_q<='0;n_b_q.pc<=m_b_q.pc;n_b_q.next_pc<=m_b_q.pc+64'd4;
        n_b_forward1_q<=m_b_q.kind==4&&gpr_write&&!trap&&gpr_rd!=0&&gpr_rd==m_b_q.rs1;
        n_b_forward2_q<=m_b_q.kind==4&&gpr_write&&!trap&&gpr_rd!=0&&gpr_rd==m_b_q.rs2;
        n_b_q.seq<=m_b_q.seq;n_b_q.epoch<=m_b_q.epoch;n_b_q.insn<=m_b_q.raw_insn;
        n_b_q.rd<=m_b_q.write_rd?m_b_q.rd:5'b0;n_b_q.write_rd<=m_b_q.write_rd;
        n_b_q.rs1<=m_b_q.rs1;n_b_q.rs2<=m_b_q.rs2;n_b_q.wdata<=m_b_q.write_rd?m_b_alu_q:64'b0;
        n_b_q.rs1_data<=m_b_q.use1?m_b_q.r1:64'b0;n_b_q.rs2_data<=m_b_q.use2?m_b_q.r2:64'b0;
        n_b_q.privilege<=privilege;
        n_b_q.branch<=m_b_q.kind==4;n_b_q.kind<=0;n_b_q.target<=m_b_alu_q;
        n_b_q.pred_next<=m_b_q.pred_next;n_b_q.pred_hit<=m_b_q.pred_hit;n_b_q.pred_taken<=m_b_q.pred_taken;
      end
      if(retirement_redirect)n_b_valid_q<=0;
      if(commit_fire)ret_b_valid_q<=0;
      if(n_to_c)begin ret_b_q<=n_b_resolved;ret_b_valid_q<=n_b_valid_q;end
    end
  end
  assign backend_valid_o={ret_valid_q,n_valid_q,m_valid_q,x_valid_q,d1_valid_q,d0_valid_q};
  assign resolve_pc_o=n_q.pc;assign resolve_seq_o=n_q.seq;
  assign decode_pc_o=d0_q.pc;assign issue_pc_o=d1_q.pc;assign alu_pc_o=x_q.pc;
  assign decode_seq_o=d0_q.seq;assign issue_seq_o=d1_q.seq;assign alu_seq_o=x_q.seq;
  assign frontend_valid_o={f3_count_q!=0,(f2_valid_q&&!f2_killed_q),(f1_valid_q&&!f1_killed_q),f0_valid_q};
  assign f0_seq_o=f0_q.seq;assign f1_seq_o=f1_q.seq;assign f2_seq_o=f2_q.seq;assign f3_seq_o=f_q.seq;
  assign fetch_outstanding_o=request_count_q;
  assign stage_valid_o={ret_valid_q,m_valid_q,(|frontend_valid_o)||request_count_q!=0};
  assign fetch_pc_o=debug_fetch.pc;assign execute_pc_o=m_q.pc;assign retire_pc_o=ret_pc_q;
  assign fetch_seq_o=debug_fetch.seq;assign execute_seq_o=m_q.seq;assign retire_seq_o=ret_seq_q;
  assign epoch_o=epoch_q;assign execute_epoch_o=m_q.epoch;assign retire_epoch_o=ret_epoch_q;
  assign stat_overlap_o=overlap_q;assign stat_prefetch_o=prefetch_q;assign stat_issue_prefetched_o=issued_q;
  assign stat_killed_o=killed_q;assign stat_forward_o=forward_q;
  assign stat_raw_stall_o=raw_stall_q;assign stat_issue_o=issue_q;assign stat_consecutive_issue_o=consecutive_q;
  assign stat_branch_o=branches_q;assign stat_prediction_hit_o=pred_hits_q;
  assign stat_prediction_taken_o=pred_taken_q;assign stat_mispredict_o=mispredicts_q;
  logic [63:0] execute_retire_cycles_q,execute_retire_fire_q;
  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin execute_retire_cycles_q<=0;execute_retire_fire_q<=0;end
    else begin
      if(m_valid_q&&ret_valid_q) execute_retire_cycles_q<=execute_retire_cycles_q+1'b1;
      if(execute_complete&&commit_fire) execute_retire_fire_q<=execute_retire_fire_q+1'b1;
    end
  end
  assign stat_execute_retire_o=execute_retire_cycles_q;assign stat_execute_retire_fire_o=execute_retire_fire_q;
  generate if(ENABLE_BP&&!ENABLE_C) begin: prediction
    rv64_branch_predictor predictor (
      .clk_i(clk_i),.aresetn_i(aresetn_i),.context_i({satp_value,privilege}),.flush_i(bp_flush),
      .lookup_valid_i(f0_allocate),.lookup_pc_i(front_pc_q),
      .ready_o(bp_ready),.hit_o(bp_hit),.taken_o(bp_taken),.ras_used_o(bp_ras_used),.kind_o(bp_kind),.next_pc_o(bp_next),
      .train_valid_i(bp_train),.train_pc_i((ret_b_valid_q&&ret_b_q.branch)?ret_b_q.pc:ret_pc_q),.train_target_i(ret_target_q),.train_kind_i(ret_kind_q),
      .train_taken_i(ret_taken_q),.train_push_i(ret_push_q),.train_pop_i(ret_pop_q),.train_link_i(ret_pc_q+64'd4)
    );
    rv64_branch_predictor second_predictor (
      .clk_i(clk_i),.aresetn_i(aresetn_i),.context_i({satp_value,privilege}),.flush_i(bp_flush),
      .lookup_valid_i(f0_allocate),.lookup_pc_i(front_pc_q+64'd4),
      .ready_o(bp_b_ready),.hit_o(bp_b_hit),.taken_o(bp_b_taken),.ras_used_o(bp_b_ras_used),.kind_o(bp_b_kind),.next_pc_o(bp_b_next),
      .train_valid_i(bp_train),.train_pc_i((ret_b_valid_q&&ret_b_q.branch)?ret_b_q.pc:ret_pc_q),.train_target_i(ret_target_q),.train_kind_i(ret_kind_q),
      .train_taken_i(ret_taken_q),.train_push_i(ret_push_q),.train_pop_i(ret_pop_q),.train_link_i(ret_pc_q+64'd4)
    );
  end else begin: no_prediction
    wire unused_training_inputs=^{ret_taken_q,ret_push_q,ret_pop_q,ret_kind_q,ret_target_q,bp_train,bp_flush};
    assign bp_ready=0;assign bp_hit=0;assign bp_taken=0;assign bp_ras_used=0;assign bp_kind=0;assign bp_next=front_pc_q+64'd4;
    assign bp_b_ready=0;assign bp_b_hit=0;assign bp_b_taken=0;assign bp_b_ras_used=0;assign bp_b_kind=0;assign bp_b_next=front_pc_q+64'd8;
  end endgenerate


`ifdef RV64_DUAL_CORE_FORMAL
  `include "formal/rv64/r63_calign_core_properties.svh"
`endif
endmodule
