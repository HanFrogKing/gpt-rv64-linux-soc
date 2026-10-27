// R55 standalone RV64C v2.0 decompressor. No fetch/PC state or vendor IP.
// The consumer MUST carry length_o: C.JALR writes PC+2, not PC+4.
// illegal_o describes length/reserved/C.D legality only; normal 32-bit
// instruction legality remains the downstream decoder's responsibility.
module rv64_rvc_decode (
  input  logic [31:0] insn_i,
  input  logic        enable_d_i,
  output logic [31:0] expanded_o,
  output logic        compressed_o,
  output logic        illegal_o,
  output logic [2:0]  length_o
);
  wire [15:0] c = insn_i[15:0];
  wire [4:0] rd = c[11:7], rs2 = c[6:2];
  wire [4:0] rdp = {2'b01,c[4:2]}, rs1p = {2'b01,c[9:7]};
  wire [11:0] ci = {{6{c[12]}},c[12],c[6:2]};
  wire [11:0] addi4 = {2'b0,c[10:7],c[12:11],c[5],c[6],2'b0};
  wire [11:0] addi16 = {{3{c[12]}},c[4:3],c[5],c[2],c[6],4'b0};
  wire [11:0] lw = {5'b0,c[5],c[12:10],c[6],2'b0};
  wire [11:0] ld = {4'b0,c[6:5],c[12:10],3'b0};
  wire [11:0] lwsp = {4'b0,c[3:2],c[12],c[6:4],2'b0};
  wire [11:0] ldsp = {3'b0,c[4:2],c[12],c[6:5],3'b0};
  wire [11:0] swsp = {4'b0,c[8:7],c[12:9],2'b0};
  wire [11:0] sdsp = {3'b0,c[9:7],c[12:10],3'b0};
  wire [20:1] jimm = {{10{c[12]}},c[8],c[10:9],c[6],c[7],c[2],c[11],c[5:3]};
  wire [12:1] bimm = {{5{c[12]}},c[6:5],c[2],c[11:10],c[4:3]};
  function automatic [31:0] itype(input [11:0] imm,input [4:0] a,
      input [2:0] f,input [4:0] d,input [6:0] op);
    itype={imm,a,f,d,op};
  endfunction
  function automatic [31:0] stype(input [11:0] imm,input [4:0] b,
      input [4:0] a,input [2:0] f,input [6:0] op);
    stype={imm[11:5],b,a,f,imm[4:0],op};
  endfunction
  function automatic [31:0] rtype(input [6:0] f7,input [4:0] b,
      input [4:0] a,input [2:0] f,input [4:0] d,input [6:0] op);
    rtype={f7,b,a,f,d,op};
  endfunction
  always_comb begin
    compressed_o = c[1:0] != 2'b11;
    length_o = compressed_o ? 3'd2 : 3'd4;
    illegal_o = 1'b0;
    expanded_o = insn_i;
    if (!compressed_o) begin
      // No support for the >=48-bit instruction length encodings.
      illegal_o = c[4:2] == 3'b111;
    end else begin
      expanded_o = 32'b0;
      case (c[1:0])
        2'b00: case (c[15:13])
          3'b000: begin // ADDI4SPN, zero immediate is reserved
            expanded_o=itype(addi4,5'd2,3'd0,rdp,7'h13);
            illegal_o=addi4==0;
          end
          3'b001: begin expanded_o=itype(ld,rs1p,3'd3,rdp,7'h07); illegal_o=!enable_d_i; end
          3'b010: expanded_o=itype(lw,rs1p,3'd2,rdp,7'h03);
          3'b011: expanded_o=itype(ld,rs1p,3'd3,rdp,7'h03);
          3'b101: begin expanded_o=stype(ld,rdp,rs1p,3'd3,7'h27); illegal_o=!enable_d_i; end
          3'b110: expanded_o=stype(lw,rdp,rs1p,3'd2,7'h23);
          3'b111: expanded_o=stype(ld,rdp,rs1p,3'd3,7'h23);
          default: illegal_o=1'b1;
        endcase
        2'b01: case (c[15:13])
          3'b000: expanded_o=itype(ci,rd,3'd0,rd,7'h13); // ADDI/NOP/HINT
          3'b001: begin expanded_o=itype(ci,rd,3'd0,rd,7'h1b); illegal_o=rd==0; end
          3'b010: expanded_o=itype(ci,5'd0,3'd0,rd,7'h13); // LI/HINT
          3'b011: begin
            if (rd==5'd2) begin
              expanded_o=itype(addi16,5'd2,3'd0,5'd2,7'h13);
              illegal_o=addi16==0;
            end else begin
              expanded_o={{14{c[12]}},c[12],c[6:2],rd,7'h37};
              illegal_o=ci==0; // rd=x0 and nonzero immediate is a HINT
            end
          end
          3'b100: case(c[11:10])
            2'b00: expanded_o=itype({6'b0,c[12],c[6:2]},rs1p,3'd5,rs1p,7'h13);
            2'b01: expanded_o=itype({6'b010000,c[12],c[6:2]},rs1p,3'd5,rs1p,7'h13);
            2'b10: expanded_o=itype(ci,rs1p,3'd7,rs1p,7'h13);
            2'b11: begin
              if (!c[12]) case(c[6:5])
                2'b00: expanded_o=rtype(7'h20,rdp,rs1p,3'd0,rs1p,7'h33);
                2'b01: expanded_o=rtype(7'h00,rdp,rs1p,3'd4,rs1p,7'h33);
                2'b10: expanded_o=rtype(7'h00,rdp,rs1p,3'd6,rs1p,7'h33);
                2'b11: expanded_o=rtype(7'h00,rdp,rs1p,3'd7,rs1p,7'h33);
              endcase else case(c[6:5])
                2'b00: expanded_o=rtype(7'h20,rdp,rs1p,3'd0,rs1p,7'h3b);
                2'b01: expanded_o=rtype(7'h00,rdp,rs1p,3'd0,rs1p,7'h3b);
                default: illegal_o=1'b1;
              endcase
            end
          endcase
          3'b101: expanded_o={jimm[20],jimm[10:1],jimm[11],jimm[19:12],5'd0,7'h6f};
          3'b110,3'b111: expanded_o={bimm[12],bimm[10:5],5'd0,rs1p,
                                    2'b00,c[13],bimm[4:1],bimm[11],7'h63};
        endcase
        2'b10: case(c[15:13])
          3'b000: expanded_o=itype({6'b0,c[12],c[6:2]},rd,3'd1,rd,7'h13);
          3'b001: begin expanded_o=itype(ldsp,5'd2,3'd3,rd,7'h07); illegal_o=!enable_d_i; end
          3'b010: begin expanded_o=itype(lwsp,5'd2,3'd2,rd,7'h03); illegal_o=rd==0; end
          3'b011: begin expanded_o=itype(ldsp,5'd2,3'd3,rd,7'h03); illegal_o=rd==0; end
          3'b100: begin
            if (rs2==0) begin
              if (c[12] && rd==0) expanded_o=32'h00100073;
              else begin
                expanded_o=itype(12'b0,rd,3'd0,{4'b0,c[12]},7'h67);
                illegal_o=rd==0;
              end
            end else expanded_o=rtype(7'b0,rs2,c[12] ? rd : 5'd0,3'd0,rd,7'h33);
          end
          3'b101: begin expanded_o=stype(sdsp,rs2,5'd2,3'd3,7'h27); illegal_o=!enable_d_i; end
          3'b110: expanded_o=stype(swsp,rs2,5'd2,3'd2,7'h23);
          3'b111: expanded_o=stype(sdsp,rs2,5'd2,3'd3,7'h23);
        endcase
        default: illegal_o=1'b1;
      endcase
      if (illegal_o) expanded_o=32'b0;
    end
  end
`ifdef RV64_RVC_FORMAL
  `include "formal/rv64/r55_rvc_properties.svh"
`endif
endmodule
