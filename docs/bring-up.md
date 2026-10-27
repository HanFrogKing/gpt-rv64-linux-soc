# 上板与 Linux 启动

本次公开的是已实际运行图形软件的源码配置。现有启动路径依赖 JTAG / XSCT 初始化 PS 和装载软件，不包含可直接写 TF 卡的 `BOOT.BIN`。

## 板卡与连接

- RK-ZYNQ7020-F，XC7Z020CLG484-2；不同封装/版本必须重新核对管脚与电气。
- 调试 USB / JTAG、串口、板卡电源。
- HDMI 显示器选择对应输入；本配置只输出 800×600，约 60 Hz。
- PS USB 连接有供电能力的 Hub，再连接键鼠和可用于测试的存储设备。

HDMI HPD 使用 Y18；不要把厂商示例中注释掉的旧管脚直接当作有效配置。实际 XDC 在 `fpga/rk-zynq7020-f/constraints/board-r1.xdc`。

## 启动顺序

1. 构建并检查 FPGA 位流，生成与该硬件一致的 PS 初始化材料。
2. 用 XSCT 完成 PS 初始化，将两个 ARM Cortex-A9 停止并保持调试会话。不要在活动 DMA/USB/显示状态下随意局部复位替换逻辑。
3. 加载 PL 位流。初始 VIO 应保持 CPU / fabric / AXI adapter 的**共同复位**。
4. 验证真实 DDR 布局和基本访问，再装载下面四项输入。PS 地址 0 只放 8 字节 OCM 跳转桩，绝不把它当 DDR 分配堆栈、原子区或 DMA 缓冲。
5. 对所有已装载字节做完整 DAP 读回并核对 SHA256；检查时钟锁定、共同复位及 ARM 状态。
6. 释放共同复位，采集真实串口的 OpenSBI、Linux 和用户态输出；保持 XSCT 所有权，避免工具退出意外恢复 ARM。
7. 验证 DRM、USB、输入后，准备 Debian 软件下层和 RAM 上层，在目标 chroot 内执行桌面入口。

| 输入 | PL CPU 地址 | PS 装载地址 |
|---|---|---|
| 8 字节 trampoline | `0x80000000` | `0x00000000`，低 OCM |
| OpenSBI fw_jump | `0x80200000` | `0x00200000` |
| Linux Image | `0x80400000` | `0x00400000` |
| 本次新 DTB | `0x87e00000` | `0x07e00000` |

实际跳转桩字节为 `97 02 20 00 67 80 02 00`，对应在 `0x80000000` 执行 `auipc t0,0x200; jalr zero,0(t0)`，跳到 `0x80200000`。低 OCM 的内容与活跃 ARM FSBL 不可混用；自主引导需要新的完整交接设计。

## 用户态和桌面检查

在目标系统检查 `/dev/dri/card0`、USB/HID、`/dev/input/event*` 和实际 Xorg/libinput 状态。存储设备先确认身份，再按只读方式检查；公开仓库没有自动格式化或写盘入口。

桌面入口路径：

```sh
# 已进入正确的目标 Debian chroot，依赖和 /dev /proc /sys /run 等已准备好
/bin/busybox sh /path/to/desktop-session.sh
```

入口会准备少量字体，关闭 GLX，启动 udev 的 input coldplug，并在新会话中使用单工作区、禁用桌面滚轮切换工作区。已有 X socket 时会拒绝重复启动。若看见背景但暂时没有窗口，应检查字体扫描和 Openbox 初始化，不能马上断言终端退出。

实测演示包括 `echo hello`、`echo input_ok`、鼠标移动和普通滚轮后窗口保持可见。应分别检查串口、DDR 帧缓冲及真实显示器；只读到 DDR 内容不代表 HDMI 电气或扫描一定正确。

## 复现范围

原私有研发流程具有严格的 source-lock、加载哈希、复位/VIO 与会话所有权状态机。它们依赖原阶段目录和原调试会话，不能把其中一个 Tcl 文件复制到新机器便声称可直接执行。公开版目前提供对应 RTL、板级构建、软件差异、配置、地址和步骤；完整的可迁移 JTAG 装载器、原诊断 initramfs 和桌面镜像一键生成仍在路线图中。

当前没有承诺从 TF 卡上电自动启动。请勿把 R106 位流直接与后续 SD 候选 DT / ARM loader 混用，也不要用 TF 自主引导实验覆盖正在运行桌面的根文件系统。
