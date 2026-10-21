#include "Vsoundwave.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

// Independent standard I2S receiver: sample on BCLK rising edges; the first
// rising edge after WS changes carries the previous word's last bit.
struct Receiver {
    bool sck=false,ws=false;
    unsigned bits=0,word=0,left=0,right=0,nleft=0,nright=0;
    void observe(bool clock,bool select,bool data) {
        if(clock && !sck) {
            if(select!=ws) {
                if(bits==15) {
                    unsigned value=((word<<1)|unsigned(data))&65535;
                    if(ws) {right=value;++nright;}
                    else {left=value;++nleft;}
                }
                ws=select;bits=0;word=0;
            } else if(bits<16) {word=(word<<1)|unsigned(data);++bits;}
        }
        sck=clock;
    }
};

int main(int argc,char**argv) {
    Verilated::commandArgs(argc,argv);
    Vsoundwave d;
    Receiver rx;
    uint64_t halfstep=0;
    d.CLK=0;d.CLK44100x256=0;d.CLK_I2S=0;
    d.reset=1;d.data=0;d.we=0;d.word=0;d.speaker=0;
    d.opl3left=0;d.opl3right=0;d.midi_left=0;d.midi_right=0;d.master_att=0;
    d.eval();
    auto run=[&](unsigned n) {
        for(unsigned i=0;i<n;++i,++halfstep) {
            d.CLK_I2S=halfstep&1;
            d.CLK=(halfstep/2)&1;
            d.CLK44100x256=((halfstep*9)/40)&1;
            d.eval();
            rx.observe(d.I2S_SCLK,d.I2S_LRCLK,d.I2S_SDIN);
        }
    };
    run(1000);d.reset=0;
    struct Case {const char*name;int l,r,ml,mr,att;};
    const Case cases[]={
        {"silence",0,0,0,0,0},
        {"small",1000,-1000,0,0,0},
        {"small_gain_2",1000,-1000,0,0,2},
        {"small_gain_3",1000,-1000,0,0,3},
        {"small_gain_8",1000,-1000,0,0,8},
        {"large",30000,-30000,0,0,0},
        {"clip",30000,-30000,30000,-30000,0},
        {"mix_gain_2",30000,-30000,30000,-30000,2},
        {"endpoints",32767,-32768,0,0,0},
        {"silence_gain_3",0,0,0,0,3}
    };
    auto expected=[](int x,int shift) {
        int a=1<<shift;
        int v=x>=0 ? x/a : -((-x+a-1)/a);
        return v>32767?32767:v< -32768?-32768:v;
    };
    unsigned bad=0;
    for(auto c:cases) {
        d.opl3left=uint16_t(c.l);d.opl3right=uint16_t(c.r);
        d.midi_left=uint16_t(c.ml);d.midi_right=uint16_t(c.mr);d.master_att=c.att;
        unsigned prevl=rx.nleft,prevr=rx.nright;
        run(80000); // 0.8 ms, enough to settle OPL sampling and complete frames.
        int el=expected(c.l+c.ml,c.att),er=expected(c.r+c.mr,c.att);
        int ol=int16_t(rx.left),orr=int16_t(rx.right);
        bool ok=rx.nleft>prevl && rx.nright>prevr && ol==el && orr==er;
        std::printf("%-18s att=%d expected=(%6d,%6d) I2S=(%6d,%6d) raw=(%04x,%04x) %s\n",
            c.name,c.att,el,er,ol,orr,rx.left,rx.right,ok?"PASS":"FAIL");
        if(!ok)++bad;
    }
    std::printf("RESULT mismatches=%u/%zu decoded_L=%u decoded_R=%u\n",bad,
        sizeof(cases)/sizeof(cases[0]),rx.nleft,rx.nright);
    return bad?1:0;
}
