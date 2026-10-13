set bit {D:/Xilinx/workspace/Next186/Network/Network.srcs/sources_1/imports/sim/run/Network_wrapper_vga_probe_20261014.bit}
set ltx {D:/Xilinx/workspace/Next186/Network/Network.srcs/sources_1/imports/sim/run/Network_wrapper_vga_probe_20261014.ltx}
set backup {D:/Xilinx/workspace/Next186/Network/Network.hw/backup}
set desired "localhost:3121/xilinx_tcf/Digilent/210299129354"
open_hw_manager
connect_hw_server -url localhost:3121
set ts [get_hw_targets -quiet $desired]
if {[llength $ts] != 1} { error "Digilent target missing" }
open_hw_target [lindex $ts 0]
set dev [get_hw_devices xc7z010_1]
current_hw_device $dev
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device -update_hw_probes true $dev
set ilas [get_hw_ilas -of_objects $dev -filter {CELL_NAME == u_ila_0}]
set ila [lindex $ilas 0]
set payload [lindex [get_hw_probes -of_objects $ila -filter {NAME =~ *dbg_vga_probe*}] 0]
set trig [lindex [get_hw_probes -of_objects $ila -filter {NAME =~ *dbg_vga_trigger}] 0]
set p [string repeat x 199]
# source dbg_vga_rowreset_evt is payload bit 54; in the MSB-first compare
# string its position is 198-54 = 144.
set p [string replace $p 144 144 1]
# Require the frame-start mode snapshot to be 13h graphics (0x30), so a
# normal text-mode row reset cannot consume the trigger before the game starts.
set p [string replace $p 166 173 00110000]
set_property TRIGGER_COMPARE_VALUE "eq199'b$p" $payload
set_property TRIGGER_COMPARE_VALUE "eq1'bX" $trig
set_property CONTROL.TRIGGER_POSITION 512 $ila
for {set i 0} {$i < 3} {incr i} {
    run_hw_ila $ila
    puts "ARMED_ROWRESET:$i"
    wait_on_hw_ila -timeout 30 $ila
    set d [upload_hw_ila_data $ila]
    set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
    set out "$backup/ila_vga_graphics_rowreset_${i}_${stamp}"
    write_hw_ila_data -force "$out.ila" $d
    puts "SAVED_ROWRESET:$out.ila"
}
close_hw_target
disconnect_hw_server
close_hw_manager
exit
