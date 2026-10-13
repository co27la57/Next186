set_param general.maxThreads 8
open_project {D:/Xilinx/workspace/Next186/Network/Network.xpr}
reset_run Network_top_zynq7010_0_0_synth_1
launch_runs Network_top_zynq7010_0_0_synth_1 -jobs 8
wait_on_run Network_top_zynq7010_0_0_synth_1
if {[get_property STATUS [get_runs Network_top_zynq7010_0_0_synth_1]] ne "synth_design Complete!"} { exit 2 }
reset_run synth_1
reset_run impl_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} { exit 3 }
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} { exit 4 }
file copy -force {D:/Xilinx/workspace/Next186/Network/Network.runs/impl_1/Network_wrapper.bit} {D:/Xilinx/workspace/Next186/Network/Network.srcs/sources_1/imports/sim/run/Network_wrapper_vga_probe_20261014.bit}
file copy -force {D:/Xilinx/workspace/Next186/Network/Network.runs/impl_1/Network_wrapper.ltx} {D:/Xilinx/workspace/Next186/Network/Network.srcs/sources_1/imports/sim/run/Network_wrapper_vga_probe_20261014.ltx}
close_project
