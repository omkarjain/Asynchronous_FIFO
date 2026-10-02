# Makefile for async_fifo — runs the self-checking testbench with Icarus Verilog.
# Requires: iverilog, vvp  (Ubuntu/Debian: sudo apt install iverilog)
#           gtkwave        (optional, for viewing the .vcd)  sudo apt install gtkwave

TOP      := tb_async_fifo
SRC      := async_fifo.v tb_async_fifo.v
BUILD    := sim_build
OUT      := $(BUILD)/$(TOP).vvp
VCD      := async_fifo.vcd

.PHONY: all sim wave clean lint

all: sim

$(BUILD):
	mkdir -p $(BUILD)

# Compile + elaborate
$(OUT): $(SRC) | $(BUILD)
	iverilog -g2012 -o $(OUT) $(SRC)

# Run the simulation (testbench is self-checking; non-zero vvp exit isn't
# automatic on error, so watch console output for PASS/FAIL / $fatal messages)
sim: $(OUT)
	vvp $(OUT)

# Open the waveform in GTKWave, using the saved signal layout if present
wave: $(VCD)
	gtkwave $(VCD) $(if $(wildcard async_fifo.gtkw),async_fifo.gtkw)

# Basic lint pass (syntax/elaboration only, no simulation)
lint: $(SRC)
	iverilog -g2012 -t null $(SRC)

clean:
	rm -rf $(BUILD)
	rm -f $(VCD)
