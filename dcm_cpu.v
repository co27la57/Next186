module dcm_cpu (
    input  inclk0, // 50 MHz 输入
    output c0,     // 25 MHz CPU 时钟 (极致稳定版)
    output c1,     // 45 MHz DSP 时钟
    output locked
);

    wire clkfb;
    wire clkfb_unbuf;
    wire c0_unbuf, c1_unbuf;
    
    BUFG bufg_in (.I(inclk0), .O(inclk_buf));
    
    // 例化 Xilinx 7 系列 MMCM 原语
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(18.000),      // VCO = 50MHz * 18 = 900MHz
        .CLKIN1_PERIOD(20.000),        // 输入时钟周期为 20ns (50MHz)
        .DIVCLK_DIVIDE(1),             // 输入预分频 = 1
        
        // 【核心修改】：将除数改为 36.000，900MHz / 36 = 25.0MHz (周期 40ns)
        // 彻底解决 26ns 路径延迟导致的时序崩溃！
        .CLKOUT0_DIVIDE_F(36.000),     
        
        // DSP 保持原来的 45MHz (900 / 20 = 45)
        .CLKOUT1_DIVIDE(20),           
        
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT1_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE(0.0),
        .CLKOUT1_PHASE(0.0)
    ) mmcm_inst (
        .CLKIN1(inclk_buf),
        .CLKFBIN(clkfb),
        .CLKFBOUT(clkfb_unbuf),
        .CLKOUT0(c0_unbuf),
        .CLKOUT1(c1_unbuf),
        .PWRDWN(1'b0),
        .RST(1'b0), // 自动锁定，不复位
        .LOCKED(locked)
    );

    // Xilinx 架构要求时钟输出必须经过 BUFG (全局时钟缓冲器) 才能接到逻辑网络上
    BUFG bufg_fb (.I(clkfb_unbuf), .O(clkfb));
    BUFG bufg_c0 (.I(c0_unbuf), .O(c0));
    BUFG bufg_c1 (.I(c1_unbuf), .O(c1));

endmodule