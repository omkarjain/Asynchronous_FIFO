//=============================================================================
// tb_async_fifo.v
//
// Self-checking testbench for async_fifo.v
//
// - Two independent, unsynchronized clocks: wclk = 10ns period,
//   rclk = 8.5ns period.
// - Constrained-random write/read activity (randomly throttled, not
//   driven every cycle, so full/empty get exercised too).
// - A scoreboard (simple FIFO reference queue) tracks what the DUT
//   SHOULD output and compares it against what it actually outputs,
//   on every accepted read, flagging any mismatch immediately.
// - Runs NUM_TRANSACTIONS writes and the same number of reads, then
//   reports PASS/FAIL.
//=============================================================================

`timescale 1ns/1ps

module tb_async_fifo;

    //-------------------------------------------------------------------
    // Parameters
    //-------------------------------------------------------------------
    parameter DATASIZE         = 8;
    parameter ADDRSIZE         = 4;           // FIFO depth = 2^4 = 16
    parameter NUM_TRANSACTIONS = 500;
    parameter TIMEOUT_NS       = 200000;

    //-------------------------------------------------------------------
    // DUT connections
    //-------------------------------------------------------------------
    reg                  wclk;
    reg                  rclk;
    reg                  wrst_n;
    reg                  rrst_n;

    reg                  winc;
    reg  [DATASIZE-1:0]  wdata;
    wire                 wfull;

    reg                  rinc;
    wire [DATASIZE-1:0]  rdata;
    wire                 rempty;

    //-------------------------------------------------------------------
    // Scoreboard state
    //-------------------------------------------------------------------
    reg [DATASIZE-1:0] sb_queue [0:2*NUM_TRANSACTIONS];
    integer sb_wr_idx;
    integer sb_rd_idx;

    integer write_count;
    integer read_count;
    integer check_count;
    integer error_count;

    //-------------------------------------------------------------------
    // DUT instance
    //-------------------------------------------------------------------
    async_fifo #(
        .DATASIZE (DATASIZE),
        .ADDRSIZE (ADDRSIZE)
    ) dut (
        .wclk   (wclk),
        .wrst_n (wrst_n),
        .winc   (winc),
        .wdata  (wdata),
        .wfull  (wfull),

        .rclk   (rclk),
        .rrst_n (rrst_n),
        .rinc   (rinc),
        .rdata  (rdata),
        .rempty (rempty)
    );

    //-------------------------------------------------------------------
    // Clock generation: two unrelated, asynchronous clocks
    //-------------------------------------------------------------------
    initial wclk = 1'b0;
    always  #5.000 wclk = ~wclk;     // 10.0 ns period  -> 100 MHz

    initial rclk = 1'b0;
    always  #4.250 rclk = ~rclk;     // 8.5  ns period  -> ~117.6 MHz

    //-------------------------------------------------------------------
    // Waveform dump
    //-------------------------------------------------------------------
    initial begin
        $dumpfile("async_fifo.vcd");
        $dumpvars(0, tb_async_fifo);
    end

    //-------------------------------------------------------------------
    // Reset generation (each domain resets on its own clock)
    //-------------------------------------------------------------------
    initial begin
        wrst_n      = 1'b0;
        rrst_n      = 1'b0;
        winc        = 1'b0;
        rinc        = 1'b0;
        wdata       = {DATASIZE{1'b0}};
        sb_wr_idx   = 0;
        sb_rd_idx   = 0;
        write_count = 0;
        read_count  = 0;
        check_count = 0;
        error_count = 0;

        repeat (5) @(posedge wclk);
        wrst_n = 1'b1;

        repeat (5) @(posedge rclk);
        rrst_n = 1'b1;
    end

    //-------------------------------------------------------------------
    // Write process (wclk domain): constrained-random writes
    //
    // RACE CONDITION HISTORY (kept here deliberately -- see
    // docs/design_notes.md for the full writeup):
    //
    //   v1: drove winc/wdata with BLOCKING assignments exactly at
    //       posedge wclk. This raced against the DUT's own nonblocking
    //       updates at the identical edge -- a classic testbench/DUT
    //       race whose outcome depends on simulator block-evaluation
    //       order. Result: ~500 corrupted comparisons out of 521.
    //
    //   v2: switched winc/wdata to NONBLOCKING assignments at posedge
    //       wclk to remove that race. This fixed the same-edge race,
    //       but introduced a subtler bug: it added an extra one-cycle
    //       pipeline stage between "decide to write" and "write takes
    //       effect". Right at the full boundary, the DUT's own
    //       (wclken && !wfull) guard could silently drop a write the
    //       testbench had already committed to in its scoreboard,
    //       because the testbench's "not full" judgment was one cycle
    //       stale relative to the write that *caused* fullness. This
    //       dropped exactly 4 of 500 writes and desynced the scoreboard
    //       from word ~336 onward (152 mismatches).
    //
    //   v3 (current): decide and drive winc/wdata with a small delta
    //       delay (#1) AFTER the clock edge, using blocking assignment.
    //       By the time the testbench reads wfull and drives winc, the
    //       DUT's nonblocking updates for this edge have already
    //       settled, and the new winc/wdata values have a full cycle
    //       of setup margin before the next edge. No same-edge race,
    //       no extra pipeline stage. Verified bit-exact against a
    //       separately logged write/read address+data trace (zero
    //       drops, zero reordering, across 500/500 transactions)
    //       before being folded into this scoreboard-checked version.
    //-------------------------------------------------------------------
    initial begin : wr_proc
        reg [DATASIZE-1:0] wdata_next;
        reg                do_write;

        winc  = 1'b0;
        wdata = {DATASIZE{1'b0}};
        @(posedge wrst_n);

        forever begin
            @(posedge wclk);
            #1; // let the DUT's nonblocking updates for this edge settle first

            if (write_count < NUM_TRANSACTIONS) begin
                do_write = (!wfull) && ($urandom_range(0, 3) != 0); // ~75% duty cycle

                if (do_write) begin
                    wdata_next = $urandom_range(0, (1 << DATASIZE) - 1);
                    winc  = 1'b1;
                    wdata = wdata_next;

                    // record what we expect to read back, in order
                    sb_queue[sb_wr_idx] = wdata_next;
                    sb_wr_idx   = sb_wr_idx + 1;
                    write_count = write_count + 1;
                end else begin
                    winc = 1'b0;
                end
            end else begin
                winc = 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------
    // Read process (rclk domain): constrained-random reads
    // (same delta-delay reasoning as the write process above)
    //-------------------------------------------------------------------
    initial begin : rd_proc
        reg do_read;

        rinc = 1'b0;
        @(posedge rrst_n);

        forever begin
            @(posedge rclk);
            #1;

            if (read_count < NUM_TRANSACTIONS) begin
                do_read = (!rempty) && ($urandom_range(0, 2) != 0); // ~66% duty cycle

                if (do_read) begin
                    rinc = 1'b1;
                    read_count = read_count + 1;
                end else begin
                    rinc = 1'b0;
                end
            end else begin
                rinc = 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------
    // Scoreboard checker (rclk domain)
    //
    // NOTE: this block reads 'rdata' in the same always block, at the
    // same posedge, that the DUT's pointer registers update on. Because
    // Verilog nonblocking assignments (used for all DUT pointer state)
    // are deferred to the NBA region, this block's blocking read of
    // 'rdata' in the Active region still observes the PRE-edge value --
    // i.e. exactly the data word that was sitting on the bus for the
    // cycle being consumed by this rinc pulse. Getting this ordering
    // wrong is a classic source of testbench/DUT race conditions in
    // CDC verification (see docs/design_notes.md).
    //-------------------------------------------------------------------
    always @(posedge rclk) begin
        if (rrst_n && rinc && !rempty) begin
            check_count = check_count + 1;
            if (rdata !== sb_queue[sb_rd_idx]) begin
                error_count = error_count + 1;
                $display("ERROR @%0t ns: index %0d  expected=0x%0h  got=0x%0h",
                          $time, sb_rd_idx, sb_queue[sb_rd_idx], rdata);
            end
            sb_rd_idx = sb_rd_idx + 1;
        end
    end

    //-------------------------------------------------------------------
    // End-of-test: wait for both write and read counts to hit target,
    // give a short drain margin, then report.
    //-------------------------------------------------------------------
    initial begin
        fork
            wait (write_count >= NUM_TRANSACTIONS);
            wait (read_count  >= NUM_TRANSACTIONS);
        join

        repeat (20) @(posedge rclk);   // let any trailing reads settle

        $display("=====================================================");
        $display(" async_fifo self-checking testbench complete");
        $display(" Writes performed  : %0d", write_count);
        $display(" Reads performed   : %0d", read_count);
        $display(" Words checked     : %0d", check_count);
        $display(" Errors detected   : %0d", error_count);
        if (error_count == 0)
            $display(" RESULT: PASS - all %0d words verified correctly.", check_count);
        else
            $display(" RESULT: FAIL - %0d mismatch(es) detected.", error_count);
        $display("=====================================================");
        $finish;
    end

    //-------------------------------------------------------------------
    // Safety watchdog, in case of an unexpected deadlock
    //-------------------------------------------------------------------
    initial begin
        #TIMEOUT_NS;
        $display("ERROR: TIMEOUT - simulation did not complete within %0d ns", TIMEOUT_NS);
        $display("RESULT: FAIL - watchdog timeout");
        $finish;
    end

endmodule
