# This file records the three slot replacements made in the enclosing
# Network.srcs/constrs_1/new/Network.xdc. It is a reviewable patch/reference;
# the active XDC is outside this inner Next186 repository.
# Total ILA width remains 200 bits.
#
# probe10, 24 bits: dbg_opl3_probe24
#   [23:16] internal OPL3 Z80 address low byte
#   [15:6]  command FIFO qdata[9:0] = {port_addr[1:0], data[7:0]}
#   [5:2]   channel_active[3:0]
#   [1]     FIFO qempty
#   [0]     sequencer ready
# probe15, 1 bit: dbg_opl3_hit = any channel sample-hit pulse
# probe19, 8 bits:
#   {OPL3_PORT, outer WR, outer IORQ, CPU_CE,
#    internal Z80 IORQ, internal Z80 WR, reset_done, LED0_active}
#
# The retired VGA connections were dbg_vga_ramaddr_at_ack[23:0], the duplicate
# dbg_vga_ack_pulse, and dbg_vga_cdc_at_wr[7:0].

set_property port_width 24 [get_debug_ports u_ila_0/probe10]
connect_debug_port u_ila_0/probe10 [get_nets [list \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[0]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[1]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[2]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[3]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[4]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[5]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[6]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[7]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[8]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[9]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[10]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[11]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[12]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[13]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[14]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[15]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[16]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[17]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[18]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[19]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[20]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[21]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[22]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe24[23]}]]

set_property port_width 1 [get_debug_ports u_ila_0/probe15]
connect_debug_port u_ila_0/probe15 [get_nets [list Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_hit]]

set_property port_width 8 [get_debug_ports u_ila_0/probe19]
connect_debug_port u_ila_0/probe19 [get_nets [list \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe8[0]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe8[1]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe8[2]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe8[3]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe8[4]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe8[5]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe8[6]} \
  {Network_i/top_zynq7010_0/inst/u_Next186/sys_inst/dbg_opl3_probe8[7]}]]
