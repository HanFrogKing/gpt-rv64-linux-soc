// R70 F/D candidate: registered shared integer normalization, unchanged seven-edge response.
`include "HardFloat_consts.vi"
// Seven-cycle FMA plus original-operand recode bank. Architectural FPR/CSR/LSU state
// belongs to the core and is not changed here. Only accepted, non-killed
// responses may retire. HardFloat Release 1, RISCV specialization, pristine.
module rv64_fp_execute (
 input logic clk_i, rst_ni, kill_i,
 input logic req_valid_i, output logic req_ready_o,
 input logic [31:0] req_insn_i,
 input logic [63:0] req_a_i, req_b_i, req_c_i, req_integer_i,
 input logic [2:0] req_frm_i,
 output logic rsp_valid_o, input logic rsp_ready_i,
 output logic [63:0] rsp_result_o,
 output logic [4:0] rsp_flags_o,
 output logic rsp_integer_o, rsp_illegal_o
);
 localparam [1:0] IDLE=0,CALC=1,WAIT_DIV=2,RESP=3;
 logic [1:0] state_q;
 logic [2:0] calc_age_q;
 logic [31:0] insn_q;
 logic [63:0] a_q,b_q,c_q,integer_q;
 logic [2:0] frm_q;
 wire fmt_d=insn_q[25];
 wire [4:0] fun=insn_q[31:27];
 wire [2:0] sub=insn_q[14:12];
 wire [4:0] rs2=insn_q[24:20];
 wire [6:0] opcode=insn_q[6:0];
 wire fused=(opcode==7'h43 || opcode==7'h47 || opcode==7'h4b || opcode==7'h4f);
 wire [2:0] rm=sub==7 ? frm_q : sub;
 wire [31:0] a_s=(&a_q[63:32]) ? a_q[31:0] : 32'h7fc00000;
 wire [31:0] b_s=(&b_q[63:32]) ? b_q[31:0] : 32'h7fc00000;
 wire [31:0] c_s=(&c_q[63:32]) ? c_q[31:0] : 32'h7fc00000;
 function automatic nan32(input [30:0] x);nan32=(&x[30:23]) && |x[22:0];endfunction
 function automatic nan64(input [62:0] x);nan64=(&x[62:52]) && |x[51:0];endfunction
 function automatic [63:0] boxed(input [31:0] x);boxed={32'hffffffff,x};endfunction
 function automatic [9:0] class32(input [31:0] x);
   logic z,e,n;begin z=x[30:23]==0;e=&x[30:23];n=|x[22:0];
     class32=10'b1 << (e ? (n ? (x[22]?9:8) : (x[31]?0:7)) :
                        z ? (n ? (x[31]?2:5) : (x[31]?3:4)) : (x[31]?1:6));end
 endfunction
 function automatic [9:0] class64(input [63:0] x);
   logic z,e,n;begin z=x[62:52]==0;e=&x[62:52];n=|x[51:0];
     class64=10'b1 << (e ? (n ? (x[51]?9:8) : (x[63]?0:7)) :
                        z ? (n ? (x[63]?2:5) : (x[63]?3:4)) : (x[63]?1:6));end
 endfunction
 wire [32:0] ar_s,br_s,cr_s;
 wire [64:0] ar_d,br_d,cr_d;
 logic [31:0] ma_s,mb_s,mc_s;
 logic [63:0] ma_d,mb_d,mc_d;
 logic [1:0] ma_op;
 // ADD/SUB use exact multiplication by one. MUL adds a zero with the
 // product's sign, preserving signed-zero semantics in every rounding mode.
 always_comb begin
   ma_s=a_s;mb_s=b_s;mc_s=c_s;ma_d=a_q;mb_d=b_q;mc_d=c_q;ma_op=insn_q[3:2];
   if(!fused) begin
     ma_op=0;
     if(fun==0 || fun==1) begin
       mb_s=32'h3f800000;mc_s=b_s;mb_d=64'h3ff0000000000000;mc_d=b_q;
       ma_op={1'b0,fun[0]};
     end else begin
       mc_s={a_s[31]^b_s[31],31'b0};mc_d={a_q[63]^b_q[63],63'b0};
     end
   end
 end
 fNToRecFN #(8,24) a32(ma_s,ar_s), b32(mb_s,br_s), c32(mc_s,cr_s);
 fNToRecFN #(11,53) a64(ma_d,ar_d), b64(mb_d,br_d), c64(mc_d,cr_d);
 wire [32:0] fma_sr;wire [64:0] fma_dr;
 wire [31:0] fma_s;wire [63:0] fma_d;wire [4:0] fma_sf,fma_df;
 // Seven edges from accepted request to FMA response. These are real
 // registers; no multicycle/false-path timing exceptions are introduced.
 for(genvar width_sel=0;width_sel<2;width_sel++)begin: fma_pipeline
   localparam integer E=width_sel==0?8:11;
   localparam integer P=width_sel==0?24:53;
   localparam integer AW=$clog2(P+1);
   logic [E+P:0] a0,b0,c0;
   logic [1:0] op0;logic [2:0] rm0;
   wire [P-1:0] mul_a,mul_b;
   wire [2*P-1:0] add_c;
   wire [5:0] pre_compact;
   wire signed [E+1:0] pre_exp;
   wire [AW-1:0] pre_dist;
   wire [P+1:0] pre_high;
   logic [P-1:0] a1,b1;
   logic [2*P-1:0] c1,c2,product2;
   logic [2*P:0] sum3;
   typedef struct packed {
     logic [5:0] compact;
     logic signed [E+1:0] exponent;
     logic [AW-1:0] distance;
     logic [P+1:0] high_c;
     logic [2:0] rounding;
   } intermed_t;
   intermed_t q1,q2,q3;
   wire raw_invalid,raw_nan,raw_inf,raw_zero,raw_sign;
   wire signed [E+1:0] raw_exp;
   wire [P+2:0] raw_sig;
   logic invalid4,nan4,inf4,zero4,sign4;
   logic signed [E+1:0] exp4;
   logic [P+2:0] sig4;
   logic [2:0] rm4;
   wire [E+P:0] rounded;
   wire [4:0] rounded_flags;
   logic [E+P:0] rounded5;
   logic [4:0] flags5;
   // E1: recode and operation selection. Data pipeline needs no reset:
   // CALC age prevents any uninitialized or killed transaction from retiring.
   if(width_sel==0)begin: single_input
     always_ff @(posedge clk_i)begin a0<=ar_s;b0<=br_s;c0<=cr_s;end
     assign fma_sr=rounded5;assign fma_sf=flags5;
   end else begin: double_input
     always_ff @(posedge clk_i)begin a0<=ar_d;b0<=br_d;c0<=cr_d;end
     assign fma_dr=rounded5;assign fma_df=flags5;
   end
   mulAddRecFNToRaw_preMul #(E,P) pre(1'b1,op0,a0,b0,c0,rm0,
     mul_a,mul_b,add_c,pre_compact,pre_exp,pre_dist,pre_high);
   mulAddRecFNToRaw_postMul #(E,P) post(q3.compact,q3.exponent,q3.distance,q3.high_c,
     sum3,q3.rounding,raw_invalid,raw_nan,raw_inf,raw_zero,raw_sign,raw_exp,raw_sig);
   roundRawFNToRecFN #(E,P,0) rounder(1'b1,invalid4,1'b0,nan4,inf4,zero4,sign4,exp4,sig4,
     rm4,rounded,rounded_flags);
   always_ff @(posedge clk_i)begin
     op0<=ma_op;rm0<=rm;
     // E2: exponent comparison, alignment, special cases.
     a1<=mul_a;b1<=mul_b;c1<=add_c;
     q1.compact<=pre_compact;q1.exponent<=pre_exp;q1.distance<=pre_dist;
     q1.high_c<=pre_high;q1.rounding<=rm0;
     // E3: exact significand product.
     product2<=a1*b1;c2<=c1;q2<=q1;
     // E4: product plus aligned addend, with full carry.
     sum3<={1'b0,product2}+{1'b0,c2};q3<=q2;
     // E5: cancellation and normalization, preserving guard/round/sticky.
     invalid4<=raw_invalid;nan4<=raw_nan;inf4<=raw_inf;zero4<=raw_zero;
     sign4<=raw_sign;exp4<=raw_exp;sig4<=raw_sig;rm4<=q3.rounding;
     // E6: one final IEEE rounding and exception flags.
     rounded5<=rounded;flags5<=rounded_flags;
     // E7 is the response bank in the enclosing execution controller.
   end
 end
 recFNToFN #(8,24) fmaOut32(fma_sr,fma_s);
 recFNToFN #(11,53) fmaOut64(fma_dr,fma_d);
 // Original operands are separately recoded for comparisons/conversions/divide.
 wire [32:0] a_sr_w,b_sr_w;wire [64:0] a_dr_w,b_dr_w;
 logic [32:0] a_sr,b_sr;logic [64:0] a_dr,b_dr;
 fNToRecFN #(8,24) opA32(a_s,a_sr_w),opB32(b_s,b_sr_w);
 fNToRecFN #(11,53) opA64(a_q,a_dr_w),opB64(b_q,b_dr_w);
 // Decode/normalize source operands separately from format/integer conversion.
 always_ff @(posedge clk_i)begin
   a_sr<=a_sr_w;b_sr<=b_sr_w;a_dr<=a_dr_w;b_dr<=b_dr_w;
 end
 wire lt_s,eq_s,gt_s,un_s,lt_d,eq_d,gt_d,un_d;
 wire [4:0] cmp_sf,cmp_df;
 wire cmp_signaling=fun==5 ? 1'b0 : sub!=2;
 compareRecFN #(8,24) compare32(a_sr,b_sr,cmp_signaling,lt_s,eq_s,gt_s,un_s,cmp_sf);
 compareRecFN #(11,53) compare64(a_dr,b_dr,cmp_signaling,lt_d,eq_d,gt_d,un_d,cmp_df);
 wire [63:0] integer64=rs2[1] ? integer_q :
                       rs2[0] ? {32'b0,integer_q[31:0]} : {{32{integer_q[31]}},integer_q[31:0]};
 wire [32:0] fromint_sr;wire [64:0] fromint_dr;
 wire [31:0] fromint_s;wire [63:0] fromint_d;wire [4:0] fromint_sf,fromint_df;
 // Share the exact upstream 64-bit normalization, then register its complete
 // raw representation and rounding mode before the S/D rounders. The enclosing
 // CALC age/kill contract prevents any stale transaction from retiring.
 wire fromint_zero_w,fromint_sign_w;
 wire signed [8:0] fromint_exp_w;
 wire [64:0] fromint_sig_w;
 logic fromint_zero_q,fromint_sign_q;
 logic signed [8:0] fromint_exp_q;
 logic [64:0] fromint_sig_q;
 logic [2:0] fromint_rm_q;
 iNToRawFN #(64) fromIntegerRaw(!rs2[0],integer64,
   fromint_zero_w,fromint_sign_w,fromint_exp_w,fromint_sig_w);
 always_ff @(posedge clk_i)begin
   fromint_zero_q<=fromint_zero_w;fromint_sign_q<=fromint_sign_w;
   fromint_exp_q<=fromint_exp_w;fromint_sig_q<=fromint_sig_w;
   fromint_rm_q<=rm;
 end
 roundAnyRawFNToRecFN #(7,64,8,24,
   `flRoundOpt_sigMSBitAlwaysZero | `flRoundOpt_neverUnderflows)
   fromInteger32(1'b1,1'b0,1'b0,1'b0,1'b0,fromint_zero_q,fromint_sign_q,
     fromint_exp_q,fromint_sig_q,fromint_rm_q,fromint_sr,fromint_sf);
 roundAnyRawFNToRecFN #(7,64,11,53,
   `flRoundOpt_sigMSBitAlwaysZero | `flRoundOpt_neverUnderflows)
   fromInteger64(1'b1,1'b0,1'b0,1'b0,1'b0,fromint_zero_q,fromint_sign_q,
     fromint_exp_q,fromint_sig_q,fromint_rm_q,fromint_dr,fromint_df);
 recFNToFN #(8,24) fromIntegerOut32(fromint_sr,fromint_s);
 recFNToFN #(11,53) fromIntegerOut64(fromint_dr,fromint_d);
 wire [31:0] toint_sw,toint_dw;wire [63:0] toint_sl,toint_dl;
 wire [2:0] toint_swf,toint_dwf,toint_slf,toint_dlf;
 recFNToIN #(8,24,32) toSW(1'b1,a_sr,rm,!rs2[0],toint_sw,toint_swf);
 recFNToIN #(11,53,32) toDW(1'b1,a_dr,rm,!rs2[0],toint_dw,toint_dwf);
 recFNToIN #(8,24,64) toSL(1'b1,a_sr,rm,!rs2[0],toint_sl,toint_slf);
 recFNToIN #(11,53,64) toDL(1'b1,a_dr,rm,!rs2[0],toint_dl,toint_dlf);
 wire [32:0] cvt_sr;wire [64:0] cvt_dr;
 wire [31:0] cvt_s;wire [63:0] cvt_d;wire [4:0] cvt_sf,cvt_df;
 recFNToRecFN #(11,53,8,24) convert32(1'b1,a_dr,rm,cvt_sr,cvt_sf);
 recFNToRecFN #(8,24,11,53) convert64(1'b1,a_sr,rm,cvt_dr,cvt_df);
 recFNToFN #(8,24) convertOut32(cvt_sr,cvt_s);
 recFNToFN #(11,53) convertOut64(cvt_dr,cvt_d);
 logic illegal,uses_rm,wants_div,integer_result;
 logic [63:0] result;
 logic [4:0] flags;
 logic [2:0] int_flags;
 logic [31:0] sign_s,min_s;
 logic [63:0] sign_d,min_d;
 always_comb begin
   // NaN boxing applies to sign-injection and FCLASS, but NOT FMV.X.W.
   sign_s={sub==0?b_s[31]:sub==1?!b_s[31]:a_s[31]^b_s[31],a_s[30:0]};
   sign_d={sub==0?b_q[63]:sub==1?!b_q[63]:a_q[63]^b_q[63],a_q[62:0]};
   min_s=(lt_s || (eq_s && a_s[31])) ? (sub[0]?b_s:a_s) : (sub[0]?a_s:b_s);
   min_d=(lt_d || (eq_d && a_q[63])) ? (sub[0]?b_q:a_q) : (sub[0]?a_q:b_q);
   if(nan32(a_s[30:0]))min_s=nan32(b_s[30:0])?32'h7fc00000:b_s;
   else if(nan32(b_s[30:0]))min_s=a_s;
   if(nan64(a_q[62:0]))min_d=nan64(b_q[62:0])?64'h7ff8000000000000:b_q;
   else if(nan64(b_q[62:0]))min_d=a_q;
   result=0;flags=0;illegal=0;uses_rm=0;wants_div=0;integer_result=0;int_flags=0;
   if(insn_q[26]) illegal=1; // only S and D, no H/Q formats
   if(fused) begin
     uses_rm=1;result=fmt_d?fma_d:boxed(fma_s);flags=fmt_d?fma_df:fma_sf;
   end else if(opcode==7'h53) begin
     case(fun)
       0,1,2: begin uses_rm=1;result=fmt_d?fma_d:boxed(fma_s);flags=fmt_d?fma_df:fma_sf;end
       3,11: begin uses_rm=1;wants_div=1;if(fun==11 && rs2!=0)illegal=1;end
       4: begin result=fmt_d?sign_d:boxed(sign_s);if(sub>2)illegal=1;end
       5: begin result=fmt_d?min_d:boxed(min_s);flags=fmt_d?cmp_df:cmp_sf;if(sub>1)illegal=1;end
       8: begin
         uses_rm=1;result=fmt_d?cvt_d:boxed(cvt_s);flags=fmt_d?cvt_df:cvt_sf;
         if(rs2!=(fmt_d?0:1))illegal=1;
       end
       20: begin
         integer_result=1;flags=fmt_d?cmp_df:cmp_sf;
         if(sub==2) result={63'b0,fmt_d?eq_d:eq_s};
         else if(sub==1) result={63'b0,fmt_d?lt_d:lt_s};
         else if(sub==0) result={63'b0,fmt_d?(lt_d||eq_d):(lt_s||eq_s)};
         else illegal=1;
       end
       24: begin
         uses_rm=1;integer_result=1;
         if(rs2[1]) begin result=fmt_d?toint_dl:toint_sl;int_flags=fmt_d?toint_dlf:toint_slf;end
         else begin
           result=fmt_d?{{32{toint_dw[31]}},toint_dw}:{{32{toint_sw[31]}},toint_sw};
           int_flags=fmt_d?toint_dwf:toint_swf;
         end
         flags={int_flags[2]|int_flags[1],3'b0,int_flags[0]};
         if(rs2>3)illegal=1;
       end
       26: begin
         uses_rm=1;result=fmt_d?fromint_d:boxed(fromint_s);flags=fmt_d?fromint_df:fromint_sf;
         if(rs2>3)illegal=1;
       end
       28: begin
         integer_result=1;
         if(sub==0)result=fmt_d?a_q:{{32{a_q[31]}},a_q[31:0]};
         else if(sub==1)result={54'b0,fmt_d?class64(a_q):class32(a_s)};
         else illegal=1;
         if(rs2!=0)illegal=1;
       end
       30: begin result=fmt_d?integer_q:boxed(integer_q[31:0]);if(rs2!=0 || sub!=0)illegal=1;end
       default: illegal=1;
     endcase
   end else illegal=1;
   if(uses_rm && rm>4)illegal=1;
   if(illegal)begin result=0;flags=0;integer_result=0;wants_div=0;end
 end
 wire div_s_ready,div_d_ready,div_s_valid,div_d_valid,div_s_sqrt,div_d_sqrt;
 wire [32:0] div_sr;wire [64:0] div_dr;
 wire [31:0] div_s;wire [63:0] div_d;wire [4:0] div_sf,div_df;
 wire div_start=state_q==CALC && calc_age_q>=1 && wants_div && !illegal && !kill_i;
 wire hf_reset_n=rst_ni && !kill_i;
 divSqrtRecFN_small #(8,24,0) div32(hf_reset_n,clk_i,1'b1,div_s_ready,
   div_start&&!fmt_d,fun==11,a_sr,b_sr,rm,div_s_valid,div_s_sqrt,div_sr,div_sf);
 divSqrtRecFN_small #(11,53,0) div64(hf_reset_n,clk_i,1'b1,div_d_ready,
   div_start&&fmt_d,fun==11,a_dr,b_dr,rm,div_d_valid,div_d_sqrt,div_dr,div_df);
 recFNToFN #(8,24) divOut32(div_sr,div_s);
 recFNToFN #(11,53) divOut64(div_dr,div_d);
 wire unused_compare=^{gt_s,gt_d,un_s,un_d,div_s_sqrt,div_d_sqrt,insn_q[19:15],insn_q[11:7]};
 assign req_ready_o=rst_ni && state_q==IDLE && !kill_i;
 assign rsp_valid_o=rst_ni && state_q==RESP && !kill_i;
 always_ff @(posedge clk_i or negedge rst_ni) begin
   if(!rst_ni)begin
     state_q<=IDLE;calc_age_q<=0;insn_q<=0;a_q<=0;b_q<=0;c_q<=0;integer_q<=0;frm_q<=0;
     rsp_result_o<=0;rsp_flags_o<=0;rsp_integer_o<=0;rsp_illegal_o<=0;
   end else if(kill_i)begin state_q<=IDLE;end
   else case(state_q)
     IDLE:if(req_valid_i)begin
       insn_q<=req_insn_i;a_q<=req_a_i;b_q<=req_b_i;c_q<=req_c_i;
       integer_q<=req_integer_i;frm_q<=req_frm_i;state_q<=CALC;calc_age_q<=0;
     end
     CALC:begin
       if(wants_div && !illegal)begin
         if(calc_age_q>=1 && (fmt_d?div_d_ready:div_s_ready))state_q<=WAIT_DIV;
         else if(calc_age_q<1)calc_age_q<=calc_age_q+1'b1;
       end else if(illegal || calc_age_q==6) begin
         rsp_result_o<=result;rsp_flags_o<=flags;rsp_integer_o<=integer_result;
         rsp_illegal_o<=illegal;state_q<=RESP;
       end else calc_age_q<=calc_age_q+1'b1;
     end
     WAIT_DIV:if(fmt_d?div_d_valid:div_s_valid)begin
       rsp_result_o<=fmt_d?div_d:boxed(div_s);rsp_flags_o<=fmt_d?div_df:div_sf;
       rsp_integer_o<=0;rsp_illegal_o<=0;state_q<=RESP;
     end
     RESP:if(rsp_ready_i)state_q<=IDLE;
     default:state_q<=IDLE;
   endcase
 end
`ifdef RV64_FP_EXECUTE_FORMAL
 `include "formal/rv64/r70_fp_execute_properties.svh"
`endif
endmodule
