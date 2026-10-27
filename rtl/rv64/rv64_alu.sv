// R64-01: standalone combinational ALU; not yet connected to a CPU pipeline.
// op_i is a local operation selector, NOT a RISC-V instruction encoding.
module rv64_alu (
  input  logic [4:0]  op_i,
  input  logic [63:0] a_i, b_i,
  output logic [63:0] result_o,
  output logic        illegal_o,
  output logic        eq_o, lt_o, ltu_o
);
  localparam logic [4:0]
    ALU_ADD=0, ALU_SUB=1, ALU_SLL=2, ALU_SLT=3, ALU_SLTU=4,
    ALU_XOR=5, ALU_SRL=6, ALU_SRA=7, ALU_OR=8, ALU_AND=9,
    ALU_ADDW=10, ALU_SUBW=11, ALU_SLLW=12, ALU_SRLW=13, ALU_SRAW=14;
  logic [31:0] word_result;

  assign eq_o  = a_i == b_i;
  assign lt_o  = $signed(a_i) < $signed(b_i);
  assign ltu_o = a_i < b_i;

  always_comb begin
    result_o = 64'b0;
    word_result = 32'b0;
    illegal_o = 1'b0;
    case (op_i)
      ALU_ADD:  result_o = a_i + b_i;
      ALU_SUB:  result_o = a_i - b_i;
      ALU_SLL:  result_o = a_i << b_i[5:0];
      ALU_SLT:  result_o = {63'b0, lt_o};
      ALU_SLTU: result_o = {63'b0, ltu_o};
      ALU_XOR:  result_o = a_i ^ b_i;
      ALU_SRL:  result_o = a_i >> b_i[5:0];
      ALU_SRA:  result_o = $unsigned($signed(a_i) >>> b_i[5:0]);
      ALU_OR:   result_o = a_i | b_i;
      ALU_AND:  result_o = a_i & b_i;
      ALU_ADDW: begin
        word_result = a_i[31:0] + b_i[31:0];
        result_o = {{32{word_result[31]}}, word_result};
      end
      ALU_SUBW: begin
        word_result = a_i[31:0] - b_i[31:0];
        result_o = {{32{word_result[31]}}, word_result};
      end
      ALU_SLLW: begin
        word_result = a_i[31:0] << b_i[4:0];
        result_o = {{32{word_result[31]}}, word_result};
      end
      ALU_SRLW: begin
        word_result = a_i[31:0] >> b_i[4:0];
        result_o = {{32{word_result[31]}}, word_result};
      end
      ALU_SRAW: begin
        word_result = $unsigned($signed(a_i[31:0]) >>> b_i[4:0]);
        result_o = {{32{word_result[31]}}, word_result};
      end
      default: illegal_o = 1'b1;
    endcase
  end
endmodule
