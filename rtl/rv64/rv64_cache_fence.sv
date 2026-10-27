// Retirement barrier for the serial core and a drained in-order memory stream.
// The producer holds the complete commit packet while ready is low. Cache done
// stays asserted until ack; both caches share this controller's common reset.
// D clean remains unacknowledged through I invalidation and commit backpressure.
module rv64_cache_fence #(parameter bit ENABLE_D=1, ENABLE_I=1) (
  input logic clk_i, aresetn_i, fatal_i,
  input logic core_valid_i,
  output logic core_ready_o,
  input logic [31:0] core_insn_i,
  input logic core_trap_i, core_unsupported_i,
  output logic commit_valid_o,
  input logic commit_ready_i,
  output logic clean_valid_o,
  input logic clean_ready_i, clean_done_i,
  output logic clean_ack_o,
  output logic inv_valid_o,
  input logic inv_ready_i, inv_done_i,
  output logic inv_ack_o,
  output logic [31:0] stat_start_o, stat_clean_o, stat_inv_o, stat_complete_o
);
  localparam logic [2:0] IDLE=0, REQUEST_D=1, WAIT_D=2,
    REQUEST_I=3, WAIT_I=4, FINISH=5;
  logic [2:0] state_q;
  logic need_clean_q, need_inv_q;
  wire legal=core_valid_i && !core_trap_i && !core_unsupported_i &&
    core_insn_i[6:0]==7'h0f;
  // FENCE and FENCE.I ignore the otherwise unused imm/rs1/rd fields.
  wire want_clean=ENABLE_D && legal &&
    (core_insn_i[14:12]==3'b000 || core_insn_i[14:12]==3'b001);
  wire want_inv=ENABLE_I && legal && core_insn_i[14:12]==3'b001;
  wire unused_fields=^{core_insn_i[31:15],core_insn_i[11:7]};
  wire maintenance=want_clean || want_inv;
  wire d_complete=!need_clean_q || clean_done_i;
  wire i_complete=!need_inv_q || inv_done_i;
  wire allow_commit=(state_q==IDLE && !maintenance) ||
    (state_q==FINISH && d_complete && i_complete);
  wire enabled=aresetn_i && !fatal_i;
  wire commit_fire=commit_valid_o && commit_ready_i;
  wire clean_fire=clean_valid_o && clean_ready_i;
  wire inv_fire=inv_valid_o && inv_ready_i;
  assign core_ready_o=enabled && allow_commit && commit_ready_i;
  assign commit_valid_o=enabled && allow_commit && core_valid_i;
  assign clean_valid_o=enabled && state_q==REQUEST_D;
  assign inv_valid_o=enabled && state_q==REQUEST_I && d_complete;
  assign clean_ack_o=enabled && state_q==FINISH && need_clean_q && commit_fire;
  assign inv_ack_o=enabled && state_q==FINISH && need_inv_q && commit_fire;
  always_ff @(posedge clk_i) begin
    if(!aresetn_i) begin
      state_q<=IDLE;need_clean_q<=0;need_inv_q<=0;
      stat_start_o<=0;stat_clean_o<=0;stat_inv_o<=0;stat_complete_o<=0;
    end else if(!fatal_i) case(state_q)
      IDLE: if(maintenance) begin
        need_clean_q<=want_clean;need_inv_q<=want_inv;
        state_q<=want_clean ? REQUEST_D : REQUEST_I;
        stat_start_o<=stat_start_o+1'b1;
      end
      REQUEST_D: if(clean_fire) begin state_q<=WAIT_D;stat_clean_o<=stat_clean_o+1'b1;end
      WAIT_D: if(clean_done_i) state_q<=need_inv_q ? REQUEST_I : FINISH;
      REQUEST_I: if(inv_fire) begin state_q<=WAIT_I;stat_inv_o<=stat_inv_o+1'b1;end
      WAIT_I: if(inv_done_i && d_complete) state_q<=FINISH;
      FINISH: if(commit_fire) begin
        state_q<=IDLE;need_clean_q<=0;need_inv_q<=0;
        stat_complete_o<=stat_complete_o+1'b1;
      end
      default: state_q<=IDLE;
    endcase
  end
`ifdef RV64_CACHE_FENCE_FORMAL
  `include "formal/rv64/cache_fence_properties.svh"
`endif
endmodule
