// Synthesizable read-only boot page at 0x1000, no vendor IP. The 40-byte
// program is independently rebuilt from sw/rv64/linux/bootrom.S by R76.
// Naturally aligned INCR reads, <=8-byte beats, no locked/cross-page access.
// Invalid reads drain ARLEN+1 zero/DECERR beats. All writes drain AWLEN+1
// beats and return DECERR. One read and write outstanding, common reset.
module rv64_boot_rom (
 input logic clk_i,aresetn_i,
 input logic s_arvalid_i,output logic s_arready_o,
 input logic s_arid_i,input logic [63:0] s_araddr_i,
 input logic [7:0] s_arlen_i,input logic [2:0] s_arsize_i,
 input logic [1:0] s_arburst_i,input logic s_arlock_i,
 output logic s_rvalid_o,input logic s_rready_i,
 output logic s_rid_o,s_rlast_o,output logic [63:0] s_rdata_o,output logic [1:0] s_rresp_o,
 input logic s_awvalid_i,output logic s_awready_o,
 input logic s_awid_i,input logic [63:0] s_awaddr_i,
 input logic [7:0] s_awlen_i,input logic [2:0] s_awsize_i,
 input logic [1:0] s_awburst_i,input logic s_awlock_i,
 input logic s_wvalid_i,output logic s_wready_o,input logic [63:0] s_wdata_i,
 input logic [7:0] s_wstrb_i,input logic s_wlast_i,
 output logic s_bvalid_o,input logic s_bready_i,output logic s_bid_o,output logic [1:0] s_bresp_o
);
 logic rvalid_q,rid_q,rbad_q,wid_q;
 logic [11:0] raddr_q;
 logic [7:0] rlen_q,rbeat_q,wlen_q,wbeat_q;
 logic [2:0] rsize_q;
 logic [1:0] wstate_q;
 localparam logic [1:0] W_IDLE=0,W_DATA=1,W_RESP=2;
 wire unused_fields=^{s_awaddr_i,s_awsize_i,s_awburst_i,s_awlock_i,s_wdata_i,s_wstrb_i,s_wlast_i};
 function automatic logic [63:0] rom_word(input logic [8:0] index);
  begin
   case(index)
    9'd0:rom_word=64'h00000297f1402573;
    9'd1:rom_word=64'h0002b58301428293;
    9'd2:rom_word=64'h000280670082b283;
    9'd3:rom_word=64'h0000000087e00000;
    9'd4:rom_word=64'h0000000080000000;
    default:rom_word=0;
   endcase
  end
 endfunction
 function automatic logic allowed(input logic [63:0] a,input logic [7:0] n,
  input logic [2:0] sz,input logic [1:0] burst,input logic lk);
  logic [12:0] finish;
  begin
   finish={1'b0,a[11:0]}+(({5'd0,n}+13'd1)<<sz);
   allowed=a[63:12]==52'd1&&sz<=3&&burst==1&&!lk&&
    (a[2:0]&((3'd1<<sz)-3'd1))==0&&finish<=13'h1000;
  end
 endfunction
 assign s_arready_o=aresetn_i&&!rvalid_q;
 assign s_rvalid_o=aresetn_i&&rvalid_q;
 assign s_rid_o=rid_q;assign s_rlast_o=rbeat_q==rlen_q;
 assign s_rresp_o=rbad_q?2'b11:2'b00;
 assign s_rdata_o=rbad_q?64'd0:rom_word(raddr_q[11:3]);
 assign s_awready_o=aresetn_i&&wstate_q==W_IDLE;
 assign s_wready_o=aresetn_i&&wstate_q==W_DATA;
 assign s_bvalid_o=aresetn_i&&wstate_q==W_RESP;
 assign s_bid_o=wid_q;assign s_bresp_o=2'b11;
 always_ff @(posedge clk_i or negedge aresetn_i)begin
  if(!aresetn_i)begin
   rvalid_q<=0;rid_q<=0;rbad_q<=0;raddr_q<=0;rlen_q<=0;rbeat_q<=0;rsize_q<=0;
   wstate_q<=W_IDLE;wid_q<=0;wlen_q<=0;wbeat_q<=0;
  end else begin
   if(s_arvalid_i&&s_arready_o)begin
    rvalid_q<=1;rid_q<=s_arid_i;raddr_q<=s_araddr_i[11:0];rlen_q<=s_arlen_i;rbeat_q<=0;rsize_q<=s_arsize_i;
    rbad_q<=!allowed(s_araddr_i,s_arlen_i,s_arsize_i,s_arburst_i,s_arlock_i);
   end else if(s_rvalid_o&&s_rready_i)begin
    if(s_rlast_o)rvalid_q<=0;
    else begin rbeat_q<=rbeat_q+8'd1;raddr_q<=raddr_q+(12'd1<<rsize_q);end
   end
   if(s_awvalid_i&&s_awready_o)begin
    wstate_q<=W_DATA;wid_q<=s_awid_i;wlen_q<=s_awlen_i;wbeat_q<=0;
   end else if(s_wvalid_i&&s_wready_o)begin
    if(wbeat_q==wlen_q)wstate_q<=W_RESP;
    else wbeat_q<=wbeat_q+8'd1;
   end else if(s_bvalid_o&&s_bready_i)wstate_q<=W_IDLE;
  end
 end
endmodule
