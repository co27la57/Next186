module dcm (
    input  inclk0, // 50 MHz 输入
    output c0,     // 25 MHz (VGA)
    output c1,     // 50 MHz (SDRAM)
    output c2,     // 50 MHz (SDRAM out)
    output c3,     // 11.25 MHz (Audio - 接近 44.1kHz*256)
    output c4,      // 14.75 MHz (UART - 接近 14.7456MHz)
    output locked
);
    wire clkfb;
    wire clk_unbuf;
    wire clkfb_unbuf;
    wire c0_unbuf, c1_unbuf, c2_unbuf, c3_unbuf, c4_unbuf;

    // 例化 Xilinx 7 系列 MMCM 原语
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(18.000),      // VCO = 50MHz * 18 = 900MHz
        .CLKIN1_PERIOD(20.000),        // 50 MHz
        .DIVCLK_DIVIDE(1),             
        .CLKOUT0_DIVIDE_F(36.000),     // 900 / 36 = 25 MHz (VGA)
        .CLKOUT1_DIVIDE(18),           // 900 / 18 = 50 MHz
        .CLKOUT2_DIVIDE(18),           // 900 / 18 = 50 MHz
        .CLKOUT3_DIVIDE(80),           // 900 / 80 = 11.25 MHz (音频)
        .CLKOUT4_DIVIDE(61),           // 900 / 61 = 14.75 MHz (UART)
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT1_DUTY_CYCLE(0.5),
        .CLKOUT2_DUTY_CYCLE(0.5),
        .CLKOUT3_DUTY_CYCLE(0.5),
        .CLKOUT4_DUTY_CYCLE(0.5)
    ) mmcm_inst (
        .CLKIN1(inclk0),
        .CLKFBIN(clkfb),
        .CLKFBOUT(clkfb_unbuf),
        .CLKOUT0(c0_unbuf),
        .CLKOUT1(c1_unbuf),
        .CLKOUT2(c2_unbuf),
        .CLKOUT3(c3_unbuf),
        .CLKOUT4(c4_unbuf),
        .PWRDWN(1'b0),
        .RST(1'b0), // 自动锁定，不复位
        .LOCKED(locked)
    );

    // Xilinx 架构要求时钟输出必须经过 BUFG (全局时钟缓冲器)
    BUFG bufg_fb (.I(clkfb_unbuf), .O(clkfb));
    BUFG bufg_in (.I(inclk0), .O(inclk_buf));
    BUFG bufg_c0 (.I(c0_unbuf), .O(c0));
    BUFG bufg_c1 (.I(c1_unbuf), .O(c1));
    BUFG bufg_c2 (.I(c2_unbuf), .O(c2));
    BUFG bufg_c3 (.I(c3_unbuf), .O(c3));
    BUFG bufg_c4 (.I(c4_unbuf), .O(c4));

endmodule