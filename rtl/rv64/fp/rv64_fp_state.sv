// Standalone architectural FP state. All mutation inputs denote RETIREMENT,
// never speculative execution. Integration must merge fs_o/sd_o into both
// mstatus and sstatus and serialize explicit FCSR/status writes with FP commit.
module rv64_fp_state (
 input logic clk_i,rst_ni,
 input logic fs_write_i,input logic [1:0] fs_wdata_i,
 output logic [1:0] fs_o,output logic sd_o,fp_enabled_o,
 input logic [4:0] rs1_i,rs2_i,rs3_i,
 output logic [63:0] rs1_o,rs2_o,rs3_o,
 input logic retire_i,retire_write_i,retire_single_i,
 input logic [4:0] retire_rd_i,retire_flags_i,
 input logic [63:0] retire_data_i,
 input logic [11:0] csr_addr_i,input logic [1:0] csr_op_i,
 input logic [63:0] csr_wdata_i,input logic csr_retire_i,
 output logic [63:0] csr_rdata_o,output logic csr_illegal_o,
 output logic [2:0] frm_o,output logic [4:0] fflags_o
);
 // FPRs intentionally have no reset: FS=Off blocks access after reset. OS
 // initializes registers before exposing a new context. f0 is writable.
 logic [63:0] fpr_q[0:31];
 logic [1:0] fs_q;
 logic [7:0] fcsr_q;
 logic [7:0] csr_old,csr_arg,csr_new,fcsr_next;
 logic csr_exists,csr_mutates;
 assign fs_o=fs_q;assign sd_o=fs_q==3;assign fp_enabled_o=fs_q!=0;
 assign frm_o=fcsr_q[7:5];assign fflags_o=fcsr_q[4:0];
 assign rs1_o=fp_enabled_o ? fpr_q[rs1_i] : 64'b0;
 assign rs2_o=fp_enabled_o ? fpr_q[rs2_i] : 64'b0;
 assign rs3_o=fp_enabled_o ? fpr_q[rs3_i] : 64'b0;
 always_comb begin
   csr_old=0;csr_arg=0;csr_exists=1;
   case(csr_addr_i)
     12'h001:begin csr_old={3'b0,fcsr_q[4:0]};csr_arg={3'b0,csr_wdata_i[4:0]};end
     12'h002:begin csr_old={5'b0,fcsr_q[7:5]};csr_arg={5'b0,csr_wdata_i[2:0]};end
     12'h003:begin csr_old=fcsr_q;csr_arg=csr_wdata_i[7:0];end
     default:csr_exists=0;
   endcase
   csr_illegal_o=!csr_exists || !fp_enabled_o;
   csr_rdata_o=csr_illegal_o ? 64'b0 : {56'b0,csr_old};
   csr_new=csr_old;
   case(csr_op_i)
     1:csr_new=csr_arg;
     2:csr_new=csr_old | csr_arg;
     3:csr_new=csr_old & ~csr_arg;
     default:begin end
   endcase
   // SET/CLEAR with zero mask are pure reads and leave FS clean. Masks use
   // architecturally implemented bits, while nonzero reserved-bit writes may
   // conservatively mark Dirty; no reserved rounding value is rejected here.
   csr_mutates=csr_retire_i && !csr_illegal_o &&
               (csr_op_i==1 || (csr_op_i!=0 && csr_wdata_i!=0));
   fcsr_next=fcsr_q;
   if(retire_i && fp_enabled_o) fcsr_next[4:0]=fcsr_q[4:0] | retire_flags_i;
   if(csr_mutates)case(csr_addr_i)
     12'h001:fcsr_next[4:0]=csr_new[4:0];
     12'h002:fcsr_next[7:5]=csr_new[2:0];
     12'h003:fcsr_next=csr_new;
     default:begin end
   endcase
 end
 always_ff @(posedge clk_i)begin
   if(rst_ni && fp_enabled_o && retire_i && retire_write_i)
     fpr_q[retire_rd_i]<=retire_single_i ? {32'hffffffff,retire_data_i[31:0]} : retire_data_i;
 end
 // Synchronous reset also gates the unreset register-file write port.
 always_ff @(posedge clk_i)begin
   if(!rst_ni)begin fs_q<=0;fcsr_q<=0;end
   else begin
     fcsr_q<=fcsr_next;
     if(fp_enabled_o && ((retire_i && (retire_write_i || retire_flags_i!=0)) || csr_mutates))fs_q<=3;
     // Explicit mstatus/sstatus FS write is the retirement ordering boundary.
     if(fs_write_i)fs_q<=fs_wdata_i;
   end
 end
 wire unused_csr_high=^csr_wdata_i[63:8];
`ifdef RV64_FP_STATE_FORMAL
 `include "formal/rv64/r57_fp_state_properties.svh"
`endif
endmodule
