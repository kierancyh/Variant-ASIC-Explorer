# ~/ll_designs/ll_policy/constraints.sdc
create_clock -name clk -period $::env(CLOCK_PERIOD) [get_ports clk]
set_clock_uncertainty 0.10 [get_clocks clk]
set_false_path -from [get_ports clk]

# Minimal IO/electrical modelling for OpenROAD repair/signoff.
# Exclude clk from generic data-input constraints.
set DATA_INPUTS [remove_from_collection [all_inputs] [get_ports clk]]

# Give primary inputs a realistic driver instead of leaving them unmodelled.
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_4 -pin X $DATA_INPUTS

# Give STA a simple IO timing model. The design has huge internal slack,
# so this should not create setup/hold pressure; it just removes unconstrained IO warnings.
set_input_delay 0.50 -clock [get_clocks clk] $DATA_INPUTS
set_output_delay 0.50 -clock [get_clocks clk] [all_outputs]

# Give output ports an explicit load for signoff and resizer modelling.
set_load 0.020 [all_outputs]

# Ask repair to aim below the slow-corner 1.5 ns library transition limit.
# This is intentionally mild; do not add max_fanout/max_cap yet.
set_max_transition 1.30 [current_design]