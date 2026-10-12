set here [file normalize [pwd]]
read_verilog -sv [file join $here Next186_BlackBoxes.v]
synth_design -top opl3_mem -part xc7z010clg400-1 -mode out_of_context
report_utilization -file [file join $here opl3_bb_utilization.rpt]
exit
