set_param general.maxThreads 8
open_project {D:/Xilinx/workspace/Next186/Network/Network.xpr}
reset_run Network_top_zynq7010_0_0_synth_1
launch_runs Network_top_zynq7010_0_0_synth_1 -jobs 8
wait_on_run Network_top_zynq7010_0_0_synth_1
puts "child_status=[get_property STATUS [get_runs Network_top_zynq7010_0_0_synth_1]]"
close_project
