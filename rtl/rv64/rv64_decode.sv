// R64-02/06: RV64IM + Zifencei decode; execution is a separate contract.
// Unimplemented/reserved encodings are rejected, except FENCE/FENCE.I fields
// which the base specifications explicitly require implementations to ignore.
module rv64_decode (
  input  logic [31:0] insn_i,
  output logic        illegal_o,
  output logic [3:0]  kind_o,
  output logic [4:0]  rd_o, rs1_o, rs2_o,
  output logic        write_rd_o, use_rs1_o, use_rs2_o,
  output logic [63:0] imm_o,
  output logic [4:0]  alu_op_o,
  output logic        alu_a_pc_o, alu_a_zero_o, alu_b_imm_o,
  output logic [2:0]  branch_op_o,
  output logic [1:0]  mem_size_o,
  output logic        mem_unsigned_o,
  output logic [3:0]  fence_pred_o, fence_succ_o,
  output logic [3:0]  md_op_o
);
  localparam logic [3:0] K_INVALID=0, K_ALU=1, K_LOAD=2, K_STORE=3,
    K_BRANCH=4, K_JAL=5, K_JALR=6, K_FENCE=7, K_FENCEI=8,
    K_ECALL=9, K_EBREAK=10, K_MULDIV=11;
  // Contract with rv64_alu; integration tests check every arithmetic family.
  localparam logic [4:0] A_ADD=0, A_SUB=1, A_SLL=2, A_SLT=3, A_SLTU=4,
    A_XOR=5, A_SRL=6, A_SRA=7, A_OR=8, A_AND=9,
    A_ADDW=10, A_SUBW=11, A_SLLW=12, A_SRLW=13, A_SRAW=14;
  wire [2:0] f3=insn_i[14:12];
  wire [6:0] f7=insn_i[31:25];
  wire [63:0] imm_i={{52{insn_i[31]}},insn_i[31:20]};
  wire [63:0] imm_s={{52{insn_i[31]}},insn_i[31:25],insn_i[11:7]};
  wire [63:0] imm_b={{51{insn_i[31]}},insn_i[31],insn_i[7],
    insn_i[30:25],insn_i[11:8],1'b0};
  wire [63:0] imm_u={{32{insn_i[31]}},insn_i[31:12],12'b0};
  wire [63:0] imm_j={{43{insn_i[31]}},insn_i[31],insn_i[19:12],
    insn_i[20],insn_i[30:21],1'b0};

  always_comb begin
    kind_o=K_INVALID; illegal_o=1'b1;
    rd_o=0; rs1_o=0; rs2_o=0;
    write_rd_o=0; use_rs1_o=0; use_rs2_o=0;
    imm_o=0; alu_op_o=A_ADD;
    alu_a_pc_o=0; alu_a_zero_o=0; alu_b_imm_o=0;
    branch_op_o=0; mem_size_o=0; mem_unsigned_o=0;
    fence_pred_o=0; fence_succ_o=0; md_op_o=0;
    case(insn_i[6:0])
      7'h37: begin // LUI: sign-extended U immediate, not a zero-extended 64-bit value.
        kind_o=K_ALU; write_rd_o=1; imm_o=imm_u;
        alu_a_zero_o=1; alu_b_imm_o=1;
      end
      7'h17: begin // AUIPC
        kind_o=K_ALU; write_rd_o=1; imm_o=imm_u;
        alu_a_pc_o=1; alu_b_imm_o=1;
      end
      7'h6f: begin
        kind_o=K_JAL; write_rd_o=1; imm_o=imm_j;
        alu_a_pc_o=1; alu_b_imm_o=1;
      end
      7'h67: if(f3==0) begin
        kind_o=K_JALR; write_rd_o=1; use_rs1_o=1;
        imm_o=imm_i; alu_b_imm_o=1;
        // Execution must later clear target bit 0, check alignment and write PC+4.
      end
      7'h63: if(f3==0 || f3==1 || f3>=4) begin
        kind_o=K_BRANCH; use_rs1_o=1; use_rs2_o=1;
        imm_o=imm_b; branch_op_o=f3; alu_a_pc_o=1; alu_b_imm_o=1;
        // ALU computes target. The branch comparator uses register operands.
      end
      7'h03: if(f3<=6) begin
        kind_o=K_LOAD; write_rd_o=1; use_rs1_o=1;
        imm_o=imm_i; alu_b_imm_o=1;
        mem_size_o=f3[1:0]; mem_unsigned_o=f3[2];
        // A load to x0 still has K_LOAD and must execute/fault; only GPR write is off.
      end
      7'h23: if(f3<=3) begin
        kind_o=K_STORE; use_rs1_o=1; use_rs2_o=1;
        imm_o=imm_s; alu_b_imm_o=1; mem_size_o=f3[1:0];
      end
      7'h13: begin
        write_rd_o=1; use_rs1_o=1; imm_o=imm_i; alu_b_imm_o=1;
        case(f3)
          0: begin kind_o=K_ALU; alu_op_o=A_ADD; end
          2: begin kind_o=K_ALU; alu_op_o=A_SLT; end
          3: begin kind_o=K_ALU; alu_op_o=A_SLTU; end
          4: begin kind_o=K_ALU; alu_op_o=A_XOR; end
          6: begin kind_o=K_ALU; alu_op_o=A_OR; end
          7: begin kind_o=K_ALU; alu_op_o=A_AND; end
          1: if(insn_i[31:26]==0) begin
            kind_o=K_ALU; alu_op_o=A_SLL; imm_o={58'b0,insn_i[25:20]};
          end
          5: if(insn_i[31:26]==0 || insn_i[31:26]==6'h10) begin
            kind_o=K_ALU; alu_op_o=insn_i[30] ? A_SRA : A_SRL;
            imm_o={58'b0,insn_i[25:20]};
          end
          default: begin end
        endcase
      end
      7'h1b: begin
        write_rd_o=1; use_rs1_o=1; imm_o=imm_i; alu_b_imm_o=1;
        case(f3)
          0: begin kind_o=K_ALU; alu_op_o=A_ADDW; end
          1: if(f7==0) begin
            kind_o=K_ALU; alu_op_o=A_SLLW; imm_o={59'b0,insn_i[24:20]};
          end
          5: if(f7==0 || f7==7'h20) begin
            kind_o=K_ALU; alu_op_o=insn_i[30] ? A_SRAW : A_SRLW;
            imm_o={59'b0,insn_i[24:20]};
          end
          default: begin end
        endcase
      end
      7'h33: begin
        write_rd_o=1; use_rs1_o=1; use_rs2_o=1;
        if(f7==0) begin
          kind_o=K_ALU;
          case(f3)
            0: alu_op_o=A_ADD;
            1: alu_op_o=A_SLL;
            2: alu_op_o=A_SLT;
            3: alu_op_o=A_SLTU;
            4: alu_op_o=A_XOR;
            5: alu_op_o=A_SRL;
            6: alu_op_o=A_OR;
            7: alu_op_o=A_AND;
            default: begin end
          endcase
        end else if(f7==7'h20 && (f3==0 || f3==5)) begin
          kind_o=K_ALU; alu_op_o=(f3==0) ? A_SUB : A_SRA;
        end else if(f7==1) begin
          kind_o=K_MULDIV;md_op_o={1'b0,f3};
        end
      end
      7'h3b: begin
        write_rd_o=1; use_rs1_o=1; use_rs2_o=1;
        if(f7==0 && (f3==0 || f3==1 || f3==5)) begin
          kind_o=K_ALU;
          case(f3)
            0: alu_op_o=A_ADDW;
            1: alu_op_o=A_SLLW;
            5: alu_op_o=A_SRLW;
            default: begin end
          endcase
        end else if(f7==7'h20 && (f3==0 || f3==5)) begin
          kind_o=K_ALU; alu_op_o=(f3==0) ? A_SUBW : A_SRAW;
        end else if(f7==1 && (f3==0 || f3>=4)) begin
          kind_o=K_MULDIV;
          case(f3)
            0: md_op_o=8;
            4: md_op_o=9;
            5: md_op_o=10;
            6: md_op_o=11;
            7: md_op_o=12;
            default: begin end
          endcase
        end
      end
      7'h0f: begin
        if(f3==0) begin
          kind_o=K_FENCE; fence_pred_o=insn_i[27:24]; fence_succ_o=insn_i[23:20];
          // Ignore fm/rs1/rd; execution may conservatively fence all operations.
        end else if(f3==1) kind_o=K_FENCEI; // Ignore imm12/rs1/rd per Zifencei.
      end
      7'h73: begin
        if(insn_i==32'h00000073) kind_o=K_ECALL;
        else if(insn_i==32'h00100073) kind_o=K_EBREAK;
      end
      default: begin end
    endcase
    illegal_o=(kind_o==K_INVALID);
    if(illegal_o) begin // Invalid encodings must not leak speculative side effects.
      write_rd_o=0; use_rs1_o=0; use_rs2_o=0;
      imm_o=0; alu_op_o=A_ADD;
      alu_a_pc_o=0; alu_a_zero_o=0; alu_b_imm_o=0;
      branch_op_o=0; mem_size_o=0; mem_unsigned_o=0;
      fence_pred_o=0; fence_succ_o=0;
    end
    write_rd_o=write_rd_o && (insn_i[11:7]!=0);
    rd_o=write_rd_o ? insn_i[11:7] : 5'b0;
    rs1_o=use_rs1_o ? insn_i[19:15] : 5'b0;
    rs2_o=use_rs2_o ? insn_i[24:20] : 5'b0;
  end
endmodule
