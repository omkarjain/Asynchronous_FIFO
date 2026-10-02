## constraints.xdc
## Timing constraints for async_fifo.v
##
## NOTE: port names below assume wr_clk / rd_clk / wr_rst / rd_rst as the
## write- and read-domain clock/reset. Rename to match your top-level ports
## if they differ.

## ---------------------------------------------------------------
## Primary clocks
## ---------------------------------------------------------------
## Adjust periods (ns) to your actual clock frequencies.
create_clock -name wr_clk -period 10.000 [get_ports wr_clk]
create_clock -name rd_clk -period 7.000  [get_ports rd_clk]

## ---------------------------------------------------------------
## Clock domain crossing constraints
## ---------------------------------------------------------------
## The two 2-flop gray-code synchronizers are the only legal paths between
## wr_clk and rd_clk. Since gray-coded pointers only ever change by one bit
## at a time, a false path (rather than a tight max-delay) is the standard,
## correct way to constrain them — the synchronizer's job is exactly to
## resolve metastability across this boundary, and timing analysis across
## it is meaningless without a matching false_path.

## Write pointer (gray) -> synchronized into rd_clk domain
set_false_path -from [get_clocks wr_clk] -to [get_clocks rd_clk]

## Read pointer (gray) -> synchronized into wr_clk domain
set_false_path -from [get_clocks rd_clk] -to [get_clocks wr_clk]

## If your synchronizer registers have identifiable names/hierarchy
## (e.g. u_wr2rd_sync/sync_ff*, u_rd2wr_sync/sync_ff*), you can tighten
## the above to just those paths instead of a blanket clock-to-clock
## false path, e.g.:
##
## set_false_path -from [get_cells u_wr2rd_sync/sync_ff_reg[*]] \
##                 -to   [get_cells u_wr2rd_sync/sync_ff2_reg[*]]

## ---------------------------------------------------------------
## Async reset — treat as false path if resets are asynchronous
## and separately synchronized per-domain
## ---------------------------------------------------------------
# set_false_path -from [get_ports wr_rst]
# set_false_path -from [get_ports rd_rst]

## ---------------------------------------------------------------
## Input/output delay placeholders — fill in once this is integrated
## into a larger design or hooked to real I/O timing.
## ---------------------------------------------------------------
# set_input_delay  -clock wr_clk 2.000 [get_ports {din wr_en}]
# set_output_delay -clock rd_clk 2.000 [get_ports {dout}]
