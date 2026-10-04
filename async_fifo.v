//=============================================================================
// async_fifo.v
//
// Asynchronous (dual-clock) FIFO, Cummings-style design
// ("Simulation and Synthesis Techniques for Asynchronous FIFO Design",
//  SNUG 2002 — Clifford E. Cummings)
//
// Top module : async_fifo
// Submodules : sync_r2w      - 2-flop synchronizer, read ptr  -> write domain
//              sync_w2r      - 2-flop synchronizer, write ptr -> read domain
//              fifo_mem      - dual-port RAM (1 write port, 1 read port)
//              rptr_empty    - read pointer (binary+gray) + empty flag
//              wptr_full     - write pointer (binary+gray) + full flag
//
// DATASIZE : width of each FIFO entry, in bits
// ADDRSIZE : number of address bits -> FIFO depth = 2^ADDRSIZE
//=============================================================================

`timescale 1ns/1ps

//-----------------------------------------------------------------------
// sync_r2w: synchronizes the gray-coded READ pointer into the WRITE
// clock domain, so the write side can safely compute "full".
//-----------------------------------------------------------------------
module sync_r2w #(parameter ADDRSIZE = 4)
(
    output reg [ADDRSIZE:0] rq2_rptr,   // read ptr, synced into wclk domain
    input      [ADDRSIZE:0] rptr,       // read ptr, gray code, rclk domain
    input                   wclk,
    input                   wrst_n
);
    reg [ADDRSIZE:0] rq1_rptr;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n)
            {rq2_rptr, rq1_rptr} <= 0;
        else
            {rq2_rptr, rq1_rptr} <= {rq1_rptr, rptr};
    end
endmodule


//-----------------------------------------------------------------------
// sync_w2r: synchronizes the gray-coded WRITE pointer into the READ
// clock domain, so the read side can safely compute "empty".
//-----------------------------------------------------------------------
module sync_w2r #(parameter ADDRSIZE = 4)
(
    output reg [ADDRSIZE:0] wq2_wptr,   // write ptr, synced into rclk domain
    input      [ADDRSIZE:0] wptr,       // write ptr, gray code, wclk domain
    input                   rclk,
    input                   rrst_n
);
    reg [ADDRSIZE:0] wq1_wptr;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n)
            {wq2_wptr, wq1_wptr} <= 0;
        else
            {wq2_wptr, wq1_wptr} <= {wq1_wptr, wptr};
    end
endmodule


//-----------------------------------------------------------------------
// fifo_mem: dual-port memory. Write port clocked by wclk, read port is
// combinational (address-register + async read), as is standard for
// this style of FIFO.
//-----------------------------------------------------------------------
module fifo_mem #(parameter DATASIZE = 8, ADDRSIZE = 4)
(
    input      [DATASIZE-1:0] wdata,
    input      [ADDRSIZE-1:0] waddr,
    input      [ADDRSIZE-1:0] raddr,
    input                     wclken,
    input                     wfull,
    input                     wclk,
    output     [DATASIZE-1:0] rdata
);
    localparam DEPTH = 1 << ADDRSIZE;

    reg [DATASIZE-1:0] mem [0:DEPTH-1];

    assign rdata = mem[raddr];

    always @(posedge wclk)
        if (wclken && !wfull)
            mem[waddr] <= wdata;
endmodule


//-----------------------------------------------------------------------
// rptr_empty: read-domain pointer logic. Maintains a binary pointer
// (for RAM addressing) and its gray-coded twin (for the CDC crossing),
// and derives the "empty" flag by comparing the next gray read pointer
// against the synchronized write pointer.
//-----------------------------------------------------------------------
module rptr_empty #(parameter ADDRSIZE = 4)
(
    output reg                rempty,
    output     [ADDRSIZE-1:0] raddr,
    output reg [ADDRSIZE:0]   rptr,      // gray-coded read pointer (exported)
    input      [ADDRSIZE:0]   rq2_wptr,  // synced write pointer, gray code
    input                     rinc,
    input                     rclk,
    input                     rrst_n
);
    reg  [ADDRSIZE:0] rbin;
    wire [ADDRSIZE:0] rgraynext, rbinnext;
    wire               rempty_val;

    // binary + gray pointer register
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n)
            {rbin, rptr} <= 0;
        else
            {rbin, rptr} <= {rbinnext, rgraynext};
    end

    assign raddr = rbin[ADDRSIZE-1:0];

    assign rbinnext  = rbin + (rinc & ~rempty);
    assign rgraynext = (rbinnext >> 1) ^ rbinnext;   // binary -> gray

    // FIFO is empty when the next read pointer would equal the
    // synchronized (and therefore slightly stale) write pointer.
    assign rempty_val = (rgraynext == rq2_wptr);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n)
            rempty <= 1'b1;
        else
            rempty <= rempty_val;
    end
endmodule


//-----------------------------------------------------------------------
// wptr_full: write-domain pointer logic. Mirrors rptr_empty, but
// derives "full" using the classic Cummings comparison: next gray
// write pointer vs. synchronized read pointer with its top two bits
// inverted (this is what distinguishes "completely full" from
// "completely empty" when both pointers wrap to the same address).
//-----------------------------------------------------------------------
module wptr_full #(parameter ADDRSIZE = 4)
(
    output reg                wfull,
    output     [ADDRSIZE-1:0] waddr,
    output reg [ADDRSIZE:0]   wptr,      // gray-coded write pointer (exported)
    input      [ADDRSIZE:0]   wq2_rptr,  // synced read pointer, gray code
    input                     winc,
    input                     wclk,
    input                     wrst_n
);
    reg  [ADDRSIZE:0] wbin;
    wire [ADDRSIZE:0] wgraynext, wbinnext;
    wire               wfull_val;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n)
            {wbin, wptr} <= 0;
        else
            {wbin, wptr} <= {wbinnext, wgraynext};
    end

    assign waddr = wbin[ADDRSIZE-1:0];

    assign wbinnext  = wbin + (winc & ~wfull);
    assign wgraynext = (wbinnext >> 1) ^ wbinnext;   // binary -> gray

    assign wfull_val = (wgraynext == {~wq2_rptr[ADDRSIZE:ADDRSIZE-1],
                                        wq2_rptr[ADDRSIZE-2:0]});

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n)
            wfull <= 1'b0;
        else
            wfull <= wfull_val;
    end
endmodule


//-----------------------------------------------------------------------
// async_fifo: top-level module wiring the five submodules together.
//-----------------------------------------------------------------------
module async_fifo #(parameter DATASIZE = 8, ADDRSIZE = 4)
(
    // write side (wclk domain)
    input                   wclk,
    input                   wrst_n,
    input                   winc,
    input  [DATASIZE-1:0]   wdata,
    output                  wfull,

    // read side (rclk domain)
    input                   rclk,
    input                   rrst_n,
    input                   rinc,
    output [DATASIZE-1:0]   rdata,
    output                  rempty
);

    wire [ADDRSIZE:0]   wptr, rptr;         // gray-coded pointers, native domain
    wire [ADDRSIZE:0]   wq2_rptr, rq2_wptr; // gray-coded pointers, synced domain
    wire [ADDRSIZE-1:0] waddr, raddr;

    // CDC synchronizers
    sync_r2w #(.ADDRSIZE(ADDRSIZE)) sync_r2w_inst (
        .rq2_rptr (wq2_rptr),
        .rptr     (rptr),
        .wclk     (wclk),
        .wrst_n   (wrst_n)
    );

    sync_w2r #(.ADDRSIZE(ADDRSIZE)) sync_w2r_inst (
        .wq2_wptr (rq2_wptr),
        .wptr     (wptr),
        .rclk     (rclk),
        .rrst_n   (rrst_n)
    );

    // storage
    fifo_mem #(.DATASIZE(DATASIZE), .ADDRSIZE(ADDRSIZE)) fifo_mem_inst (
        .wdata  (wdata),
        .waddr  (waddr),
        .raddr  (raddr),
        .wclken (winc),
        .wfull  (wfull),
        .wclk   (wclk),
        .rdata  (rdata)
    );

    // read-domain pointer + empty flag
    rptr_empty #(.ADDRSIZE(ADDRSIZE)) rptr_empty_inst (
        .rempty   (rempty),
        .raddr    (raddr),
        .rptr     (rptr),
        .rq2_wptr (rq2_wptr),
        .rinc     (rinc),
        .rclk     (rclk),
        .rrst_n   (rrst_n)
    );

    // write-domain pointer + full flag
    wptr_full #(.ADDRSIZE(ADDRSIZE)) wptr_full_inst (
        .wfull    (wfull),
        .waddr    (waddr),
        .wptr     (wptr),
        .wq2_rptr (wq2_rptr),
        .winc     (winc),
        .wclk     (wclk),
        .wrst_n   (wrst_n)
    );

endmodule
