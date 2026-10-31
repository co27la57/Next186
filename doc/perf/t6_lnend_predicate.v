`timescale 1ns/1ps
// vga_lnbytecount 的单位是"字"(32bit). 判据 = (lnbytecount[7:3] == lnend)
module t6;
  reg [7:0] lnb; reg [4:0] lnend; integer step, quota, n, i; reg done;

  task run(input [8*7:1] name, input [4:0] end_v, input integer st, input integer q);
    begin
      lnb=8'd0; lnend=end_v; step=st; quota=q; n=0; done=0;
      for (i=0; i<40; i=i+1) begin
        if (!done) begin
          lnb = lnb + step[7:0];
          n   = n + 1;
          if (lnb[7:3] == lnend) done = 1;
        end
      end
      if (!done)
        $display("  %s step=%0d lnend=%0d : *** 行永不结束 *** (末 lnb=%0d [7:3]=%0d)", name, st, end_v, lnb, lnb[7:3]);
      else
        $display("  %s step=%0d lnend=%0d : %0d 突发 x %0d 字 = %0d 字 / 需要 %0d 字  %s",
                 name, st, end_v, n, st, n*st, quota,
                 (n*st==quota) ? "精确匹配" : ((n*st>quota) ? "多取" : "不足!"));
    end
  endtask

  initial begin
    $display("=== A. 现状 (窄模式 step=8 字, col_init=15 -> 只收 16 半字=8 字) ===");
    run("text  ", 5'd6,   8, 48);
    run("half  ", 5'd6,   8, 48);
    run("13h   ", 5'd11,  8, 88);
    run("planar", 5'd11,  8, 88);
    run("vesa  ", 5'd22, 16,176);
    $display("");
    $display("=== B. 只把窄模式步进改 16 字(吃满 burst), lnend 不动 ===");
    run("text  ", 5'd6,  16, 48);
    run("half  ", 5'd6,  16, 48);
    run("13h   ", 5'd11, 16, 88);
    run("planar", 5'd11, 16, 88);
    $display("");
    $display("=== C. 步进 16 + 13h/planar 的 lnend 11->12 (奇数不可达) ===");
    run("13h   ", 5'd12, 16, 88);
    run("planar", 5'd12, 16, 88);
    $display("");
    $display("=== D. C 再把 quota 配平到 96 字 ===");
    run("13h   ", 5'd12, 16, 96);
    run("planar", 5'd12, 16, 96);
  end
endmodule
