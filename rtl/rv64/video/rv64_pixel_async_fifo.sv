// R99: vendor-independent dual-clock ready/valid pixel transport.
// One COMMON asynchronous reset flushes both domains. Each domain releases its
// own reset synchronously. A one-sided reset is not a supported interface.
// Storage: 2**ADDR_BITS RAM words plus one registered read/prefetch word.
module rv64_pixel_async_fifo #(
    parameter integer DATA_WIDTH = 32,
    parameter integer ADDR_BITS = 10
) (
    input  wire                  aresetn_i,
    input  wire                  wr_clk_i,
    input  wire                  wr_valid_i,
    input  wire [DATA_WIDTH-1:0] wr_data_i,
    output wire                  wr_ready_o,
    input  wire                  rd_clk_i,
    output wire                  rd_valid_o,
    output reg  [DATA_WIDTH-1:0] rd_data_o,
    input  wire                  rd_ready_i
);
    localparam integer PTR_BITS = ADDR_BITS+1;
    localparam integer DEPTH = 1 << ADDR_BITS;
    // ADDR_BITS >= 2, DATA_WIDTH >= 1; checked by simulation/elaboration gates.
    (* ASYNC_REG = "TRUE" *) reg [1:0] wr_release_q, rd_release_q;
    // Intentional mixed use: asynchronous control flush, synchronous RAM-address
    // initialization. Only these local release nets have this reset contract.
    /* verilator lint_off SYNCASYNCNET */
    (* ASYNC_REG = "TRUE" *) reg wr_active, rd_active;
    /* verilator lint_on SYNCASYNCNET */
    always @(posedge wr_clk_i or negedge aresetn_i)
        if (!aresetn_i) begin wr_release_q <= 2'b00; wr_active <= 0; end
        else begin wr_release_q <= {wr_release_q[0],1'b1}; wr_active <= wr_release_q[1]; end
    always @(posedge rd_clk_i or negedge aresetn_i)
        if (!aresetn_i) begin rd_release_q <= 2'b00; rd_active <= 0; end
        else begin rd_release_q <= {rd_release_q[0],1'b1}; rd_active <= rd_release_q[1]; end

    reg [PTR_BITS-1:0] wr_bin_q, wr_gray_q, rd_bin_q, rd_gray_q;
    (* ASYNC_REG = "TRUE" *) reg [PTR_BITS-1:0] rd_gray_meta_q, rd_gray_sync_q;
    (* ASYNC_REG = "TRUE" *) reg [PTR_BITS-1:0] wr_gray_meta_q, wr_gray_sync_q;
    reg full_q, empty_q, out_valid_q;
    assign wr_ready_o = wr_active && !full_q;
    assign rd_valid_o = rd_active && out_valid_q;
    wire wr_push = wr_valid_i && wr_ready_o;
    // Prefetch only into a free output slot or while that slot is consumed.
    wire rd_fetch = rd_active && !empty_q && (!out_valid_q || rd_ready_i);
    wire [PTR_BITS-1:0] wr_bin_next = wr_bin_q + {{ADDR_BITS{1'b0}},wr_push};
    wire [PTR_BITS-1:0] rd_bin_next = rd_bin_q + {{ADDR_BITS{1'b0}},rd_fetch};
    wire [PTR_BITS-1:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    wire [PTR_BITS-1:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;
    wire [PTR_BITS-1:0] full_compare = {~rd_gray_sync_q[PTR_BITS-1:PTR_BITS-2],
                                      rd_gray_sync_q[PTR_BITS-3:0]};

    // RAM addresses change only on their clock edge, including during reset.
    // Ready/valid are disabled asynchronously by wr_active/rd_active. The three
    // local release edges initialize these pointers before either can be used.
    always @(posedge wr_clk_i)
        if (!wr_active) wr_bin_q <= 0;
        else wr_bin_q <= wr_bin_next;
    always @(posedge rd_clk_i)
        if (!rd_active) rd_bin_q <= 0;
        else rd_bin_q <= rd_bin_next;
    // Only Gray transport/CDC state flushes asynchronously: a stopped source
    // clock must not leave a stale nonzero Gray pointer visible to its peer.
    // RAM enables instead depend on synchronous full/empty/output-valid state.
    always @(posedge wr_clk_i)
        if (!wr_active) full_q <= 0;
        else full_q <= (wr_gray_next == full_compare);
    always @(posedge rd_clk_i) begin
        if (!rd_active) begin empty_q <= 1; out_valid_q <= 0; end
        else begin
            empty_q <= (rd_gray_next == wr_gray_sync_q);
            if (rd_fetch) out_valid_q <= 1;
            else if (rd_ready_i) out_valid_q <= 0;
        end
    end
    always @(posedge wr_clk_i or negedge wr_active) begin
        if (!wr_active) begin
            wr_gray_q <= 0;
            rd_gray_meta_q <= 0; rd_gray_sync_q <= 0;
        end else begin
            rd_gray_meta_q <= rd_gray_q;
            rd_gray_sync_q <= rd_gray_meta_q;
            wr_gray_q <= wr_gray_next;
        end
    end
    always @(posedge rd_clk_i or negedge rd_active) begin
        if (!rd_active) begin
            rd_gray_q <= 0;
            wr_gray_meta_q <= 0; wr_gray_sync_q <= 0;
        end else begin
            wr_gray_meta_q <= wr_gray_q;
            wr_gray_sync_q <= wr_gray_meta_q;
            rd_gray_q <= rd_gray_next;
        end
    end
    // Synchronous read, no RAM/output-data reset: allows dual-clock BRAM.
    // Old RAM bits after reset are invalid until fresh pointer synchronization.
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    // No asynchronous control reaches a RAM address or enable. During local
    // reset these unqualified enables may perform a discarded RAM operation;
    // the external interface is inactive and all pointers/flags are initialized
    // on three release edges before a fresh transfer can be accepted.
    always @(posedge wr_clk_i)
        if (wr_valid_i && !full_q) mem[wr_bin_q[ADDR_BITS-1:0]] <= wr_data_i;
    always @(posedge rd_clk_i)
        if (!empty_q && (!out_valid_q || rd_ready_i))
            rd_data_o <= mem[rd_bin_q[ADDR_BITS-1:0]];

`ifdef RV64_PIXEL_FIFO_FORMAL
`include "formal/rv64/r99_pixel_fifo_properties.svh"
`endif
endmodule
