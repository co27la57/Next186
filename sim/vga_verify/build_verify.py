"""Audited extension of WorkBuddy's bench; never edit production RTL here."""
from pathlib import Path
import os
import sys
import shutil

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = HERE / "run"
OUT.mkdir(exist_ok=True)

source = (HERE / "baseline_vga_path.v").read_text(encoding="utf-8")
# Snapshot the WorkBuddy input: all experiment edits below affect this generated copy.
(OUT / "workbuddy_input.v").write_text(source, encoding="utf-8")

def replace(old, new):
    global source
    if source.count(old) != 1:
        raise RuntimeError("Bench anchor changed: " + old)
    source = source.replace(old, new)

replace("input  wire        CLK_50MHZ,",
"""input wire CLK_50MHZ, pixel_clock,
    input wire [31:0] stall_seed,
    input wire [7:0] max_stall,
    input wire [7:0] fix_flags,
    input wire cache_read,
    input wire [23:0] cache_address,
    output wire o_fifo_rst, o_wr_busy, o_rd_busy, o_full, o_empty,
    output wire o_fifo_wr, o_bridge_busy,
    output wire [10:0] o_level,
    output wire [15:0] o_wdata,
    output wire [23:0] o_data_addr,
    output wire [1:0] o_ack,
    output wire [31:0] o_q,
    output wire [3:0] o_exline, o_bridge_state,
    output wire [8:0] o_fetch_row,
    output wire [2:0] o_text,
    output wire o_endscan, o_vrdon,
""")
replace("wire        clk_25 = clk_25_div;", "wire clk_25 = pixel_clock;")
replace("max_read <= &sdraddr[7:3] ? ~sdraddr[2:0] : 3'b111;", """max_read <= fix_flags[6] ? (&sdraddr[8:4] ? ~sdraddr[3:1] : 3'd7)
                                : (&sdraddr[7:3] ? ~sdraddr[2:0] : 3'd7);""")
replace("if (!crw && sys_rd_data_valid) col_counter <= col_counter - 1'b1;",
        "if (!crw && sys_rd_data_valid && (!fix_flags[5] || !col_counter[4])) col_counter <= col_counter - 1'b1;")
# Production DAC_SRAM adds one synchronous palette stage after the font/EGA
# mux. The original visual model omitted it, shifting characters by one pixel.
replace("reg  [3:0]  exline = 4'b0000;", "reg [3:0] exline=0; reg [3:0] palette_index=0;")
replace("VGA_R <= sdon ? {6{idx[0]}}", "palette_index<=idx;\n      VGA_R <= sdon ? {6{palette_index[0]}}")
replace("VGA_G <= sdon ? {6{idx[1]}}", "VGA_G <= sdon ? {6{palette_index[1]}}")
replace("VGA_B <= sdon ? {6{idx[2]}}", "VGA_B <= sdon ? {6{palette_index[2]}}")
replace("if (RTCDIVEND) RTCDIV25 <= 0;", """if(vblnk && fix_flags[1]) begin
      vga13[1]<=vga13[0]; vgatext[1]<=vgatext[0]; v240[1]<=v240[0];
      planar[1]<=planar[0]; half[1]<=half[0];
    end
    if (RTCDIVEND) RTCDIV25 <= 0;""")
replace("wire        ddr_rd = 1'b0, ddr_wr = 1'b0;", "wire ddr_rd=cache_read, ddr_wr=0;")
replace("wire [8:0]  memmap_mux = 0;", "wire [8:0] memmap_mux=cache_address[23:15];")
replace("wire [9:0]  cache_hi_addr = 0;", "wire [9:0] cache_hi_addr=cache_address[14:5];")
replace("else                     cache_cmd_done <= 1'b1;", "else if(cache_line_start) cache_cmd_done<=1;")
replace("sys_cmd_ack_d1 <= sys_cmd_ack;", """sys_cmd_ack_d1 <= sys_cmd_ack;
    cache_line_start <= sys_cmd_ack!=0 && sys_cmd_ack_d1==0 &&
                        (sys_cmd_ack==1 || sys_cmd_ack==3);""")
# Reuse the actual cache presentation logic, rather than a second arbitration model.
production=(ROOT / "ddr_186.v").read_text(encoding="utf-8")
cq_start=production.index("\treg        cq_act")
cq_end=production.index("    assign ram_cmd",cq_start)
cq_logic=production[cq_start:cq_end]
replace("reg         cache_cmd_done = 1'b0;", "reg cache_cmd_done=0; reg cache_line_start=0;\n"+cq_logic)
replace("wire        vb_resync = (vb_win != 6'd0);", """wire vb_resync = fix_flags[0] ? rs_active : (vb_win != 0);
  localparam RS_RUN=0, RS_DRAIN=1, RS_RESET=2, RS_READY=3;
  reg [1:0] rs_state=RS_RUN;
  reg [6:0] rs_count=0;
  wire rs_active=(rs_state!=RS_RUN) || vb_rise;
  wire rs_reset=(rs_state==RS_RESET);
  always @(posedge clk_sdr) begin
    if (!rst_n || !fix_flags[0]) begin rs_state<=RS_RUN; rs_count<=0; end
    else case(rs_state)
      RS_RUN: if(vb_rise) begin rs_state<=RS_DRAIN; rs_count<=0; end
      // Stop at the actual command output. ACK is the current bridge transaction;
      // crw is only a retained transaction type and is never an idle condition.
      RS_DRAIN: begin
        if(sys_cmd_ack!=0 || sys_rd_data_valid) rs_count<=0;
        else if(rs_count==5) begin rs_state<=RS_RESET; rs_count<=0; end
        else rs_count<=rs_count+1'b1;
      end
      RS_RESET: if(rs_count==63) begin rs_state<=RS_READY; rs_count<=0; end
                else rs_count<=rs_count+1'b1;
      // XPM wr_rst_busy includes the round trip to the read reset domain.
      RS_READY: if(!fifo_rst && !o_wr_busy) rs_state<=RS_RUN;
    endcase
  end""")
replace("fifo_rst     <= vb_resync;", "fifo_rst <= fix_flags[0] ? rs_reset : vb_resync;")
replace("wire        fifo_wr = !crw && sys_rd_data_valid && !col_counter[4];",
        "wire fifo_wr = !crw && sys_rd_data_valid && !col_counter[4] && !(fix_flags[0] && rs_active);")
replace("wire [1:0]  ram_cmd   = cntrl0_user_command_register;",
        "wire [1:0] ram_cmd = fix_flags[0] && rs_active ? 2'b00 : (cq_act && cq_on) ? (cq_sp!=0 ? 2'b00 : cq_cmd) : cntrl0_user_command_register;")
replace("wire [23:0] ram_addr  = sdraddr;", "wire [23:0] ram_addr=(cq_act && cq_on) ? cq_addr : sdraddr;")
replace("wire        vrden = vrden_raw && !(cfg_rd_drop_last_tail && tail_last);", """reg [7:0] scan_reads=0;
  reg scan_active=0;
  wire [7:0] read_quota=(vgatext[1] || half[1]) ? 48 : (vga13[1] || planar[1]) ? 88 : 168;
  wire cadence=(vgatext[1] || half[1]) ? &hcount_pan[3:0] :
                 (vga13[1] || planar[1]) ? &hcount_pan[2:0] : &hcount_pan[1:0];
  wire vrden=(fix_flags[4] ? ((vrdon || scan_active) && scan_reads<read_quota && cadence) : vrden_raw)
              && !(cfg_rd_drop_last_tail && tail_last);
  always @(posedge clk_25) begin
    if(vblnk || hcount==799) begin scan_reads<=0; scan_active<=0; end
    else begin
      if(vrdon) scan_active<=1;
      if(vrden) scan_reads<=scan_reads+1'b1;
    end
  end""")
replace("vga_repln_count  <= 4'd0;", """vga_repln_count <= 0;
      if (fix_flags[1]) begin
        vga_ddr_row_count<=0; col_counter<=5'd16;
        vgatext[0]<=vgatextreq; vga13[0]<=vga13req; v240[0]<=1;
        planar[0]<=planarreq; half[0]<=halfreq; repln_graph[0]<=replnreq;
      end""")
replace("parameter integer FIFO_DEPTH16 = 512", "parameter integer FIFO_DEPTH16 = 1024")
replace(",\n    .ovf(fifo_ovf), .empty_o(fifo_empty), .underrun(fifo_underrun),\n    .wrptr_o(fifo_wrptr), .rdptr_o(fifo_rdptr)", "")
replace(".wrusedw(fifo_wr_used_words), .rst(fifo_rst)",
""".wrusedw(fifo_wr_used_words), .rst(fifo_rst),
    .wr_busy(o_wr_busy), .rd_busy(o_rd_busy),
    .full(o_full), .empty(o_empty), .level(o_level)""")
replace(".clk(clk_sdr), .ram_cmd(ram_cmd), .ram_addr(ram_addr),",
""".clk(clk_sdr), .rst_n(rst_n), .stall_seed(stall_seed),
    .max_stall(max_stall), .short_vga(fix_flags[6]), .busy(o_bridge_busy),
    .data_addr(o_data_addr), .state_debug(o_bridge_state),
    .ram_cmd(ram_cmd), .ram_addr(ram_addr),""")
replace("else                     cntrl0_user_command_register <= 2'b00;",
"""else                     cntrl0_user_command_register <= 2'b00;
    // Host prefill is a bench setup phase, not a simulated board reset.
    if (!rst_n) cntrl0_user_command_register <= 0;""")
replace("endmodule", """assign o_fifo_rst = fifo_rst;
  assign o_fifo_wr = fifo_wr;
  assign o_wdata = sys_DOUT;
  assign o_ack = sys_cmd_ack;
  assign o_q = fifo_dout32;
  assign o_exline = exline;
  assign o_fetch_row = vga_ddr_row_count;
  assign o_text = vgatext;
  assign o_endscan = s_vga_endscanline;
  assign o_vrdon = vrdon;
endmodule""")
(OUT / "vga_path.v").write_text(source, encoding="utf-8")
shutil.copyfile(ROOT / "font8x16.mem", OUT / "font8x16.mem")
sys.path.insert(0, str(ROOT / "sim"))
import build
original_run = build.run
def run_with_flags(cmd, **kwargs):
    if "--cc" in cmd:
        cmd += ["--timing", "-DONESPIN", "-DDISABLE_XPM_ASSERTIONS", "-Wno-PINMISSING"]
    elif "c++" in cmd:
        cmd = ["-std=c++20" if c == "-std=c++17" else c for c in cmd]
        cmd += [str(Path(build.VROOT) / "include/verilated_timing.cpp")]
    return original_run(cmd, **kwargs)
build.run = run_with_flags
xpm = Path("D:/Xilinx/2025.2/Vivado/data/ip/xpm")
files = [
    OUT / "vga_path.v", HERE / "bridge_model.v", HERE / "fifo_xpm.v",
    HERE / "vga_sg_model.v",
    HERE / "vga_font_model.v",
    xpm / "xpm_fifo/hdl/xpm_fifo.sv",
    xpm / "xpm_memory/hdl/xpm_memory.sv",
    xpm / "xpm_cdc/hdl/xpm_cdc.sv",
    HERE / "verify_main.cpp",
]
# Work in the workspace; reuse its already populated Zig caches.
os.environ.setdefault("ZIG_GLOBAL_CACHE_DIR", str(ROOT / "sim/run/opl3_led/zig-global"))
os.environ.setdefault("ZIG_LOCAL_CACHE_DIR", str(ROOT / "sim/run/opl3_led/zig-local"))
os.environ.setdefault("ZIG_LIB_DIR", str(Path(build.ZIG).parent / "lib"))
sys.argv = ["build.py", "--top", "vga_path", "--out", str(OUT)] + list(map(str, files))
build.main()
