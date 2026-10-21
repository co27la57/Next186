#include "Vvga_path.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <deque>
#include <set>
#include <fstream>

// Independent FIFO/source scoreboard. No expected address uses the DUT's
// row/column counters. Tags travel with actual accepted writes and reads.
struct Item { unsigned addr, data; };
struct Bench {
    Vvga_path d;
    std::deque<Item> fifo;
    Item q[2] = {};
    bool qvalid = false;
    uint64_t time = 0, cycle = 0, writes = 0, reads = 0, overflow = 0, underflow = 0;
    unsigned mismatch = 0, frame = 0, line_rd = 0, line_wr = 0, maxlevel = 0;
    uint64_t steady_underflow=0, steady_overflow=0;
    uint64_t address_errors=0, quota_errors=0, pixel_errors=0, visible_pixels=0;
    uint64_t nonblack_pixels=0;
    unsigned text_source=0, palette_source=0, line_pixels=0;
    bool text_source_valid=false, palette_source_valid=false;
    unsigned prev_v = 0, prev_h = 0, prev_ack = 0, burst_n = 0;
    int first_addr = -1, first_h = -1;
    bool prev_blank = false, collecting = false;
    unsigned first_frame_addr = 0;
    std::set<unsigned> fs_addrs;
    unsigned flags, seed, stall, frames, mode, cpu_period, pan, blank, start;
    bool cache_seen=false;
    unsigned cache_transactions=0;
    std::ofstream trace;

    Bench(int argc, char** argv) {
        flags = argc > 1 ? std::strtoul(argv[1],0,0) : 0;
        seed = argc > 2 ? std::strtoul(argv[2],0,0) : 1;
        stall = argc > 3 ? std::strtoul(argv[3],0,0) : 0;
        frames = argc > 4 ? std::strtoul(argv[4],0,0) : 5;
        mode = argc > 5 ? std::strtoul(argv[5],0,0) : 0;
        cpu_period = argc > 6 ? std::strtoul(argv[6],0,0) : 0;
        pan = argc > 7 ? std::strtoul(argv[7],0,0) : 0;
        blank = argc > 8 ? std::strtoul(argv[8],0,0) : 0;
        start = argc > 9 ? std::strtoul(argv[9],0,0) : 0;
        d.CLK_50MHZ=0; d.pixel_clock=0; d.rst_n=0; d.h_wr=0;
        d.cfg_vgatext=mode==0; d.cfg_vga13=mode==1;
        d.cfg_planar=mode==2; d.cfg_half=0;
        d.cfg_repln_graph=mode==1; d.cfg_scraddr=start;
        d.cfg_vga_offset=40; d.cfg_lcr=1023;
        d.cfg_vde=argc>10 ? std::strtoul(argv[10],0,0) : 479;
        d.cfg_vga_hrzpan=pan; d.stall_seed=seed; d.max_stall=stall;
        d.cfg_rd_drop_last_tail=(flags&8)!=0; d.cfg_fetch_step16=0;
        d.cfg_sdrc_off=(flags&4) ? 0 : 8;
        d.fix_flags=flags;
        d.cache_read=0; d.cache_address=0x12340;
        d.eval();
        if(argc>11 && std::strtoul(argv[11],0,0)) {
            trace.open("flush_wave.csv");
            trace<<"cycle,h,v,fifo_reset,wr_busy,rd_busy,resync,bridge_state,ack,cmd,level,rowcol,lnbyte,col_counter,wrreq,write_addr,write_data\n";
        }
    }
    void evaluate() {
        d.eval();
        const uint64_t target=Verilated::time()+5000;
        while(d.eventsPending() && d.nextTimeSlot()<=target) {
            Verilated::timeInc(d.nextTimeSlot()-Verilated::time());
            d.eval();
        }
        Verilated::timeInc(target-Verilated::time());
        d.eval(); time=target;
    }
    void check_reset() {
        if (d.o_fifo_rst || d.o_wr_busy) fifo.clear();
        if (d.o_fifo_rst || d.o_rd_busy) qvalid=false;
    }
    void sdr_rise() {
        check_reset();
        if(trace && frame==3 && d.dbg_vblnk && d.dbg_vcount<483) {
            trace<<cycle<<','<<unsigned(d.dbg_hcount)<<','<<unsigned(d.dbg_vcount)<<','
                 <<unsigned(d.o_fifo_rst)<<','<<unsigned(d.o_wr_busy)<<','<<unsigned(d.o_rd_busy)<<','
                 <<unsigned(d.dbg_vb_resync)<<','<<unsigned(d.o_bridge_state)<<','<<unsigned(d.o_ack)<<','
                 <<unsigned(d.dbg_ram_cmd)<<','<<unsigned(d.o_level)<<','<<unsigned(d.dbg_vga_ddr_row_col)<<','
                 <<unsigned(d.dbg_vga_lnbytecount)<<','<<unsigned(d.dbg_col_counter)<<','<<unsigned(d.o_fifo_wr)<<','
                 <<unsigned(d.o_data_addr)<<','<<unsigned(d.o_wdata)<<'\n';
        }
        if(d.rst_n && cpu_period) {
            if(d.cache_read && d.o_ack==3) cache_seen=true;
            if(cache_seen && !d.o_bridge_busy && d.o_ack==0) {
                d.cache_read=0; cache_seen=false; ++cache_transactions;
            } else if(!d.cache_read && cycle%cpu_period==0) {
                d.cache_read=1; d.cache_address=0x12340+(cache_transactions%16)*32;
            }
            d.eval();
        }
        if (!d.o_fifo_rst && !d.o_wr_busy && d.o_fifo_wr) {
            if (d.o_full) { ++overflow; if(frame>=3)++steady_overflow; }
            else {
                fifo.push_back({unsigned(d.o_data_addr),unsigned(d.o_wdata)});
                ++writes; ++line_wr;
            }
        }
        if (d.o_ack && !prev_ack && burst_n < 20) {
            std::printf("ACK %u cyc=%llu addr_half=%06x lnb=%u col=%u reset=%u busy=%u\n",
                burst_n, (unsigned long long)cycle, d.dbg_ram_addr,
                d.dbg_vga_lnbytecount, d.dbg_col_counter, d.o_fifo_rst, d.o_wr_busy);
            ++burst_n;
        }
        prev_ack=d.o_ack;
        d.CLK_50MHZ=1; evaluate();
        check_reset();
        if (d.o_level > maxlevel) maxlevel=d.o_level;
    }
    void pixel_rise() {
        check_reset();
        if (d.dbg_vblnk && !prev_blank) {
            ++frame;
            std::printf("FRAME %u W=%llu R=%llu overflow=%llu underflow=%llu level=%u fetchrow=%u\n",
                frame,(unsigned long long)writes,(unsigned long long)reads,
                (unsigned long long)overflow,(unsigned long long)underflow,
                d.o_level,d.o_fetch_row);
        }
        prev_blank=d.dbg_vblnk;
        if (d.dbg_vcount != prev_v) {
            if(frame>=3 && prev_v<480) {
                unsigned expected=mode==0 ? 48 : 88;
                if(line_rd!=expected) {
                    if(quota_errors++<8)
                        std::printf("QUOTA v=%u RD=%u expected=%u\n",prev_v,line_rd,expected);
                }
            }
            if(frame>=2 && prev_v<480 && (prev_v<20 || prev_v>477))
                std::printf("LINE frame=%u v=%u RD32=%u WR16=%u first_addr=%06x h=%d level=%u\n",
                    frame,prev_v,line_rd,line_wr,first_addr,first_h,d.o_level);
            line_rd=0; line_wr=0; line_pixels=0; first_addr=-1; first_h=-1;
            prev_v=d.dbg_vcount;
        }
        // sr_font and vga_attr both sample the old FIFO mux at this edge.
        // The output uses their values from the preceding pixel edge.
        unsigned selected=(d.dbg_hcount_pan & 8) ? 1 : 0;
        unsigned current_source=q[selected].addr;
        bool current_valid=qvalid;
        bool visible=mode==0 && d.dbg_sdon && frame>=3 && d.dbg_vcount<480;
        if(visible) {
            unsigned expected=0x5c000+2*start+(d.dbg_vcount/16)*80+(line_pixels+pan)/8;
            ++visible_pixels;
            if(!palette_source_valid || palette_source!=expected) {
                if(pixel_errors++<4)
                    std::printf("PIXEL_ADDR v=%u x=%u h=%u got=%06x expected=%06x\n",
                        d.dbg_vcount,line_pixels,d.dbg_hcount,palette_source,expected);
            }
            ++line_pixels;
        }
        bool rd=d.dbg_vrden && !d.o_rd_busy && !d.o_fifo_rst;
        bool got=false;
        Item next[2]={};
        if (rd) {
            ++line_rd;
            if(d.o_empty) { ++underflow; if(frame>=3)++steady_underflow; }
            else if(fifo.size()<2) { ++mismatch; }
            else {
                next[0]=fifo.front(); fifo.pop_front();
                next[1]=fifo.front(); fifo.pop_front();
                if(frame>=3 && d.dbg_vcount<480) {
                    unsigned row=mode==0 ? d.dbg_vcount/16 : mode==1 ? d.dbg_vcount/2 : d.dbg_vcount;
                    unsigned base=(mode==0 ? 0x5c000 : 0x50000) + 2*start + row*(mode==0 ? 80 : 160);
                    unsigned meaningful=mode==0 ? 40 : 80;
                    if(line_rd<=meaningful) {
                        unsigned expected=base+(line_rd-1)*2;
                        if(next[0].addr!=expected || next[1].addr!=expected+1) {
                            if(address_errors++<4)
                                std::printf("READ_ADDR v=%u rd=%u got=%06x expected=%06x\n",
                                    d.dbg_vcount,line_rd,next[0].addr,expected);
                        }
                    }
                }
                ++reads; got=true;
                if(first_addr<0) {
                    first_addr=next[0].addr; first_h=d.dbg_hcount;
                    if(d.dbg_vcount==0 && frame>=3) {
                        fs_addrs.insert(next[0].addr);
                        std::printf("FS frame=%u addr=%06x level=%u qsize=%zu\n",
                            frame,next[0].addr,d.o_level,fifo.size());
                    }
                }
            }
        }
        d.pixel_clock=1; evaluate();
        if(visible && blank && (d.VGA_R || d.VGA_G || d.VGA_B)) ++nonblack_pixels;
        palette_source=text_source; palette_source_valid=text_source_valid;
        text_source=current_source; text_source_valid=current_valid;
        if(got) {
            q[0]=next[0]; q[1]=next[1]; qvalid=true;
            unsigned expected=q[0].data | (q[1].data<<16);
            if(d.o_q != expected && mismatch++<8)
                std::printf("Q_MISMATCH got=%08x expected=%08x\n",d.o_q,expected);
        }
    }
    void tick() {
        sdr_rise();
        if(!(cycle&1)) pixel_rise();
        else { d.pixel_clock=0; evaluate(); }
        d.CLK_50MHZ=0; evaluate();
        evaluate();
        ++cycle;
    }
    int run() {
        // Full address-tagged memory; address unit is a 16-bit halfword.
        d.h_wr=1;
        for(unsigned a=0;a<(1u<<20);++a) {
            d.h_addr=a;
            d.h_din=blank ? ((a>=0x5c000+2*start && a<0x5c000+2*start+80*30) ? 0 : 0xffff) : a;
            tick();
        }
        d.h_wr=0; for(int i=0;i<32;++i)tick();
        d.rst_n=1;
        for(uint64_t i=0;frame<frames && i<uint64_t(frames+3)*1700000;++i) tick();
        std::printf("RESULT flags=%u seed=%u stall=%u mode=%u frames=%u FS_variants=%zu maxlevel=%u overflow=%llu underflow=%llu steady_OVF=%llu steady_UDF=%llu scoreboard_errors=%u textbits=%u cache_n=%u pan=%u\n",
            flags,seed,stall,mode,frame,fs_addrs.size(),maxlevel,
            (unsigned long long)overflow,(unsigned long long)underflow,
            (unsigned long long)steady_overflow,(unsigned long long)steady_underflow,mismatch,d.o_text,cache_transactions,pan);
        std::printf("CHECK address_errors=%llu quota_errors=%llu pixel_errors=%llu visible_pixels=%llu nonblack_pixels=%llu blank=%u start=%u\n",
            (unsigned long long)address_errors,(unsigned long long)quota_errors,
            (unsigned long long)pixel_errors,(unsigned long long)visible_pixels,
            (unsigned long long)nonblack_pixels,blank,start);
        return mismatch ? 2 : (address_errors || quota_errors || (mode==0 && pixel_errors) || nonblack_pixels || steady_underflow || steady_overflow || frame<frames) ? 1 : 0;
    }
};
int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    Bench b(argc,argv); return b.run();
}
