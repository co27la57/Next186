"""Prepare a reviewable production patch; NEVER apply it to the checkout.

Matches sim flags=55: transaction fence, complete frame state, true base,
fixed line consumption, saturating acceptance counter. AXI stays unchanged.
"""
from pathlib import Path
import difflib
import hashlib
import json
import subprocess

ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
OUT=HERE / "candidate"
OUT.mkdir(exist_ok=True)
BASE="111904f"
original={name:subprocess.check_output(["git","show",BASE+":"+name],cwd=ROOT).decode("utf-8").replace("\r\n","\n")
          for name in ["ddr_186.v","Next186_BlackBoxes.v"]}
sources=dict(original)

def edit(name,old,new):
    if sources[name].count(old)!=1:
        raise RuntimeError("Production source anchor changed: "+old)
    sources[name]=sources[name].replace(old,new)

f="ddr_186.v"
edit(f,"\treg [5:0] vb_win  = 6'd0;", """    localparam [1:0] VGA_FS_RUN=0, VGA_FS_DRAIN=1,
                     VGA_FS_RESET=2, VGA_FS_READY=3;
    reg [1:0] vga_frame_state=VGA_FS_RUN;
    reg [6:0] vga_flush_count=0;
    wire vga_fifo_reset_busy;""")
edit(f,"\twire      vb_resync = (vb_win != 6'd0);", """    wire vb_resync=(vga_frame_state!=VGA_FS_RUN) || vb_rise;
    wire vga_fifo_reset_phase=(vga_frame_state==VGA_FS_RESET);""")
edit(f,"fifo_rst     <= vb_resync;", "fifo_rst <= vga_fifo_reset_phase;")
edit(f,".wrreq(!crw && sys_rd_data_valid && !col_counter[4]),",
     ".wrreq(!crw && sys_rd_data_valid && !col_counter[4] && !vb_resync),")
edit(f,"\t  .rst(fifo_rst)\n", "\t  .rst(fifo_rst),\n      .reset_busy(vga_fifo_reset_busy)\n")
edit(f,"\t\tif (vb_rise)            vb_win <= 6'd63;\n\t\telse if (vb_win != 0)   vb_win <= vb_win - 1'b1;", """        // Retire the current bridge transaction before resetting the FIFO.
        // crw retains a transaction TYPE; it is deliberately not an idle test.
        if (!clk_sys_locked) begin
            vga_frame_state<=VGA_FS_DRAIN;
            vga_flush_count<=0;
        end else case(vga_frame_state)
            VGA_FS_RUN: if(vb_rise) begin
                vga_frame_state<=VGA_FS_DRAIN;
                vga_flush_count<=0;
            end
            VGA_FS_DRAIN: begin
                if(sys_cmd_ack!=0 || sys_rd_data_valid) vga_flush_count<=0;
                else if(vga_flush_count==5) begin
                    vga_frame_state<=VGA_FS_RESET;
                    vga_flush_count<=0;
                end else vga_flush_count<=vga_flush_count+1'b1;
            end
            VGA_FS_RESET: begin
                if(vga_flush_count==63) begin
                    vga_frame_state<=VGA_FS_READY;
                    vga_flush_count<=0;
                end else vga_flush_count<=vga_flush_count+1'b1;
            end
            // XPM write reset busy includes its read-domain reset handshake.
            VGA_FS_READY: if(!fifo_rst && !vga_fifo_reset_busy)
                vga_frame_state<=VGA_FS_RUN;
            default: vga_frame_state<=VGA_FS_DRAIN;
        endcase""")
edit(f,"vga_ddr_row_col + vga_lnbytecount - 5'd8, 1'b0}",
     "vga_ddr_row_col + vga_lnbytecount, 1'b0}")
edit(f,"if(!crw && sys_rd_data_valid) col_counter <= col_counter - 1'b1;",
     "if(!crw && sys_rd_data_valid && !col_counter[4]) col_counter <= col_counter - 1'b1;")
edit(f,"\t\t\tvga_repln_count  <= 4'd0;", """            vga_repln_count<=0;
            vga_ddr_row_count<=0;
            col_counter<=5'd16;
            vga13[0]<=vga13req;
            vgatext[0]<=vgatextreq;
            v240[0]<=1'b1;
            planar[0]<=planarreq;
            half[0]<=halfreq;
            repln_graph[0]<=replnreq;""")
edit(f,"    assign ram_cmd   = (cq_act && cq_on) ? (cq_sp != 2'd0 ? 2'b00 : cq_cmd) : cntrl0_user_command_register;",
     "    assign ram_cmd = vb_resync ? 2'b00 : (cq_act && cq_on) ? (cq_sp != 2'd0 ? 2'b00 : cq_cmd) : cntrl0_user_command_register;")
old="\twire vrden = (vrdon || exline[3]) && ((vgatext[1] | half[1]) ? &hcount_pan[3:0] : (vga13[1] | planar[1]) ? &hcount_pan[2:0] : &hcount_pan[1:0]);"
edit(f,old,"""    reg [7:0] vga_line_reads=0;
    reg vga_line_active=0;
    wire [7:0] vga_line_quota=(vgatext[1] || half[1]) ? 8'd48 :
                              (vga13[1] || planar[1]) ? 8'd88 : 8'd168;
    wire vga_read_cadence=(vgatext[1] || half[1]) ? &hcount_pan[3:0] :
                          (vga13[1] || planar[1]) ? &hcount_pan[2:0] : &hcount_pan[1:0];
    wire vrden=(vrdon || vga_line_active) &&
               (vga_line_reads<vga_line_quota) && vga_read_cadence;
    always @(posedge clk_25) begin
        if(vblnk || hcount==10'd799) begin
            vga_line_reads<=0;
            vga_line_active<=0;
        end else begin
            if(vrdon) vga_line_active<=1;
            if(vrden) vga_line_reads<=vga_line_reads+1'b1;
        end
    end""")
edit(f,"\t\tif(RTCDIVEND) RTCDIV25 <= 0;\t", """        // Follow the fetch configuration while blanked, so the first active
        // frame cannot use a display mode captured before the frame reset.
        if(vblnk) begin
            vga13[1]<=vga13[0]; vgatext[1]<=vgatext[0]; v240[1]<=v240[0];
            planar[1]<=planar[0]; half[1]<=half[0];
        end
        if(RTCDIVEND) RTCDIV25 <= 0;""")
f="Next186_BlackBoxes.v"
edit(f,"    input  wire        rst\n);\n    wire wr_busy;", "    input  wire        rst,\n    output wire        reset_busy\n);\n    wire wr_busy;")
edit(f,"    wire [10:0] full_wrusedw;", "    wire [10:0] full_wrusedw;\n    assign reset_busy=wr_busy;")

patch=[]
for name,new in sources.items():
    (OUT/name).write_text(new,encoding="utf-8")
    patch.extend(difflib.unified_diff(original[name].splitlines(True),new.splitlines(True),
                 fromfile="a/"+name,tofile="b/"+name))
(HERE / "vga_frame_alignment.patch").write_text("".join(patch),encoding="utf-8")
(OUT / "input_hashes.json").write_text(json.dumps({"base_commit":BASE,"normalized_sha256":{
    name:hashlib.sha256(original[name].encode("utf-8")).hexdigest() for name in sources}},indent=2),encoding="utf-8")
print("Prepared candidate sources and patch; production files were not changed.")
