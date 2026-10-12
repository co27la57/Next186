set here [file normalize [pwd]]
read_verilog -sv [file join $here .tmp_opl3_synth.v]
synth_design -top opl3_mem -part xc7z010clg400-1 -mode out_of_context
report_utilization -file [file join $here opl3_mem_utilization.rpt]
report_timing_summary -file [file join $here opl3_mem_timing.rpt]
exit
