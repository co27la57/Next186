# Usage: vivado ... -source capture_vga_20261014.tcl -tclargs program text
#        vivado ... -source capture_vga_20261014.tcl -tclargs capture graphics
set do_program [expr {[lindex $argv 0] eq "program"}]
set mode [lindex $argv 1]
if {$mode ni {text graphics}} { error "mode must be text or graphics" }
set root {D:/Xilinx/workspace/Next186/Network}
set bit "$root/Network.srcs/sources_1/imports/sim/run/Network_wrapper_vga_probe_20261014.bit"
set ltx "$root/Network.srcs/sources_1/imports/sim/run/Network_wrapper_vga_probe_20261014.ltx"
set backup "$root/Network.hw/backup"
set desired "localhost:3121/xilinx_tcf/Digilent/210299129354"
open_hw_manager
connect_hw_server -url localhost:3121
set ts [get_hw_targets -quiet $desired]
if {[llength $ts] != 1} { error "Expected the verified Digilent target $desired; found [get_hw_targets -quiet]" }
open_hw_target [lindex $ts 0]
set dev [get_hw_devices xc7z010_1]
if {[llength $dev] != 1 || [get_property PART $dev] ne "xc7z010"} { error "Expected xc7z010" }
current_hw_device $dev
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
if {$do_program} {
    set_property PROGRAM.FILE $bit $dev
    program_hw_devices $dev
    puts "PROGRAM_DONE:$bit"
    after 12000
}
refresh_hw_device -update_hw_probes true $dev
set ilas [get_hw_ilas -of_objects $dev -filter {CELL_NAME == u_ila_0}]
if {[llength $ilas] != 1} { error "Expected one u_ila_0; found $ilas" }
set ila [lindex $ilas 0]
set payload ""
set trigger ""
foreach p [get_hw_probes -of_objects $ila] {
    set name [get_property NAME $p]
    puts "HW_PROBE:$name"
    if {[string match *dbg_vga_probe* $name]} { set payload $p }
    if {[string match *dbg_vga_trigger $name]} { set trigger $p }
}
if {$payload eq "" || $trigger eq ""} { error "VGA packed payload/trigger missing" }
set_property CONTROL.TRIGGER_POSITION 128 $ila
set_property CONTROL.DATA_DEPTH 1024 $ila

proc capture_vga {ila payload trigger backup mode tag line horizontal} {
    # 199'b mask uses x for all untested fields. Require the actual live mode
    # as well as the requested scan position so a text capture cannot be
    # mislabelled as graphics following a fresh bitstream download.
    set pattern [string repeat x 199]
    set vertical [format %010b $line]
    set h [format %010b $horizontal]
    set pattern [string replace $pattern 71 80 $vertical]
    set pattern [string replace $pattern 81 90 $h]
    if {$mode eq "text"} { set textbits 11 } else { set textbits 00 }
    set pattern [string replace $pattern 95 96 $textbits]
    set_property TRIGGER_COMPARE_VALUE "eq1'bX" $trigger
    set_property TRIGGER_COMPARE_VALUE "eq199'b$pattern" $payload
    run_hw_ila $ila
    puts "ILA_ARMED:$mode/$tag vcount=$line hcount=$horizontal"
    wait_on_hw_ila -timeout 30 $ila
    set data [upload_hw_ila_data $ila]
    set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
    set out "$backup/ila_vga_${mode}_${tag}_${stamp}"
    write_hw_ila_data -force "$out.ila" $data
    write_hw_ila_data -force -csv_file "$out.csv" $data
    puts "ILA_SAVED:$out.ila"
}

foreach tag {fs_a fs_b fs_c} {
    capture_vga $ila $payload $trigger $backup $mode $tag 0 0
}
foreach line {1 2 3 4} {
    capture_vga $ila $payload $trigger $backup $mode "line$line" $line 0
}
close_hw_target
disconnect_hw_server
close_hw_manager
exit
