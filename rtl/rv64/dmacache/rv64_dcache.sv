// R84 isolated DMA maintenance candidate, derived from accepted R46 blocking cache.
// maint_op: 0 clean, 1 invalidate (reject dirty), 2 flush; 3 is DECERR.
// Physical address rounds down to a 32-byte line. One command, held done/ack.
// DMA ownership forbids CPU writes while device owns a streaming buffer.
// NC_BASE/NC_BYTES describe a static physical uncached pool, not coherency.
// Control integration must drain its own MMIO response before starting maintenance.
// D1 candidate. Blocking physical write-back/write-allocate cache.
// Common reset discards dirty RAM; reset must span a rising clock edge.
module rv64_dcache #(
  parameter bit ENABLE=1,
  parameter logic [63:0] RAM_BASE=64'h80000000,
  parameter logic [63:0] RAM_BYTES=64'h08000000,
  parameter logic [63:0] NC_BASE=64'h87000000,
  parameter logic [63:0] NC_BYTES=64'd0
) (
input logic clk_i, aresetn_i,
input logic  d_ptw_i,
input logic  d_axi_arvalid_i,
output logic  d_axi_arready_o,
input logic  d_axi_arid_i,
input logic [63:0] d_axi_araddr_i,
input logic [7:0] d_axi_arlen_i,
input logic [2:0] d_axi_arsize_i,
input logic [2:0] d_axi_arprot_i,
input logic [1:0] d_axi_arburst_i,
input logic  d_axi_arlock_i,
input logic [3:0] d_axi_arcache_i,
output logic  d_axi_rvalid_o,
input logic  d_axi_rready_i,
output logic  d_axi_rid_o,
output logic  d_axi_rlast_o,
output logic [63:0] d_axi_rdata_o,
output logic [1:0] d_axi_rresp_o,
input logic  d_axi_awvalid_i,
output logic  d_axi_awready_o,
input logic  d_axi_awid_i,
input logic [63:0] d_axi_awaddr_i,
input logic [7:0] d_axi_awlen_i,
input logic [2:0] d_axi_awsize_i,
input logic [2:0] d_axi_awprot_i,
input logic [1:0] d_axi_awburst_i,
input logic  d_axi_awlock_i,
input logic [3:0] d_axi_awcache_i,
input logic  d_axi_wvalid_i,
output logic  d_axi_wready_o,
input logic [63:0] d_axi_wdata_i,
input logic [7:0] d_axi_wstrb_i,
input logic  d_axi_wlast_i,
output logic  d_axi_bvalid_o,
input logic  d_axi_bready_i,
output logic  d_axi_bid_o,
output logic [1:0] d_axi_bresp_o,

input logic clean_valid_i,
output logic clean_ready_o, clean_done_o,
input logic clean_ack_i,
input logic maint_valid_i,
output logic maint_ready_o, maint_done_o,
input logic maint_ack_i,
input logic [63:0] maint_addr_i,
input logic [1:0] maint_op_i,
output logic [1:0] maint_resp_o,
output logic [31:0] stat_maint_o, stat_maint_error_o,
output logic mem_req_valid_o,
input logic mem_req_ready_i,
output logic mem_req_write_o, mem_req_lock_o, mem_req_ptw_o,
output logic [63:0] mem_req_addr_o,
output logic [2:0] mem_req_size_o, mem_req_prot_o,
output logic [7:0] mem_req_len_o,
output logic [3:0] mem_req_cache_o,
output logic [255:0] mem_req_wdata_o,
output logic [31:0] mem_req_wstrb_o,
input logic mem_rsp_valid_i,
output logic mem_rsp_ready_o,
input logic [255:0] mem_rsp_data_i,
input logic [1:0] mem_rsp_resp_i,
input logic mem_fatal_i,
output logic fatal_o,
output logic [63:0] fault_addr_o,
output logic [1:0] fault_resp_o,
output logic fault_write_o,
output logic [31:0] stat_req_o, stat_hit_o, stat_miss_o,
output logic [31:0] stat_refill_o, stat_writeback_o, stat_bypass_o,
output logic [31:0] stat_clean_o, stat_error_o
);
localparam logic [3:0] IDLE=0,CHECK=1,GATHER_READ=2,GATHER_SAVE=3,
  MEM_REQ=4,MEM_WAIT=5,FILL=6,INSTALL=7,RESP=8,CLEAN_SCAN=9,CLEAN_CHECK=10,STOP=11,MAINT_SCAN=12,MAINT_CHECK=13;
localparam logic [1:0] KIND_WB=0,KIND_FILL=1,KIND_BYPASS=2;
localparam logic [1:0] AFTER_MISS=0,AFTER_LOCK=1,AFTER_CLEAN=2,AFTER_MAINT=3;
logic [3:0] state_q;
logic [127:0] valid_q,dirty_q;
logic [63:0] data_ram[0:511];
logic [51:0] tag_ram[0:127];
logic [63:0] read_data_q;
logic [51:0] read_tag_q;
logic aw_pending_q,w_pending_q;
logic [63:0] awaddr_q,wdata_q;
logic [7:0] awlen_q,wstrb_q;
logic [2:0] awsize_q,awprot_q;
logic [1:0] awburst_q;
logic [3:0] awcache_q;
logic awid_q,awlock_q,awptw_q,wlast_q;
logic [63:0] addr_q,store_data_q;
logic [7:0] store_strb_q;
logic [2:0] size_q,prot_q;
logic [3:0] cache_q;
logic write_q,lock_q,ptw_q;
logic [1:0] resp_q,kind_q,after_q,word_q;
logic [63:0] data_q,wb_addr_q;
logic [6:0] work_index_q,scan_q;
logic [255:0] line_q;
logic clean_done_q,fatal_q;
logic maint_done_q;
logic [1:0] maint_op_q,maint_resp_q;
logic [63:0] maint_addr_q;
wire [6:0] maint_index=maint_addr_q[11:5];
wire maint_hit=valid_q[maint_index] && read_tag_q==maint_addr_q[63:12];
function automatic logic in_ram(input logic [63:0] line_addr);
  in_ram=RAM_BYTES>=32 && line_addr>=RAM_BASE && line_addr-RAM_BASE<=RAM_BYTES-64'd32;
endfunction
function automatic logic in_nc(input logic [63:0] line_addr);
  in_nc=NC_BYTES>=32 && line_addr>=NC_BASE && line_addr-NC_BASE<=NC_BYTES-64'd32;
endfunction
wire [63:0] maint_start_line={maint_addr_i[63:5],5'b0};
wire unused_maint_offset=^maint_addr_i[4:0];
wire maint_legal=maint_op_i!=3 && in_ram(maint_start_line);
logic [63:0] fault_addr_q;
logic [1:0] fault_resp_q;
logic fault_write_q;
wire [6:0] index_q=addr_q[11:5];
wire hit=valid_q[index_q] && read_tag_q==addr_q[63:12];
wire idle=state_q==IDLE && !fatal_q && !clean_done_q && !maint_done_q;
wire write_start=aresetn_i && idle && (aw_pending_q || aw_fire) && (w_pending_q || w_fire);
wire read_fire=d_axi_arvalid_i && d_axi_arready_o;
wire aw_fire=d_axi_awvalid_i && d_axi_awready_o;
wire w_fire=d_axi_wvalid_i && d_axi_wready_o;
wire clean_fire=clean_valid_i && clean_ready_o;
wire maint_fire=maint_valid_i && maint_ready_o;
wire rsp_fire=mem_rsp_valid_i && mem_rsp_ready_o;
wire [63:0] start_addr=write_start ? write_addr : d_axi_araddr_i;
wire [2:0] start_size=write_start ? write_size : d_axi_arsize_i;
wire start_lock=write_start ? write_lock : d_axi_arlock_i;
wire [63:0] start_line={start_addr[63:5],5'b0};
wire cacheable=ENABLE && in_ram(start_line) && !in_nc(start_line);
wire [7:0] lane_mask=8'((9'd1<<(1<<start_size))-9'd1)<<start_addr[2:0];
wire invalid_start=start_size>3 || (start_addr & ((64'd1<<start_size)-64'd1))!=0 ||
  (start_lock && start_size!=2 && start_size!=3) ||
  (write_start ? (write_id || write_len!=0 || write_burst!=1 || !write_last || |(write_strb & ~lane_mask)) :
                 (d_axi_arid_i || d_axi_arlen_i!=0 || d_axi_arburst_i!=1));
// Select accepted channel payloads independently; either channel may already
// be buffered, or handshake in the current cycle. No AXI VALID depends on READY.
wire [63:0] write_addr=aw_pending_q?awaddr_q:d_axi_awaddr_i;
wire [7:0] write_len=aw_pending_q?awlen_q:d_axi_awlen_i;
wire [2:0] write_size=aw_pending_q?awsize_q:d_axi_awsize_i;
wire [2:0] write_prot=aw_pending_q?awprot_q:d_axi_awprot_i;
wire [1:0] write_burst=aw_pending_q?awburst_q:d_axi_awburst_i;
wire [3:0] write_cache=aw_pending_q?awcache_q:d_axi_awcache_i;
wire write_id=aw_pending_q?awid_q:d_axi_awid_i;
wire write_lock=aw_pending_q?awlock_q:d_axi_awlock_i;
wire write_ptw=aw_pending_q?awptw_q:d_ptw_i;
wire [63:0] write_data=w_pending_q?wdata_q:d_axi_wdata_i;
wire [7:0] write_strb=w_pending_q?wstrb_q:d_axi_wstrb_i;
wire write_last=w_pending_q?wlast_q:d_axi_wlast_i;
wire hit_response=state_q==CHECK && hit && !lock_q && !fatal_q && !mem_fatal_i;
wire lookup_start=(read_fire || write_start) && !invalid_start && cacheable;
wire [8:0] ram_read_addr=lookup_start ? start_addr[11:3] : {work_index_q,word_q};
wire [6:0] tag_read_addr=lookup_start ? start_addr[11:5] : state_q==MAINT_SCAN ? maint_index : scan_q;
wire ram_read=lookup_start || (aresetn_i && state_q==GATHER_READ);
wire tag_read=lookup_start || (aresetn_i && (state_q==CLEAN_SCAN || state_q==MAINT_SCAN));
wire hit_store=aresetn_i && state_q==CHECK && hit && !lock_q && write_q;
wire fill_write=aresetn_i && state_q==FILL;
wire [8:0] ram_write_addr=hit_store ? addr_q[11:3] : {index_q,word_q};
wire [63:0] ram_write_data=hit_store ? store_data_q : line_q[int'(word_q)*64+:64];
wire [7:0] ram_write_strb=hit_store ? store_strb_q : 8'hff;
wire tag_write=aresetn_i && state_q==INSTALL;

// R46 only a consumed, successful ordinary read hit may hand off to the next
// valid ordinary cacheable read. No writes, locks, PTW, maintenance or faults.
wire read_turn_slot=hit_response && !write_q && d_axi_rready_i && !clean_done_q &&
  !d_axi_arlock_i && !d_ptw_i && !invalid_start && cacheable;
assign d_axi_arready_o=aresetn_i && (idle || read_turn_slot) && !aw_pending_q && !w_pending_q &&
  !d_axi_awvalid_i && !d_axi_wvalid_i && !clean_valid_i && !maint_valid_i;
assign d_axi_awready_o=aresetn_i && idle && !aw_pending_q && ((!clean_valid_i && !maint_valid_i) || w_pending_q);
assign d_axi_wready_o=aresetn_i && idle && !w_pending_q && ((!clean_valid_i && !maint_valid_i) || aw_pending_q);
assign d_axi_rvalid_o=aresetn_i && (state_q==RESP || hit_response) && !write_q;
assign d_axi_rid_o=1'b0;
assign d_axi_rlast_o=1'b1;
assign d_axi_rdata_o=hit_response ? read_data_q : data_q;
assign d_axi_rresp_o=resp_q;
assign d_axi_bvalid_o=aresetn_i && (state_q==RESP || hit_response) && write_q;
assign d_axi_bid_o=1'b0;
assign d_axi_bresp_o=resp_q;
assign clean_ready_o=aresetn_i && idle && !aw_pending_q && !w_pending_q;
assign clean_done_o=aresetn_i && clean_done_q;
assign maint_ready_o=aresetn_i && idle && !aw_pending_q && !w_pending_q && !clean_valid_i;
assign maint_done_o=aresetn_i && maint_done_q;
assign maint_resp_o=maint_resp_q;
assign mem_req_valid_o=aresetn_i && state_q==MEM_REQ;
assign mem_req_write_o=kind_q==KIND_WB || (kind_q==KIND_BYPASS && write_q);
assign mem_req_lock_o=kind_q==KIND_BYPASS && lock_q;
assign mem_req_ptw_o=kind_q!=KIND_WB && ptw_q;
assign mem_req_addr_o=kind_q==KIND_WB ? wb_addr_q :
  kind_q==KIND_FILL ? {addr_q[63:5],5'b0} : addr_q;
assign mem_req_size_o=kind_q==KIND_BYPASS ? size_q : 3'd3;
assign mem_req_len_o=kind_q==KIND_BYPASS ? 8'd0 : 8'd3;
assign mem_req_prot_o=kind_q==KIND_WB ? 3'd0 : prot_q;
assign mem_req_cache_o=kind_q==KIND_BYPASS ? cache_q : 4'd0;
assign mem_req_wdata_o=kind_q==KIND_WB ? line_q : {192'd0,store_data_q};
assign mem_req_wstrb_o=kind_q==KIND_WB ? 32'hffffffff : {24'd0,store_strb_q};
assign mem_rsp_ready_o=aresetn_i && state_q==MEM_WAIT;
assign fatal_o=aresetn_i && fatal_q;
assign fault_addr_o=fault_addr_q;
assign fault_resp_o=fault_resp_q;
assign fault_write_o=fault_write_q;

always_ff @(posedge clk_i) begin
  if(ram_read) read_data_q<=data_ram[ram_read_addr];
  if(tag_read) read_tag_q<=tag_ram[tag_read_addr];
  if(hit_store || fill_write)
    for(integer lane=0;lane<8;lane=lane+1)
      if(ram_write_strb[lane]) data_ram[ram_write_addr][lane*8+:8]<=ram_write_data[lane*8+:8];
  if(tag_write) tag_ram[index_q]<=addr_q[63:12];
end

function automatic [63:0] merge_bytes(input [63:0] old_word,input [63:0] new_word,input [7:0] mask);
  merge_bytes=old_word;
  for(integer lane=0;lane<8;lane=lane+1)
    if(mask[lane]) merge_bytes[lane*8+:8]=new_word[lane*8+:8];
endfunction

always_ff @(posedge clk_i) begin
  if(!aresetn_i) begin
    state_q<=IDLE;valid_q<=0;dirty_q<=0;aw_pending_q<=0;w_pending_q<=0;
    awaddr_q<=0;awlen_q<=0;awsize_q<=0;awprot_q<=0;awburst_q<=0;awcache_q<=0;
    awid_q<=0;awlock_q<=0;awptw_q<=0;wdata_q<=0;wstrb_q<=0;wlast_q<=0;
    addr_q<=0;store_data_q<=0;store_strb_q<=0;size_q<=0;prot_q<=0;cache_q<=0;
    write_q<=0;lock_q<=0;ptw_q<=0;resp_q<=0;data_q<=0;kind_q<=0;after_q<=0;
    word_q<=0;work_index_q<=0;scan_q<=0;wb_addr_q<=0;line_q<=0;
    clean_done_q<=0;maint_done_q<=0;maint_op_q<=0;maint_addr_q<=0;maint_resp_q<=0;
    stat_maint_o<=0;stat_maint_error_o<=0;fatal_q<=0;fault_addr_q<=0;fault_resp_q<=0;fault_write_q<=0;
    stat_req_o<=0;stat_hit_o<=0;stat_miss_o<=0;stat_refill_o<=0;stat_writeback_o<=0;
    stat_bypass_o<=0;stat_clean_o<=0;stat_error_o<=0;
  end else if(mem_fatal_i && !fatal_q) begin
    fatal_q<=1;state_q<=STOP;fault_addr_q<=mem_req_addr_o;
    fault_resp_q<=mem_rsp_resp_i;fault_write_q<=mem_req_write_o;stat_error_o<=stat_error_o+1'b1;
  end else begin
    if(clean_done_q && clean_ack_i) clean_done_q<=0;
    if(maint_done_q && maint_ack_i) maint_done_q<=0;
    if(aw_fire) begin
      aw_pending_q<=1;awaddr_q<=d_axi_awaddr_i;awlen_q<=d_axi_awlen_i;
      awsize_q<=d_axi_awsize_i;awprot_q<=d_axi_awprot_i;awburst_q<=d_axi_awburst_i;
      awcache_q<=d_axi_awcache_i;awid_q<=d_axi_awid_i;awlock_q<=d_axi_awlock_i;awptw_q<=d_ptw_i;
    end
    if(w_fire) begin w_pending_q<=1;wdata_q<=d_axi_wdata_i;wstrb_q<=d_axi_wstrb_i;wlast_q<=d_axi_wlast_i;end
    case(state_q)
      IDLE: begin
        if(clean_fire) begin scan_q<=0;state_q<=CLEAN_SCAN;end
        if(maint_fire) begin
          maint_addr_q<=maint_start_line;maint_op_q<=maint_op_i;maint_resp_q<=0;
          work_index_q<=maint_addr_i[11:5];
          if(maint_legal) state_q<=MAINT_SCAN;
          else begin
            maint_resp_q<=3;maint_done_q<=1;
            stat_maint_o<=stat_maint_o+1'b1;stat_maint_error_o<=stat_maint_error_o+1'b1;
          end
        end
        if(read_fire || write_start) begin
          addr_q<=start_addr;size_q<=start_size;lock_q<=start_lock;write_q<=write_start;
          prot_q<=write_start ? write_prot : d_axi_arprot_i;
          cache_q<=write_start ? write_cache : d_axi_arcache_i;
          ptw_q<=write_start ? write_ptw : d_ptw_i;
          store_data_q<=write_start ? write_data : 64'd0;
          store_strb_q<=write_start ? write_strb : 8'd0;
          resp_q<=0;data_q<=0;stat_req_o<=stat_req_o+1'b1;
          if(write_start) begin aw_pending_q<=0;w_pending_q<=0;end
          if(invalid_start) begin resp_q<=3;stat_error_o<=stat_error_o+1'b1;state_q<=RESP;end
          else if(cacheable) state_q<=CHECK;
          else begin kind_q<=KIND_BYPASS;stat_bypass_o<=stat_bypass_o+1'b1;state_q<=MEM_REQ;end
        end
      end
      CHECK: begin
        if(lock_q) begin
          stat_bypass_o<=stat_bypass_o+1'b1;
          if(hit && dirty_q[index_q]) begin
            work_index_q<=index_q;wb_addr_q<={read_tag_q,index_q,5'b0};
            after_q<=AFTER_LOCK;word_q<=0;state_q<=GATHER_READ;
          end else begin
            if(hit) valid_q[index_q]<=0;
            kind_q<=KIND_BYPASS;state_q<=MEM_REQ;
          end
        end else if(hit) begin
          stat_hit_o<=stat_hit_o+1'b1;data_q<=read_data_q;
          if(write_q) dirty_q[index_q]<=1;
          state_q<=hit_response && (write_q ? d_axi_bready_i : d_axi_rready_i) ? IDLE : RESP;
          if(read_fire) begin
            addr_q<=d_axi_araddr_i;size_q<=d_axi_arsize_i;lock_q<=0;write_q<=0;
            prot_q<=d_axi_arprot_i;cache_q<=d_axi_arcache_i;ptw_q<=d_ptw_i;
            store_data_q<=0;store_strb_q<=0;resp_q<=0;data_q<=0;
            stat_req_o<=stat_req_o+1'b1;state_q<=CHECK;
          end
        end else begin
          stat_miss_o<=stat_miss_o+1'b1;
          if(valid_q[index_q] && dirty_q[index_q]) begin
            work_index_q<=index_q;wb_addr_q<={read_tag_q,index_q,5'b0};
            after_q<=AFTER_MISS;word_q<=0;state_q<=GATHER_READ;
          end else begin valid_q[index_q]<=0;kind_q<=KIND_FILL;state_q<=MEM_REQ;end
        end
      end
      GATHER_READ: state_q<=GATHER_SAVE;
      GATHER_SAVE: begin
        line_q[int'(word_q)*64+:64]<=read_data_q;
        if(word_q==3) begin kind_q<=KIND_WB;state_q<=MEM_REQ;end
        else begin word_q<=word_q+1'b1;state_q<=GATHER_READ;end
      end
      MEM_REQ: if(mem_req_ready_i) state_q<=MEM_WAIT;
      MEM_WAIT: if(rsp_fire) begin
        if((kind_q==KIND_WB && mem_rsp_resp_i!=0) || (mem_rsp_resp_i==1 && (kind_q!=KIND_BYPASS || !lock_q))) begin
          fatal_q<=1;state_q<=STOP;fault_addr_q<=mem_req_addr_o;
          fault_resp_q<=mem_rsp_resp_i;fault_write_q<=mem_req_write_o;stat_error_o<=stat_error_o+1'b1;
        end else if(kind_q==KIND_WB) begin
          dirty_q[work_index_q]<=0;stat_writeback_o<=stat_writeback_o+1'b1;
          if(after_q==AFTER_MAINT) begin
            if(maint_op_q==2) valid_q[work_index_q]<=0;
            maint_done_q<=1;maint_resp_q<=0;stat_maint_o<=stat_maint_o+1'b1;state_q<=IDLE;
          end else if(after_q==AFTER_CLEAN) begin
            if(scan_q==127) begin clean_done_q<=1;stat_clean_o<=stat_clean_o+1'b1;state_q<=IDLE;end
            else begin scan_q<=scan_q+1'b1;state_q<=CLEAN_SCAN;end
          end else begin
            valid_q[index_q]<=0;kind_q<=after_q==AFTER_LOCK ? KIND_BYPASS : KIND_FILL;state_q<=MEM_REQ;
          end
        end else if(mem_rsp_resp_i[1]) begin
          data_q<=0;resp_q<=mem_rsp_resp_i;stat_error_o<=stat_error_o+1'b1;state_q<=RESP;
        end else if(kind_q==KIND_FILL) begin
          line_q<=mem_rsp_data_i;
          if(write_q) line_q[int'(addr_q[4:3])*64+:64]<=merge_bytes(mem_rsp_data_i[int'(addr_q[4:3])*64+:64],store_data_q,store_strb_q);
          word_q<=0;state_q<=FILL;
        end else begin data_q<=mem_rsp_data_i[63:0];resp_q<=mem_rsp_resp_i;state_q<=RESP;end
      end
      FILL: if(word_q==3) state_q<=INSTALL;else word_q<=word_q+1'b1;
      INSTALL: begin
        valid_q[index_q]<=1;dirty_q[index_q]<=write_q;
        data_q<=line_q[int'(addr_q[4:3])*64+:64];stat_refill_o<=stat_refill_o+1'b1;state_q<=RESP;
      end
      RESP: if(write_q ? d_axi_bready_i : d_axi_rready_i) state_q<=IDLE;
      CLEAN_SCAN: begin work_index_q<=scan_q;state_q<=CLEAN_CHECK;end
      CLEAN_CHECK: begin
        if(valid_q[scan_q] && dirty_q[scan_q]) begin
          wb_addr_q<={read_tag_q,scan_q,5'b0};after_q<=AFTER_CLEAN;word_q<=0;state_q<=GATHER_READ;
        end else if(scan_q==127) begin clean_done_q<=1;stat_clean_o<=stat_clean_o+1'b1;state_q<=IDLE;end
        else begin scan_q<=scan_q+1'b1;state_q<=CLEAN_SCAN;end
      end
      MAINT_SCAN: state_q<=MAINT_CHECK;
      MAINT_CHECK: begin
        if(!ENABLE || in_nc(maint_addr_q) || !maint_hit) begin
          maint_done_q<=1;maint_resp_q<=0;stat_maint_o<=stat_maint_o+1'b1;state_q<=IDLE;
        end else if(maint_op_q==1) begin
          if(dirty_q[maint_index]) begin
            maint_resp_q<=2;stat_maint_error_o<=stat_maint_error_o+1'b1;
          end else begin valid_q[maint_index]<=0;dirty_q[maint_index]<=0;end
          maint_done_q<=1;stat_maint_o<=stat_maint_o+1'b1;state_q<=IDLE;
        end else if(dirty_q[maint_index]) begin
          wb_addr_q<={read_tag_q,maint_index,5'b0};work_index_q<=maint_index;
          after_q<=AFTER_MAINT;word_q<=0;state_q<=GATHER_READ;
        end else begin
          if(maint_op_q==2) begin valid_q[maint_index]<=0;dirty_q[maint_index]<=0;end
          maint_done_q<=1;maint_resp_q<=0;stat_maint_o<=stat_maint_o+1'b1;state_q<=IDLE;
        end
      end
      STOP: ;
      default: begin fatal_q<=1;state_q<=STOP;stat_error_o<=stat_error_o+1'b1;end
    endcase
  end
end
`ifdef RV64_DCACHE_FORMAL
`include "formal/rv64/r84_dmacache_properties.svh"
`endif
endmodule
