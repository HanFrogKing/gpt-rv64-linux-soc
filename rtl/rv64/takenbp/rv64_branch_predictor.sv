`timescale 1ns/1ps
// R35 candidate: allocate BTB on actual taken control flow; train conditional BHT on both outcomes.
module rv64_branch_predictor #(
  parameter integer BTB_ENTRIES=128,
  parameter integer BHT_ENTRIES=512,
  parameter integer RAS_DEPTH=8
)(
  input logic clk_i, aresetn_i,
  input logic [65:0] context_i, // {satp, current_privilege}; caller also flushes FENCE.I/SFENCE
  input logic flush_i,
  input logic lookup_valid_i,
  input logic [63:0] lookup_pc_i,
  output logic ready_o, hit_o, taken_o, ras_used_o,
  output logic [1:0] kind_o,
  output logic [63:0] next_pc_o,
  input logic train_valid_i, // must be a non-trapping committed control-flow instruction
  input logic [63:0] train_pc_i, train_target_i,
  input logic [1:0] train_kind_i, // conditional, direct/indirect jump, call, return
  input logic train_taken_i, train_push_i, train_pop_i,
  input logic [63:0] train_link_i
);
  localparam integer BI=$clog2(BTB_ENTRIES), HI=$clog2(BHT_ENTRIES), RI=$clog2(RAS_DEPTH);
  logic context_valid_q;
  logic [65:0] context_q;
  logic [BTB_ENTRIES-1:0] btb_valid_q;
  logic [BHT_ENTRIES-1:0] bht_valid_q;
  logic [63:0] btb_pc_q [BTB_ENTRIES];
  logic [63:0] btb_target_q [BTB_ENTRIES];
  logic [1:0] btb_kind_q [BTB_ENTRIES];
  logic [1:0] bht_q [BHT_ENTRIES];
  logic [63:0] ras_q [RAS_DEPTH];
  logic [RI-1:0] ras_write_q;
  logic [RI:0] ras_count_q;
  wire [BI-1:0] lookup_bi=lookup_pc_i[BI+1:2], train_bi=train_pc_i[BI+1:2];
  wire [HI-1:0] lookup_hi=lookup_pc_i[HI+1:2], train_hi=train_pc_i[HI+1:2];
  wire [RI-1:0] ras_top=ras_write_q-1'b1;
  wire [1:0] train_old=bht_valid_q[train_hi] ? bht_q[train_hi] : 2'b01;
  wire context_match=context_valid_q && context_q==context_i;
  wire train_fire=aresetn_i && context_match && !flush_i && train_valid_i &&
    train_pc_i[1:0]==0 && train_target_i[1:0]==0 &&
    (!train_push_i || train_link_i[1:0]==0);
  wire train_allocate=train_fire && (train_kind_i!=0 || train_taken_i);
  always_comb begin
    ready_o=aresetn_i && context_match && !flush_i;
    hit_o=ready_o && lookup_valid_i && lookup_pc_i[1:0]==0 &&
      btb_valid_q[lookup_bi] && btb_pc_q[lookup_bi]==lookup_pc_i;
    kind_o=hit_o ? btb_kind_q[lookup_bi] : 2'b0;
    taken_o=hit_o && (kind_o!=0 || (bht_valid_q[lookup_hi] && bht_q[lookup_hi][1]));
    ras_used_o=taken_o && kind_o==3 && ras_count_q!=0;
    next_pc_o=lookup_pc_i+64'd4;
    if(taken_o) next_pc_o=ras_used_o ? ras_q[ras_top] : btb_target_q[lookup_bi];
  end
  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin
      context_valid_q<=0;context_q<=0;btb_valid_q<='0;bht_valid_q<='0;
      ras_write_q<=0;ras_count_q<=0;
    end else if(flush_i || !context_match) begin
      context_valid_q<=1;context_q<=context_i;btb_valid_q<='0;bht_valid_q<='0;
      ras_write_q<=0;ras_count_q<=0;
    end else if(train_fire) begin
      if(train_allocate) btb_valid_q[train_bi]<=1;
      if(train_kind_i==0) bht_valid_q[train_hi]<=1;
      if(train_push_i && train_pop_i && ras_count_q!=0) begin end
      else if(train_push_i) begin
        ras_write_q<=ras_write_q+1'b1;
        if(ras_count_q<(RI+1)'(RAS_DEPTH)) ras_count_q<=ras_count_q+1'b1;
      end else if(train_pop_i && ras_count_q!=0) begin
        ras_write_q<=ras_write_q-1'b1;ras_count_q<=ras_count_q-1'b1;
      end
    end
  end
  // Data arrays have a synchronous write process without reset. Valid bits above
  // mask stale contents; this permits generic FPGA distributed-RAM inference.
  always_ff @(posedge clk_i) begin
    if(train_fire) begin
      if(train_allocate) begin
      btb_pc_q[train_bi]<=train_pc_i;btb_target_q[train_bi]<=train_target_i;btb_kind_q[train_bi]<=train_kind_i;
      end
      if(train_kind_i==0) begin
        if(train_taken_i) bht_q[train_hi]<=train_old==3 ? 2'b11 : train_old+2'b01;
        else bht_q[train_hi]<=train_old==0 ? 2'b00 : train_old-2'b01;
      end
      if(train_push_i && train_pop_i && ras_count_q!=0) ras_q[ras_top]<=train_link_i;
      else if(train_push_i) ras_q[ras_write_q]<=train_link_i;
    end
  end
`ifdef RV64_PREDICTOR_FORMAL
`include "formal/rv64/taken_branch_predictor_properties.svh"
`endif
endmodule
