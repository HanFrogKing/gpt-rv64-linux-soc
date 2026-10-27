// R11 candidate: serial Sv39 translator and shared fully-associative TLB.
// All VA/mode/permission inputs are captured once. Physical PTE accesses use
// the R10 exclusive-capable LSU; page-table memory must provide RsrvEventual.
// No implicit address translation is delegated to the simulation host.
module rv64_mmu #(
  parameter integer TLB_ENTRIES=8
) (
  input logic clk_i, aresetn_i, flush_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input logic [63:0] req_vaddr_i, req_satp_i,
  input logic [1:0] req_access_i, req_priv_i, // 0=IF, 1=load/LR, 2/3=store/SC/AMO.
  input logic req_sum_i, req_mxr_i, req_adue_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output logic [63:0] rsp_paddr_o, rsp_cause_o, rsp_tval_o,
  output logic rsp_error_o, rsp_hit_o,
  output logic bus_valid_o,
  input logic bus_ready_i,
  output logic bus_write_o, bus_exclusive_o,
  output logic [1:0] bus_size_o,
  output logic [63:0] bus_addr_o, bus_data_o,
  input logic bus_rsp_valid_i,
  output logic bus_rsp_ready_o,
  input logic [63:0] bus_rsp_data_i,
  input logic bus_rsp_error_i, bus_rsp_exokay_i
);
  localparam integer INDEX_BITS=TLB_ENTRIES<=1 ? 1 : $clog2(TLB_ENTRIES);
  localparam logic [2:0] IDLE=0, LOOKUP=1, RD_REQ=2, RD_WAIT=3, EVAL=4, WR_REQ=5, WR_WAIT=6, RESP=7;
  logic [2:0] state_q;
  logic [63:0] va_q, pte_addr_q, pte_q, resolved_pa_q;
  logic [3:0] satp_mode_q;
  logic [43:0] satp_root_q;
  wire unused_asid=^req_satp_i[59:44]; // ASIDLEN=0; full architectural fences.
  logic [1:0] access_q, priv_q, level_q;
  logic sum_q, mxr_q, adue_q, fill_kill_q;
  logic [4:0] updated_flags_q;
  logic [63:0] paddr_q, cause_q;
  logic error_q, hit_q;
  logic valid_q [TLB_ENTRIES];
  logic [26:0] vpn_q [TLB_ENTRIES];
  logic [43:0] root_q [TLB_ENTRIES], ppn_q [TLB_ENTRIES];
  logic [4:0] flags_q [TLB_ENTRIES]; // D,U,X,W,R; valid entries already have A=V=1.
  logic [INDEX_BITS-1:0] replace_q, hit_index;
  logic hit_found, permission, leaf, invalid_pte, needs_ad;
  logic [43:0] leaf_ppn;
  logic [63:0] leaf_pa, updated_pte;
  integer lookup_index, reset_index, fill_index;
  wire req_fire=req_valid_i && req_ready_o;
  wire bus_fire=bus_valid_o && bus_ready_i;
  wire bus_rsp_fire=bus_rsp_valid_i && bus_rsp_ready_o;
  wire is_store=access_q[1];
  wire [63:0] page_cause=access_q==0 ? 64'd12 : access_q==1 ? 64'd13 : 64'd15;
  wire [63:0] access_cause=access_q==0 ? 64'd1 : access_q==1 ? 64'd5 : 64'd7;
  wire [63:0] root_entry={8'b0,satp_root_q,12'b0}+{52'b0,va_q[38:30],3'b0};
  function automatic logic allowed(input logic [3:0] flags,input logic [1:0] privilege,
      input logic [1:0] access_kind,input logic sum,input logic mxr);
    logic mode_ok, type_ok;
    begin
      mode_ok=privilege==0 ? flags[3] : privilege==1 ? (!flags[3] || (sum && access_kind!=0)) : 1'b0;
      type_ok=access_kind==0 ? flags[2] : access_kind==1 ? (flags[0] || (mxr && flags[2])) : flags[1];
      allowed=mode_ok && type_ok;
    end
  endfunction
  always_comb begin
    hit_found=0;hit_index=0;
    for(lookup_index=0;lookup_index<TLB_ENTRIES;lookup_index=lookup_index+1)
      if(!hit_found && valid_q[lookup_index] && vpn_q[lookup_index]==va_q[38:12] && root_q[lookup_index]==satp_root_q) begin
        hit_found=1;hit_index=INDEX_BITS'(lookup_index);
      end
    leaf=pte_q[1] || pte_q[3];
    invalid_pte=!pte_q[0] || (!pte_q[1] && pte_q[2]) || |pte_q[63:54] ||
      (!leaf && (pte_q[4] || pte_q[6] || pte_q[7]));
    permission=allowed(pte_q[4:1],priv_q,access_q,sum_q,mxr_q);
    leaf_ppn=pte_q[53:10];
    if(level_q==2) leaf_ppn[17:0]=va_q[29:12];
    else if(level_q==1) leaf_ppn[8:0]=va_q[20:12];
    leaf_pa={8'b0,leaf_ppn,va_q[11:0]};
    needs_ad=!pte_q[6] || (is_store && !pte_q[7]);
    updated_pte=pte_q | 64'h40 | (is_store ? 64'h80 : 64'b0);
  end
  wire bad_superpage=(level_q==2 && |pte_q[27:10]) || (level_q==1 && |pte_q[18:10]);
  wire evaluated_leaf_ok=!invalid_pte && leaf && !bad_superpage && permission;
  wire install=aresetn_i && !flush_i && !fill_kill_q &&
    ((state_q==EVAL && evaluated_leaf_ok && !needs_ad) ||
     (state_q==WR_WAIT && bus_rsp_fire && !bus_rsp_error_i && bus_rsp_exokay_i));
  wire [43:0] install_ppn=state_q==WR_WAIT ? resolved_pa_q[55:12] : leaf_pa[55:12];
  wire [4:0] install_flags=state_q==WR_WAIT ? updated_flags_q : {pte_q[7],pte_q[4:1]};
  assign req_ready_o=aresetn_i && state_q==IDLE && !flush_i;
  assign rsp_valid_o=aresetn_i && state_q==RESP;
  assign rsp_paddr_o=paddr_q;
  assign rsp_error_o=error_q;
  assign rsp_cause_o=cause_q;
  assign rsp_tval_o=error_q ? va_q : 64'b0;
  assign rsp_hit_o=hit_q;
  assign bus_valid_o=aresetn_i && (state_q==RD_REQ || state_q==WR_REQ);
  assign bus_rsp_ready_o=aresetn_i && (state_q==RD_WAIT || state_q==WR_WAIT);
  assign bus_write_o=state_q==WR_REQ || state_q==WR_WAIT;
  assign bus_exclusive_o=1;
  assign bus_size_o=3;
  assign bus_addr_o=pte_addr_q;
  assign bus_data_o=updated_pte;
  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin
      state_q<=IDLE;va_q<=0;satp_mode_q<=0;satp_root_q<=0;pte_addr_q<=0;pte_q<=0;resolved_pa_q<=0;
      access_q<=0;priv_q<=3;level_q<=2;sum_q<=0;mxr_q<=0;adue_q<=0;fill_kill_q<=0;updated_flags_q<=0;
      paddr_q<=0;cause_q<=0;error_q<=0;hit_q<=0;replace_q<=0;
      for(reset_index=0;reset_index<TLB_ENTRIES;reset_index=reset_index+1) begin
        valid_q[reset_index]<=0;vpn_q[reset_index]<=0;root_q[reset_index]<=0;
        ppn_q[reset_index]<=0;flags_q[reset_index]<=0;
      end
    end else begin
      case(state_q)
        IDLE: if(req_fire) begin
          va_q<=req_vaddr_i;satp_mode_q<=req_satp_i[63:60];satp_root_q<=req_satp_i[43:0];access_q<=req_access_i;priv_q<=req_priv_i;
          sum_q<=req_sum_i;mxr_q<=req_mxr_i;adue_q<=req_adue_i;fill_kill_q<=0;
          paddr_q<=0;cause_q<=0;error_q<=0;hit_q<=0;state_q<=LOOKUP;
        end
        LOOKUP: begin
          if(priv_q==3 || satp_mode_q==0) begin paddr_q<=va_q;state_q<=RESP;end
          else if(satp_mode_q!=8 || priv_q==2 || va_q[63:39]!={25{va_q[38]}}) begin
            error_q<=1;cause_q<=page_cause;state_q<=RESP;
          end else if(hit_found && !allowed(flags_q[hit_index][3:0],priv_q,access_q,sum_q,mxr_q)) begin
            error_q<=1;cause_q<=page_cause;state_q<=RESP;
          end else if(hit_found && (!is_store || flags_q[hit_index][4])) begin
            paddr_q<={8'b0,ppn_q[hit_index],va_q[11:0]};hit_q<=1;state_q<=RESP;
          end else if(hit_found && !adue_q) begin
            error_q<=1;cause_q<=page_cause;state_q<=RESP;
          end else begin level_q<=2;pte_addr_q<=root_entry;state_q<=RD_REQ;end
        end
        RD_REQ: if(bus_fire) state_q<=RD_WAIT;
        RD_WAIT: if(bus_rsp_fire) begin
          if(bus_rsp_error_i || !bus_rsp_exokay_i) begin error_q<=1;cause_q<=access_cause;state_q<=RESP;end
          else begin pte_q<=bus_rsp_data_i;state_q<=EVAL;end
        end
        EVAL: begin
          if(invalid_pte) begin error_q<=1;cause_q<=page_cause;state_q<=RESP;end
          else if(!leaf) begin
            if(level_q==0) begin error_q<=1;cause_q<=page_cause;state_q<=RESP;end
            else begin
              level_q<=level_q-1'b1;
              pte_addr_q<={8'b0,pte_q[53:10],12'b0}+
                {52'b0,(level_q==2 ? va_q[29:21] : va_q[20:12]),3'b0};
              state_q<=RD_REQ;
            end
          end else if(bad_superpage || !permission) begin error_q<=1;cause_q<=page_cause;state_q<=RESP;end
          else if(needs_ad && !adue_q) begin error_q<=1;cause_q<=page_cause;state_q<=RESP;end
          else if(needs_ad) begin resolved_pa_q<=leaf_pa;updated_flags_q<={updated_pte[7],updated_pte[4:1]};state_q<=WR_REQ;end
          else begin paddr_q<=leaf_pa;state_q<=RESP;end
        end
        WR_REQ: if(bus_fire) state_q<=WR_WAIT;
        WR_WAIT: if(bus_rsp_fire) begin
          if(bus_rsp_error_i) begin error_q<=1;cause_q<=access_cause;state_q<=RESP;end
          else if(bus_rsp_exokay_i) begin paddr_q<=resolved_pa_q;state_q<=RESP;end
          else begin level_q<=2;pte_addr_q<=root_entry;state_q<=RD_REQ;end
        end
        RESP: if(rsp_ready_i) state_q<=IDLE;
        default: state_q<=IDLE;
      endcase
      if(install) begin
        for(fill_index=0;fill_index<TLB_ENTRIES;fill_index=fill_index+1)
          if(valid_q[fill_index] && vpn_q[fill_index]==va_q[38:12] && root_q[fill_index]==satp_root_q) valid_q[fill_index]<=0;
        valid_q[replace_q]<=1;vpn_q[replace_q]<=va_q[38:12];root_q[replace_q]<=satp_root_q;
        ppn_q[replace_q]<=install_ppn;flags_q[replace_q]<=install_flags;
        replace_q<=replace_q==INDEX_BITS'(TLB_ENTRIES-1) ? {INDEX_BITS{1'b0}} : replace_q+1'b1;
      end
      if(flush_i) begin
        for(reset_index=0;reset_index<TLB_ENTRIES;reset_index=reset_index+1) valid_q[reset_index]<=0;
        replace_q<=0;
        if(state_q!=IDLE) fill_kill_q<=1;
      end
    end
  end
`ifdef RV64_MMU_FORMAL
  `include "formal/rv64/mmu/properties.svh"
`endif
endmodule
