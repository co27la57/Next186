# Run from sources_1/imports. Offline OPL3 synthesis only; no project/JTAG changes.
set source_dir [file normalize [file join [file dirname [info script]] ..]]
cd $source_dir
set out_dir [file join $source_dir sim run opl3_led_synth]
file mkdir $out_dir
# Keep Vivado's local Tcl app cache inside the writable workspace. On this
# machine the default user-data resolver occasionally truncates C:\ paths to
# a one-character filename before create_project.
set user_data [file join $source_dir sim run vivado_user_data]
file mkdir $user_data
set ::env(XILINX_LOCAL_USER_DATA) $user_data
create_project -in_memory -part xc7z010clg400-1
set_param general.maxThreads 8
set_property XPM_LIBRARIES {XPM_FIFO} [current_project]
read_verilog [list opl3.v opl3seq.v NextZ80CPU.v NextZ80ALU.v NextZ80Reg.v Next186_BlackBoxes.v]
synth_design -top opl3 -part xc7z010clg400-1 -mode out_of_context
create_clock -period 20.000 [get_ports clk]
create_clock -period 40.000 [get_ports cpu_clk]
report_utilization -file [file join $out_dir utilization.rpt]
report_timing_summary -file [file join $out_dir timing.rpt]
write_checkpoint -force [file join $out_dir opl3_led_synth.dcp]
puts "OPL3_LED_SYNTH_PASS"
exit 0
