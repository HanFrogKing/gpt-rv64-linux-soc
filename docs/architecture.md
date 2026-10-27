# 硬件与软件结构

## CPU 配置

核心见 [`rv64_dual_core.sv`](../rtl/rv64/seip/rv64_dual_core.sv)，板级实例见 [`rv64_board_system_video.sv`](../rtl/rv64/board/rv64_board_system_video.sv)。前端命名为 F0/F1/F2/F3，后端为 D/I/X/M/N/C；这是寄存边界的组织方式，不表示所有指令固定十拍完成。缓存未命中、页表遍历、原子和浮点等会产生额外等待或串行化。

当前板级参数启用 C、F/D、M/S/U、MMU 和 A。虽然 `ENABLE_BP=1`，核心中的预测器生成条件实际为 `ENABLE_BP && !ENABLE_C`。同样，配对发射和提前 Load 路径受 `!ENABLE_C` 限制。因此本次桌面是保守 GC 配置，双发射与预测逻辑的存在不等于它们在当前运行中生效。

后续若恢复 GC 配置中的并行取指、双发射或预测，需要重新覆盖变长指令边界、跨块取指、异常先后、重定向和浮点上下文，再做 Linux 回归；不能只翻参数。

## Cache、MMU 和总线

I-Cache 使用 4 KiB 直接映射、32 字节 cache line 和 64 位取指块。D-Cache 是阻塞式写回/写分配设计，支持逐行 clean / invalidate / flush；有脏数据的直接 invalidate 会返回错误，避免静默丢数据。

Sv39 负责地址转换与权限检查。CPU 的物理内存通过项目 AXI4 路由连接外部接口，Windows 板级工程在 PL 到 PS 的边界生成 AXI4→AXI3 转换和 MMIO 位宽转换。**64 位数据总线不意味着每个地址都允许 8 字节访问**：PLIC 采用 32 位访问，PS MMIO 的允许范围和大小由解码器逐项检查。

DMA 非硬件全相干：Linux 的非相干 DMA 钩子、显式缓存维护、非缓存池和 DT `dma-ranges` 共同处理 CPU/设备可见性。维护控制器需要先完成自身 MMIO 响应，再开始可能占用 cache/总线的操作。

## 地址布局

| CPU 物理地址 | 用途 / PS 视角 |
|---|---|
| `0x00001000` | 项目启动 ROM |
| `0x02000000` 区域 | CLINT，mtime / mtimecmp / MSIP；timebase 1 MHz |
| `0x03000000` 页 | DMA cache maintenance 控制 |
| `0x04000000` 小窗口 | 显示控制寄存器 |
| `0x0c000000` 区域 | PLIC，M/S 两个 context |
| `0x80000000` | 映射到 PS 地址 0；最前端是低 OCM，**不是安全 DDR** |
| `0x80200000` | 真正 DDR 中的 OpenSBI，PS `0x00200000` |
| `0x80400000` | Linux Image，PS `0x00400000` |
| `0x87000000` 起 | 非缓存 DMA 池；不能由任意应用硬编码当作空闲显存 |
| `0x87e00000` | DT，PS `0x07e00000` |
| `0xe0000000` 页 | PS UART0 |
| `0xe0002000` 页 | PS USB0 |

准确允许窗口及事务规则以解码器和设备树为准。启动时只有一个 8 字节跳转桩放在低 OCM；代码、堆栈和原子测试必须放在真实 DDR。

## Linux 显示链路

```text
Xorg / Openbox / xterm
  → DRM GEM shadow / CPU damage copy
  → Linux DMA allocation
  → DDR framebuffer
  → PS HP1 / display AXI DMA
  → dual-clock FIFO
  → 800×600 timing / TMDS / FPGA serializer
  → HDMI
```

像素时钟为 40 MHz，行总长 1056、帧总高 628；帧率约 60.3 Hz。串行器时钟 200 MHz，配合 DDR 输出。当前 Linux 驱动没有硬件 VBlank/pageflip，同步完成事件使用软件路径；不能称为无撕裂显示。

显示 DMA 与 CPU 经不同 PS HP 端口访问 DDR，CPU 提交暂停时扫描仍可继续。扫描 CRC、FIFO/AXI 错误计数用于诊断，DDR 读回和 CRC 不能替代实际 HDMI 画面的确认。

## 软件与 ARM 的职责

ARM A9 / JTAG 负责 PS 初始化和装载阶段；已有 Linux / Debian / Xorg 执行证据来自 PL RV64 CPU，两个 A9 保持停止。复现过程中需要保留调试会话所有权，避免退出工具后 A9 意外继续运行。

OpenSBI 提供 M→S 的启动和 SBI 服务；Linux 管理页表、进程、调度、IRQ 和设备；最小 initramfs 提供诊断与串口；Debian 官方用户态提供动态库、Xorg、Openbox 和 xterm。当前桌面采用只读软件下层与 RAM 可写层，未完成普通安装式 Debian 的所有包配置。
