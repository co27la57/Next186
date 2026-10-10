# sim/ — Verilator + cocotb 仿真台架

> 目的：用**逐拍可打印**的仿真，替代"盲加 ILA 探针 → 综合 20 分钟 → 下板"的低效循环。
> 目标问题：SD 缓冲（tag 0x1E0）经 `cache ↔ DDR` 往返后数据被破坏（偏移 0x80 读回 `0x50` 而非 `0x20`）。

---

## 1. 本机环境侦察结果（2026-09-26）

| 项 | 结果 |
|---|---|
| `verilator` / `iverilog` / `ghdl` | ❌ 都不在 PATH |
| `gcc` / `g++` / `clang` / `cl` / `make` / `cmake` | ❌ 都不在 PATH |
| **WSL** | ⛔ **被安全策略禁止**（`wsl.exe` 在程序黑名单里，不可绕过，勿重试） |
| PyPI (`pypi.org`) | ✅ 可达（`pip index versions` 正常） |
| `github.com` | ✅ 可达（HTTP 200） |

**关键发现（决定了工具链选择）**：PyPI 上存在**带 Windows x64 wheel** 的仿真器与编译器：

- `verilator` 5.48.0 → `verilator-5.48.0-py3-none-win_amd64.whl`（5.2 MB）
- `ziglang` 0.16.0 → `ziglang-0.16.0-py3-none-win_amd64.whl`（98.7 MB）—— Zig 自带 C/C++ 编译器
- `cocotb` 2.1.0 → 纯 Python wheel

## 2. 工具链

| 角色 | 选型 | 为什么 |
|---|---|---|
| 仿真器 | **Verilator 5.48**（PyPI wheel） | 唯一有 Windows wheel 的可综合 RTL 仿真器；速度快 |
| C++ 编译器 | **Zig 0.16**（PyPI wheel）→ `zig c++` | Verilator 把 Verilog 转 C++，必须有 C++ 编译器；本机没有，Zig 自带 |
| 测试台 | **cocotb 2.1** | 用 Python 写激励/断言，直接打印逐拍信号 |
| 隔离 | managed venv `envs/default` | 不污染系统环境 |

### 2.1 已实测通过的配方（2026-09-26，`LINKUP-OK`）

安装（一次性，约 15 min，`ziglang` 99 MB）：

```bash
VPY="C:/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe"
"$VPY" -m pip install verilator cocotb ziglang
```

关键路径（都是 venv 内，不依赖系统 PATH）：

| 用途 | 路径 |
|---|---|
| Verilator 可执行 | `<site-packages>/verilator/bin/verilator_bin.exe` |
| Verilator 根（运行时/头） | `<site-packages>/verilator`（`include/verilated.cpp` 等） |
| Zig | `<site-packages>/ziglang/zig.exe`（`zig c++` → clang 21.1.0，target `x86_64-unknown-windows-gnu`） |

构建入口：**`sim/build.py`**（三步：`verilator_bin --cc` → `zig c++` 编译链接 → 运行）。

```bash
"$VPY" sim/build.py --top blinky --out run/linkup --run sim/linkup/blinky.v sim/linkup/sim_main.cpp
```

### 2.2 四个必须知道的坑（都已在 `build.py` 里处理）

1. **本机没有 `make`** ⇒ Verilator 的 `--build` 不可用 ⇒ 由 `build.py` 直接调编译链。
2. `verilator_bin` 报 `$VERILATOR_ROOT needs to be in environment` ⇒ 驱动里注入该环境变量。
3. 链接缺 `VlThreadPool::VlThreadPool` ⇒ 必须**同时**编译 `verilated.cpp` **和** `verilated_threads.cpp`。
4. 链接缺 `sc_time_stamp()`：Verilator 视其为**可选弱符号**（`verilated.mk:117` 用
   `-Wl,-U,__Z13sc_time_stampv` 允许未定义），但 **zig 的 lld 不认 `-U`** ⇒ 由
   `sim/tools/vl_stubs.cpp` 提供 `double sc_time_stamp(){return 0;}`（签名见 `verilated_funcs.h:323`）。
5. 包里的 `verilator-cli.exe` / `python-zig.exe` 是 Python 入口，`verilator-cli` 会报错 ⇒ **直接用
   `verilator_bin.exe`** 和 `ziglang/zig.exe`。


## 3. 搭建流程（按序执行）

1. **建目录** `sim/`（本目录）—— 所有仿真相关文件都放这里，不污染 `sources_1/imports/` 根。
2. **建/复用 venv** 并安装：`pip install verilator cocotb ziglang`
3. **打通 Verilator + Zig**：让 Verilator 用 `zig c++` 作为 C++ 前端（`--compiler` / `CXX`），跑一个最小 hello 设计验证。
4. **stage 1 — 最小 TB**：`cache_controller.v` + **DDR 数组行为模型**，用 cocotb 直接驱动 cache 总线，
   复现"写 1KB → 逐出 → 回填 → 读回"，**逐拍打印 `(STATE, hiaddr, sdraddr, ram_cmd, ddr_rd/wr, ram_rdata, ddr_dout)`**。
5. **stage 2 — 加系统层**：把 `ddr_186.v` 的命令流水/仲裁 + **VGA 读流量模型**加进来（这是 91st 修复
   涉及的竞态所在），复现"填充拿到别的行的数据"。
6. **stage 3 — 加 CPU + BIOS**：`unit186.v` + `Next186_CPU.v` + 预置 BIOS（x86 机器码可直接灌入），
   跑完整自测，复现 `dbg_dbg4 = 0x5010`。

## 4. 目录布局

```
sim/
  README.md        本文件（流程 + 环境 + 阶段）
  Makefile         cocotb 构建入口
  filelists/       RTL 文件清单（指向 ../*.v，排除 3 个 VHDL）
  tb/              cocotb 测试（Python）
  models/          行为模型：DDR / SD SPI 从机 / VGA 流量
  run/             构建产物与波形（不提交）
```

## 5. 分阶段判据

| 阶段 | 成功判据 |
|---|---|
| 打通链路 | 一个最小 Verilog 设计能在 Verilator+Zig 下跑完并打印 |
| stage 1 | cache 的 fill / write-back 全流程在仿真里跑通，地址与数据可逐拍打印 |
| stage 2 | **在仿真里复现"回填读到别的行"**（这是核心目标） |
| stage 3 | 复现 BIOS 自测读数（`0x50`），并据此定位根因、验证修复 |

## 6. 注意

- 工程里有 3 个 **VHDL** 文件（`audio_top.vhd` / `dac_if.vhd` / `simple_uart.vhd`）—— 与本问题无关，
  仿真时**排除**（或加空壳 stub）。
- `Next186_BlackBoxes.v` 里的 XPM FIFO（`xpm_fifo_async`）是 Xilinx 原语，Verilator **不认识**；
  stage 1 不需要它们（只需 `cache` 那个 BRAM 模块），到 stage 2/3 再为 XPM 写行为模型或替换。
- 本目录**不进版本库**（`sim/` 会作为未跟踪目录出现；如需忽略可加进 `.gitignore`）。
