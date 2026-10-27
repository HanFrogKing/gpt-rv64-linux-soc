// R64-19 selectable MDU implementation; compile INSTEAD OF rv64_muldiv.sv.
// MULW: captured 16-bit limbs -> three registered products -> low-32 sum.
// Two cycles after request acceptance; other operations retain R06 latency.
// Pure SystemVerilog inferred arithmetic; no vendor IP.
// Request acceptance is irrevocable except for reset; result is held until ready.
module rv64_muldiv (
  input logic clk_i, aresetn_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input logic [3:0] req_op_i,
  input logic [63:0] req_a_i, req_b_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output logic [63:0] rsp_data_o,
  output logic rsp_illegal_o
);
  localparam logic [2:0] IDLE=0, MUL=1, DIV=2, RESP=3, MW_PRODUCT=4, MW_SUM=5;
  logic [2:0] state_q;
  logic [15:0] mw_al_q, mw_ah_q, mw_bl_q, mw_bh_q;
  logic [31:0] mw_ll_q;
  logic [15:0] mw_lh_q, mw_hl_q;
  wire [31:0] mw_low=mw_ll_q+{mw_lh_q,16'b0}+{mw_hl_q,16'b0};
  logic [6:0] remaining_q;
  logic word_q, high_q, negate_q, remainder_result_q, illegal_q;
  logic [127:0] product_q, multiplicand_q;
  logic [63:0] multiplier_q, dividend_q, result_q, remainder_q, divisor_q;
  logic [62:0] quotient_q;
  logic word_op, multiply_op, signed_a, signed_b, sign_a, sign_b;
  logic [63:0] normal_a, normal_b, magnitude_a, magnitude_b;
  logic [127:0] product_step, signed_product;
  logic [64:0] trial;
  logic [63:0] remainder_step;
  logic [63:0] quotient_step, division_magnitude, division_result, multiply_result;
  logic subtract_ok;
  wire req_fire=req_valid_i && req_ready_o;
  always_comb begin
    word_op=req_op_i>=8;
    multiply_op=req_op_i<=3 || req_op_i==8;
    signed_a=req_op_i==1 || req_op_i==2 || req_op_i==4 || req_op_i==6 || req_op_i==9 || req_op_i==11;
    signed_b=req_op_i==1 || req_op_i==4 || req_op_i==6 || req_op_i==9 || req_op_i==11;
    normal_a=word_op ? {{32{signed_a && req_a_i[31]}},req_a_i[31:0]} : req_a_i;
    normal_b=word_op ? {{32{signed_b && req_b_i[31]}},req_b_i[31:0]} : req_b_i;
    sign_a=signed_a && normal_a[63];sign_b=signed_b && normal_b[63];
    magnitude_a=sign_a ? (~normal_a+64'd1) : normal_a;
    magnitude_b=sign_b ? (~normal_b+64'd1) : normal_b;
    product_step=product_q+(multiplier_q[0] ? multiplicand_q : 128'b0);
    signed_product=negate_q ? (~product_step+128'd1) : product_step;
    multiply_result=high_q ? signed_product[127:64] : signed_product[63:0];
    trial={remainder_q,dividend_q[63]};
    subtract_ok=trial>={1'b0,divisor_q};
    remainder_step=subtract_ok ? trial[63:0]-divisor_q : trial[63:0];
    quotient_step={quotient_q,subtract_ok};
    division_magnitude=remainder_result_q ? remainder_step[63:0] : quotient_step;
    division_result=negate_q ? (~division_magnitude+64'd1) : division_magnitude;
    // Dividing by zero must give all ones even for a negative dividend.
    if(!remainder_result_q && divisor_q==0) division_result=64'hffffffffffffffff;
  end
  assign req_ready_o=aresetn_i && state_q==IDLE;
  assign rsp_valid_o=aresetn_i && state_q==RESP;
  assign rsp_data_o=result_q;
  assign rsp_illegal_o=illegal_q;
  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin
      state_q<=IDLE;remaining_q<=0;word_q<=0;high_q<=0;negate_q<=0;
      remainder_result_q<=0;illegal_q<=0;result_q<=0;product_q<=0;
      multiplicand_q<=0;multiplier_q<=0;dividend_q<=0;quotient_q<=0;
      remainder_q<=0;divisor_q<=0;
      mw_al_q<=0;mw_ah_q<=0;mw_bl_q<=0;mw_bh_q<=0;
      mw_ll_q<=0;mw_lh_q<=0;mw_hl_q<=0;
    end else begin
      case(state_q)
        IDLE: if(req_fire) begin
          illegal_q<=req_op_i>12;word_q<=word_op;high_q<=req_op_i>=1 && req_op_i<=3;
          remaining_q<=req_op_i==8 ? 7'd2 : word_op ? 7'd32 : 7'd64;
          mw_al_q<=req_a_i[15:0];mw_ah_q<=req_a_i[31:16];
          mw_bl_q<=req_b_i[15:0];mw_bh_q<=req_b_i[31:16];
          product_q<=0;multiplicand_q<={64'b0,magnitude_a};multiplier_q<=magnitude_b;
          dividend_q<=word_op ? {magnitude_a[31:0],32'b0} : magnitude_a;
          quotient_q<=0;remainder_q<=0;divisor_q<=magnitude_b;
          remainder_result_q<=req_op_i==6 || req_op_i==7 || req_op_i==11 || req_op_i==12;
          negate_q<=(req_op_i==6 || req_op_i==7 || req_op_i==11 || req_op_i==12) ? sign_a : sign_a^sign_b;
          result_q<=0;state_q<=req_op_i>12 ? RESP : req_op_i==8 ? MW_PRODUCT : multiply_op ? MUL : DIV;
        end
        MUL: begin
          product_q<=product_step;multiplicand_q<=multiplicand_q<<1;multiplier_q<=multiplier_q>>1;
          remaining_q<=remaining_q-7'd1;
          if(remaining_q==1) begin
            result_q<=word_q ? {{32{multiply_result[31]}},multiply_result[31:0]} : multiply_result;
            state_q<=RESP;
          end
        end
        MW_PRODUCT: begin
          mw_ll_q<=mw_al_q*mw_bl_q;
          mw_lh_q<=mw_al_q*mw_bh_q;
          mw_hl_q<=mw_ah_q*mw_bl_q;
          remaining_q<=remaining_q-7'd1;state_q<=MW_SUM;
        end
        MW_SUM: begin
          result_q<={{32{mw_low[31]}},mw_low};
          remaining_q<=remaining_q-7'd1;state_q<=RESP;
        end
        DIV: begin
          remainder_q<=remainder_step[63:0];quotient_q<=quotient_step[62:0];dividend_q<=dividend_q<<1;
          remaining_q<=remaining_q-7'd1;
          if(remaining_q==1) begin
            result_q<=word_q ? {{32{division_result[31]}},division_result[31:0]} : division_result;
            state_q<=RESP;
          end
        end
        RESP: if(rsp_ready_i) state_q<=IDLE;
        default: state_q<=IDLE;
      endcase
    end
  end
`ifdef RV64_MD_FORMAL
  `include "formal/rv64/fastmul_properties.svh"
`endif
endmodule
