set here [file normalize [pwd]]
read_verilog -sv [file join $here .tmp_opl3_xpm.v]
synth_design -top opl3_mem_xpm -part xc7z010clg400-1 -mode out_of_context
report_utilization -file [file join $here opl3_xpm_dist_utilization.rpt]
exit
