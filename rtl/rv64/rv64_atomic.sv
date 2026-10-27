// R10 candidate: ordered LR/SC and AMO sequencer over an exclusive-capable LSU.
// req_addr_i is PHYSICAL and permissions/PMA must be checked before acceptance.
// req_allowed_i rejects unsupported regions, including a reservation-missing SC.
// Ordinary stores/traps/context changes pulse kill_reservation_i at a boundary.
// All requests retire in order; aq/rl may use this stronger full ordering.
module rv64_atomic (
  input logic clk_i, aresetn_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input logic [4:0] req_op_i,
  input logic req_word_i, req_allowed_i,
  input logic [63:0] req_addr_i, req_operand_i,
  input logic kill_reservation_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output logic [63:0] rsp_data_o, rsp_cause_o, rsp_tval_o,
  output logic rsp_error_o,
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
  localparam logic [2:0] IDLE=0, RD_REQ=1, RD_WAIT=2, WR_REQ=3, WR_WAIT=4, RESP=5;
  localparam logic [4:0] LR=5'b00010, SC=5'b00011;
  logic [2:0] state_q;
  logic [4:0] op_q;
  logic word_q, res_word_q, res_valid_q;
  logic [63:0] addr_q, operand_q, old_q, res_addr_q;
  logic [63:0] data_q, cause_q, tval_q;
  logic error_q;
  logic [63:0] lhs, rhs, updated;
  logic op_legal;
  wire req_fire=req_valid_i && req_ready_o;
  wire bus_fire=bus_valid_o && bus_ready_i;
  wire bus_rsp_fire=bus_rsp_valid_i && bus_rsp_ready_o;
  wire req_misaligned=req_word_i ? |req_addr_i[1:0] : |req_addr_i[2:0];
  wire [63:0] loaded=word_q ? {{32{bus_rsp_data_i[31]}},bus_rsp_data_i[31:0]} : bus_rsp_data_i;
  always_comb begin
    case(req_op_i)
      5'h00,5'h01,LR,SC,5'h04,5'h08,5'h0c,5'h10,5'h14,5'h18,5'h1c: op_legal=1;
      default: op_legal=0;
    endcase
    lhs=word_q ? {{32{old_q[31]}},old_q[31:0]} : old_q;
    rhs=word_q ? {{32{operand_q[31]}},operand_q[31:0]} : operand_q;
    case(op_q)
      5'h00: updated=lhs+rhs;
      5'h01,SC: updated=rhs;
      5'h04: updated=lhs^rhs;
      5'h08: updated=lhs|rhs;
      5'h0c: updated=lhs&rhs;
      5'h10: updated=$signed(lhs)<$signed(rhs) ? lhs : rhs;
      5'h14: updated=$signed(lhs)>$signed(rhs) ? lhs : rhs;
      5'h18: updated=lhs<rhs ? lhs : rhs;
      5'h1c: updated=lhs>rhs ? lhs : rhs;
      default: updated=0;
    endcase
  end
  assign req_ready_o=aresetn_i && state_q==IDLE;
  assign rsp_valid_o=aresetn_i && state_q==RESP;
  assign rsp_data_o=data_q;
  assign rsp_error_o=error_q;
  assign rsp_cause_o=cause_q;
  assign rsp_tval_o=tval_q;
  assign bus_valid_o=aresetn_i && (state_q==RD_REQ || state_q==WR_REQ);
  assign bus_rsp_ready_o=aresetn_i && (state_q==RD_WAIT || state_q==WR_WAIT);
  assign bus_write_o=state_q==WR_REQ || state_q==WR_WAIT;
  assign bus_exclusive_o=1;
  assign bus_size_o=word_q ? 2'd2 : 2'd3;
  assign bus_addr_o=addr_q;
  assign bus_data_o=updated;
  always_ff @(posedge clk_i or negedge aresetn_i) begin
    if(!aresetn_i) begin
      state_q<=IDLE;op_q<=0;word_q<=0;addr_q<=0;operand_q<=0;old_q<=0;
      res_valid_q<=0;res_addr_q<=0;res_word_q<=0;
      data_q<=0;error_q<=0;cause_q<=0;tval_q<=0;
    end else begin
      case(state_q)
        IDLE: if(req_fire) begin
          op_q<=req_op_i;word_q<=req_word_i;addr_q<=req_addr_i;operand_q<=req_operand_i;
          data_q<=0;error_q<=0;cause_q<=0;tval_q<=0;
          // A new LR replaces the reservation; SC always consumes it. AMOs
          // conservatively invalidate an earlier local LR as a local store.
          res_valid_q<=0;
          if(!op_legal) begin error_q<=1;cause_q<=2;state_q<=RESP;end
          else if(req_misaligned || !req_allowed_i) begin
            error_q<=1;tval_q<=req_addr_i;
            cause_q<=req_misaligned ? (req_op_i==LR ? 64'd4 : 64'd6) :
              (req_op_i==LR ? 64'd5 : 64'd7);
            state_q<=RESP;
          end else if(req_op_i==SC) begin
            if(res_valid_q && res_addr_q==req_addr_i && res_word_q==req_word_i && !kill_reservation_i)
              state_q<=WR_REQ;
            else begin data_q<=1;state_q<=RESP;end
          end else state_q<=RD_REQ;
        end
        RD_REQ: if(bus_fire) state_q<=RD_WAIT;
        RD_WAIT: if(bus_rsp_fire) begin
          // OKAY on exclusive READ means the target lacks exclusive support;
          // this platform raises an access fault rather than unsafe RMW or
          // an LR/SC loop which can never make progress.
          if(bus_rsp_error_i || !bus_rsp_exokay_i) begin
            error_q<=1;cause_q<=op_q==LR ? 64'd5 : 64'd7;tval_q<=addr_q;state_q<=RESP;
          end else if(op_q==LR) begin
            data_q<=loaded;res_valid_q<=1;res_addr_q<=addr_q;res_word_q<=word_q;state_q<=RESP;
          end else begin old_q<=loaded;state_q<=WR_REQ;end
        end
        WR_REQ: if(bus_fire) state_q<=WR_WAIT;
        WR_WAIT: if(bus_rsp_fire) begin
          if(bus_rsp_error_i) begin error_q<=1;cause_q<=7;tval_q<=addr_q;state_q<=RESP;end
          else if(op_q==SC) begin data_q<=bus_rsp_exokay_i ? 64'd0 : 64'd1;state_q<=RESP;end
          else if(bus_rsp_exokay_i) begin data_q<=old_q;state_q<=RESP;end
          else state_q<=RD_REQ; // Lost exclusive monitor: re-read, recompute, retry.
        end
        RESP: if(rsp_ready_i) state_q<=IDLE;
        default: state_q<=IDLE;
      endcase
      // Boundary invalidation never cancels an irrevocable outstanding transfer.
      if(kill_reservation_i) res_valid_q<=0;
    end
  end
`ifdef RV64_ATOMIC_FORMAL
  `include "formal/rv64/atomic_properties.svh"
`endif
endmodule
