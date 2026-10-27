// R89 standalone SEIP candidate. Raw CSR operation/operand are commit inputs.
// wdata_i remains the final write value for every CSR except mip (0x344).
// R62 candidate: static optional C capability, IALIGN=16 EPC semantics.
// R30: two independent committed-retirement pulses; count their population.
// Explicit counter writes win; inhibit uses its old value. Trap/return do not
// discard older committed retirements. The caller excludes faulting instructions.
// R08/R09: commit-driven M/S/U CSR, synchronous trap and interrupt state.
// CSR read is a query. All explicit writes/traps/returns happen at commit.
// ENABLE_SU=0 preserves the verified R08 machine-only contract. PMP is absent.
module rv64_dual_csr #(
  parameter bit ENABLE_C=0,
  parameter bit ENABLE_SU=0,
  parameter bit ENABLE_A=0,
  parameter bit HAS_MMU=0
) (
  input logic clk_i, aresetn_i,
  input logic [11:0] addr_i,
  input logic write_intent_i,
  output logic [63:0] rdata_o,
  output logic illegal_o,
  input logic csr_commit_i,
  input logic [63:0] wdata_i,
  input logic [1:0] csr_op_i, // 1=write, 2=set, 3=clear; only used for mip
  input logic [63:0] csr_operand_i,
  input logic trap_i, mret_i, retire_i, retire_second_i,
  input logic sret_i, return_s_i,
  input logic irq_msip_i, irq_mtip_i, irq_meip_i, irq_seip_i,
  input logic [63:0] time_i,
  input logic [63:0] trap_pc_i, trap_cause_i, trap_tval_i,
  output logic [63:0] trap_target_o, return_pc_o,
  output logic [63:0] status_o,
  output logic [1:0] privilege_o, data_privilege_o,
  output logic mret_illegal_o, sret_illegal_o,
  output logic irq_pending_o,
  output logic [63:0] irq_cause_o, satp_o,
  output logic adue_o
);
  localparam logic [63:0] MISA=64'h8000000000001100 | (ENABLE_SU ? 64'h140000 : 64'b0) | (ENABLE_A ? 64'd1 : 64'b0) | (ENABLE_C ? 64'd4 : 64'b0);
  localparam logic [63:0] IRQ_MASK=64'haaa, DELEG_IRQ_MASK=64'h222, DELEG_EXC_MASK=64'hb3ff;
  localparam logic [63:0] SSTATUS_MASK=64'h2000c0122;
  logic [63:0] mtvec_q, mscratch_q, mepc_q, mcause_q, mtval_q;
  logic [63:0] stvec_q, sscratch_q, sepc_q, scause_q, stval_q, satp_q;
  logic [63:0] medeleg_q, mideleg_q, mie_irq_q, mip_sw_q;
  logic [2:0] mcounteren_q, scounteren_q;
  logic [1:0] priv_q, mpp_q;
  logic sie_q, spie_q, spp_q, mprv_q, sum_q, mxr_q, tvm_q, tw_q, tsr_q;
  logic [63:0] mcycle_q, minstret_q;
  logic mie_q, mpie_q;
  logic [2:0] inhibit_q;
  logic exists;
  logic adue_q, mfiom_q, sfiom_q;
  wire unused_trap_alignment=trap_pc_i[0] ^ (!ENABLE_C && trap_pc_i[1]);
  wire unused_optional_inputs=^{sret_i,irq_msip_i,irq_mtip_i,irq_meip_i,irq_seip_i,time_i,csr_op_i,csr_operand_i};
  wire [63:0] pending=ENABLE_SU ? mip_sw_q | (64'(irq_msip_i)<<3) |
    (64'(irq_mtip_i)<<7) | (64'(irq_meip_i)<<11) | (64'(irq_seip_i)<<9) : 64'b0;
  logic [63:0] mip_write;
  always_comb begin
    case(csr_op_i)
      2'd1: mip_write=csr_operand_i;
      2'd2: mip_write=mip_sw_q | csr_operand_i;
      2'd3: mip_write=mip_sw_q & ~csr_operand_i;
      default: mip_write=mip_sw_q;
    endcase
  end
  wire delegated=ENABLE_SU && priv_q!=3 && trap_cause_i[62:6]==0 &&
    ((trap_cause_i[63] ? mideleg_q : medeleg_q) & (64'd1<<trap_cause_i[5:0]))!=0;
  wire [63:0] selected_vec=delegated ? stvec_q : mtvec_q;
  logic [63:0] machine_pending, supervisor_pending, selected_pending;
  logic [5:0] irq_number;
  assign privilege_o=ENABLE_SU ? priv_q : 2'd3;
  assign data_privilege_o=ENABLE_SU ? ((priv_q==3 && mprv_q) ? mpp_q : priv_q) : 2'd3;
  assign satp_o=satp_q;
  assign adue_o=HAS_MMU && adue_q;
  assign mret_illegal_o=ENABLE_SU && priv_q!=3;
  assign sret_illegal_o=!ENABLE_SU || priv_q==0 || (priv_q==1 && tsr_q);
  assign status_o=(ENABLE_SU ? 64'ha00000000 | (64'(mpp_q)<<11) |
    (64'(sie_q)<<1) | (64'(spie_q)<<5) | (64'(spp_q)<<8) |
    (64'(mprv_q)<<17) | (64'(sum_q)<<18) | (64'(mxr_q)<<19) |
    (64'(tvm_q)<<20) | (64'(tw_q)<<21) | (64'(tsr_q)<<22) : 64'h1800) |
    (64'(mie_q)<<3) | (64'(mpie_q)<<7);
  assign trap_target_o={selected_vec[63:2],2'b00}+
    ((trap_cause_i[63] && selected_vec[1:0]==1) ? ({1'b0,trap_cause_i[62:0]}<<2) : 64'b0);
  assign return_pc_o=return_s_i ? sepc_q : mepc_q;
  always_comb begin
    machine_pending=(pending & mie_irq_q & ~mideleg_q) & {64{priv_q!=3 || mie_q}};
    supervisor_pending=(pending & mie_irq_q & mideleg_q) & {64{priv_q==0 || (priv_q==1 && sie_q)}};
    selected_pending=machine_pending!=0 ? machine_pending : supervisor_pending;
    irq_number=0;
    if(selected_pending[11]) irq_number=11;
    else if(selected_pending[3]) irq_number=3;
    else if(selected_pending[7]) irq_number=7;
    else if(selected_pending[9]) irq_number=9;
    else if(selected_pending[1]) irq_number=1;
    else if(selected_pending[5]) irq_number=5;
    irq_pending_o=ENABLE_SU && selected_pending!=0;
    irq_cause_o=64'h8000000000000000 | {58'b0,irq_number};
  end
  always_comb begin
    rdata_o=0;exists=1;
    case(addr_i)
      12'h300: rdata_o=status_o;
      12'h301: rdata_o=MISA;
      12'h302: begin exists=ENABLE_SU;rdata_o=medeleg_q;end
      12'h303: begin exists=ENABLE_SU;rdata_o=mideleg_q;end
      12'h304: rdata_o=mie_irq_q;
      12'h306: rdata_o={61'b0,mcounteren_q};
      12'h30a: begin exists=HAS_MMU;rdata_o={2'b0,adue_o,60'b0,mfiom_q};end
      12'h10a: begin exists=ENABLE_SU && HAS_MMU;rdata_o={63'b0,sfiom_q};end
      12'h344: rdata_o=pending;
      12'h305: rdata_o=mtvec_q;
      12'h320: rdata_o={61'b0,inhibit_q};
      12'h340: rdata_o=mscratch_q;
      12'h341: rdata_o=mepc_q;
      12'h342: rdata_o=mcause_q;
      12'h343: rdata_o=mtval_q;
      12'hb00,12'hc00: rdata_o=mcycle_q;
      12'hb02,12'hc02: rdata_o=minstret_q;
      12'hc01: begin exists=ENABLE_SU;rdata_o=ENABLE_SU ? time_i : 64'b0;end
      12'h100: begin exists=ENABLE_SU;rdata_o=status_o&SSTATUS_MASK;end
      12'h104: begin exists=ENABLE_SU;rdata_o=mie_irq_q&mideleg_q;end
      12'h105: begin exists=ENABLE_SU;rdata_o=stvec_q;end
      12'h106: begin exists=ENABLE_SU;rdata_o={61'b0,scounteren_q};end
      12'h140: begin exists=ENABLE_SU;rdata_o=sscratch_q;end
      12'h141: begin exists=ENABLE_SU;rdata_o=sepc_q;end
      12'h142: begin exists=ENABLE_SU;rdata_o=scause_q;end
      12'h143: begin exists=ENABLE_SU;rdata_o=stval_q;end
      12'h144: begin exists=ENABLE_SU;rdata_o=pending&mideleg_q;end
      12'h180: begin exists=ENABLE_SU;rdata_o=satp_q;end
      12'hf11,12'hf12,12'hf13,12'hf14,12'hf15: rdata_o=0;
      default: exists=0;
    endcase
    if(!exists) rdata_o=0;
    illegal_o=!exists || (write_intent_i && addr_i[11:10]==2'b11) || (ENABLE_SU && priv_q<addr_i[9:8]);
    if(ENABLE_SU && priv_q==1 && tvm_q && addr_i==12'h180) illegal_o=1;
    if(ENABLE_SU && priv_q!=3 && (addr_i==12'hc00 || addr_i==12'hc01 || addr_i==12'hc02)) begin
      if(!mcounteren_q[addr_i[1:0]] || (priv_q==0 && !scounteren_q[addr_i[1:0]])) illegal_o=1;
    end
  end
  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin
      mtvec_q<=0;mscratch_q<=0;mepc_q<=0;mcause_q<=0;mtval_q<=0;
      mcycle_q<=0;minstret_q<=0;mie_q<=0;mpie_q<=0;inhibit_q<=0;
      priv_q<=3;mpp_q<=3;sie_q<=0;spie_q<=0;spp_q<=0;adue_q<=0;mfiom_q<=0;sfiom_q<=0;
      mprv_q<=0;sum_q<=0;mxr_q<=0;tvm_q<=0;tw_q<=0;tsr_q<=0;
      stvec_q<=0;sscratch_q<=0;sepc_q<=0;scause_q<=0;stval_q<=0;satp_q<=0;
      medeleg_q<=0;mideleg_q<=0;mie_irq_q<=0;mip_sw_q<=0;mcounteren_q<=0;scounteren_q<=0;
    end else begin
      if(!inhibit_q[0]) mcycle_q<=mcycle_q+64'd1;
      if(!inhibit_q[2]) minstret_q<=minstret_q+64'(retire_i)+64'(retire_second_i);
      if(trap_i) begin
        if(delegated) begin
          sepc_q<={trap_pc_i[63:2],(ENABLE_C && trap_pc_i[1]),1'b0};scause_q<=trap_cause_i;stval_q<=trap_tval_i;
          spie_q<=sie_q;sie_q<=0;spp_q<=priv_q==1;priv_q<=1;
        end else begin
          mepc_q<={trap_pc_i[63:2],(ENABLE_C && trap_pc_i[1]),1'b0};mcause_q<=trap_cause_i;mtval_q<=trap_tval_i;
          mpie_q<=mie_q;mie_q<=0;mpp_q<=ENABLE_SU ? priv_q : 2'd3;priv_q<=3;
        end
      end else if(mret_i) begin
        if(!mret_illegal_o) begin
          mie_q<=mpie_q;mpie_q<=1;priv_q<=ENABLE_SU ? mpp_q : 2'd3;mpp_q<=ENABLE_SU ? 2'd0 : 2'd3;
          if(mpp_q!=3) mprv_q<=0;
        end
      end else if(sret_i && ENABLE_SU) begin
        if(!sret_illegal_o) begin
          sie_q<=spie_q;spie_q<=1;priv_q<=spp_q ? 2'd1 : 2'd0;spp_q<=0;mprv_q<=0;
        end
      end
      else if(csr_commit_i && write_intent_i && !illegal_o) begin
        case(addr_i)
          12'h300: begin
            mie_q<=wdata_i[3];mpie_q<=wdata_i[7];
            if(ENABLE_SU) begin
              mpp_q<=wdata_i[12:11]==2 ? 2'b0 : wdata_i[12:11];
              sie_q<=wdata_i[1];spie_q<=wdata_i[5];spp_q<=wdata_i[8];
              mprv_q<=wdata_i[17];sum_q<=wdata_i[18];mxr_q<=wdata_i[19];
              tvm_q<=wdata_i[20];tw_q<=wdata_i[21];tsr_q<=wdata_i[22];
            end
          end
          12'h302: medeleg_q<=wdata_i&DELEG_EXC_MASK;
          12'h303: mideleg_q<=wdata_i&DELEG_IRQ_MASK;
          12'h304: if(ENABLE_SU) mie_irq_q<=wdata_i&IRQ_MASK;
          12'h306: if(ENABLE_SU) mcounteren_q<=wdata_i[2:0];
          // All FENCE/aq/rl operations already fully serialize I/O and RAM;
          // FIOM=1 therefore needs no weaker, special-case ordering datapath.
          12'h30a: if(HAS_MMU) begin adue_q<=wdata_i[61];mfiom_q<=wdata_i[0];end
          12'h10a: if(ENABLE_SU && HAS_MMU) sfiom_q<=wdata_i[0];
          12'h344: if(ENABLE_SU) mip_sw_q<=mip_write&DELEG_IRQ_MASK;
          // Unsupported mtvec modes map to DIRECT; base supports IALIGN=32.
          12'h305: mtvec_q<={wdata_i[63:2],1'b0,wdata_i[1:0]==1};
          12'h320: inhibit_q<=wdata_i[2:0]&3'b101;
          12'h340: mscratch_q<=wdata_i;
          12'h341: mepc_q<={wdata_i[63:2],(ENABLE_C && wdata_i[1]),1'b0};
          12'h342: mcause_q<=wdata_i;
          12'h343: mtval_q<=wdata_i;
          12'hb00: mcycle_q<=wdata_i;
          12'hb02: minstret_q<=wdata_i;
          12'h100: begin
            sie_q<=wdata_i[1];spie_q<=wdata_i[5];spp_q<=wdata_i[8];sum_q<=wdata_i[18];mxr_q<=wdata_i[19];
          end
          12'h104: mie_irq_q<=(mie_irq_q&~mideleg_q) | (wdata_i&mideleg_q&IRQ_MASK);
          12'h105: stvec_q<={wdata_i[63:2],1'b0,wdata_i[1:0]==1};
          12'h106: scounteren_q<=wdata_i[2:0];
          12'h140: sscratch_q<=wdata_i;
          12'h141: sepc_q<={wdata_i[63:2],(ENABLE_C && wdata_i[1]),1'b0};
          12'h142: scause_q<=wdata_i;
          12'h143: stval_q<=wdata_i;
          12'h144: mip_sw_q<=(mip_sw_q&~(mideleg_q&64'd2)) | (wdata_i&mideleg_q&64'd2);
          12'h180: if(HAS_MMU && (wdata_i[63:60]==0 || wdata_i[63:60]==8))
            satp_q<={wdata_i[63:60],16'b0,wdata_i[43:0]}; // ASIDLEN=0, modes Bare/Sv39.
          default: begin end // WARL fixed/zero fields ignore legal writes.
        endcase
      end
    end
  end
`ifdef RV64_DUAL_CSR_FORMAL
  if(ENABLE_SU) begin: seip_formal
  `include "formal/rv64/r89_seip_properties.svh"
  end
  if(!ENABLE_SU) begin: machine_formal
  `include "formal/rv64/dual_csr_machine_properties.svh"
  end else begin: supervisor_formal
  `include "formal/rv64/r62_csr_privilege_properties.svh"
  if(HAS_MMU) begin: translation_csrs
    logic f_adue, f_mfiom, f_sfiom;
    logic [63:0] f_satp;
    always @(posedge clk_i) begin f_adue<=adue_q;f_satp<=satp_q;f_mfiom<=mfiom_q;f_sfiom<=sfiom_q;end
    always @* if(f_started && aresetn_i) begin
      assert((satp_q[63:60]==0 || satp_q[63:60]==8) && satp_q[59:44]==0);
      if(f_reset) assert(satp_q==0 && !adue_q && !mfiom_q && !sfiom_q);
      else begin
        assert(adue_q==((!f_trap && !f_mret && !f_sret && f_write && f_addr==12'h30a) ? f_data[61] : f_adue));
        assert(mfiom_q==((!f_trap && !f_mret && !f_sret && f_write && f_addr==12'h30a) ? f_data[0] : f_mfiom));
        assert(sfiom_q==((!f_trap && !f_mret && !f_sret && f_write && f_addr==12'h10a) ? f_data[0] : f_sfiom));
        assert(satp_q==((!f_trap && !f_mret && !f_sret && f_write && f_addr==12'h180 &&
          (f_data[63:60]==0 || f_data[63:60]==8)) ? {f_data[63:60],16'b0,f_data[43:0]} : f_satp));
      end
    end
  end
  end
`endif
endmodule
