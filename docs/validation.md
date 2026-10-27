# 验证范围与历史结果

## 本次发布对应什么

公开的功能 RTL 来源于已部署的 R106 板级源码副本，而非递归编译所有历史候选。物理桌面使用 R111 storage-r2 Linux、r113-linux1 启动及 R115 软件配置。原研究树处于 `research/rv64`，HEAD 为 `5316c60de5e07128e7685992135b0c485a01981c`，但大量阶段源码未提交，所以本次以已封存工作树和源哈希为准。

导入记录在 `provenance/source-import.json`，公开适配清单在 `provenance/publication-adaptations.json`。后者说明路径修改、initramfs 配置去除原绝对路径、DT 熵处理和公开说明调整；不会把这些调整后的文件称为与原实板逐字节相同的输入。

## 历史物理结果

| 验证 | 已观察到的结果 |
|---|---|
| 自研 PL CPU / 真实 DDR | OpenSBI、Linux、S/U 态、进程、MMU/COW、页故障隔离、定时调度与浮点上下文测试 |
| 官方 Debian 用户态 | LP64D 程序、动态库、Xorg / Openbox / xterm 实际由 PL CPU 执行 |
| USB | 真实 PS USB、Hub、存储枚举/绑定和只读访问；真实键盘与鼠标接入 |
| HDMI | 人工确认颜色条、Linux 测试图、DRM 文字控制台、完整 Debian 终端窗口 |
| 输入 | 人工确认 `echo hello`、鼠标移动；修复工作区后确认 `echo input_ok` 和窗口可见 |
| 显存 | 实际 1,920,000 字节帧缓冲读回、CRC 与扫描计数相关检查 |

上述阶段并非每次都使用同一用户态或同一启动配置，不能合并成“所有版本均已完整冷启动回归”。R115 的受控 X-only 重启具有新入口的进程/窗口管理状态证据，没有另一次人工显示确认。历史错误、启动下溢和输入延迟未被删除或改称零错误。

`docs/images/debian-desktop-ddr-readback.png` 对应完整窗口的实际 DDR 内容；该图不是摄像照片，也不是软件模拟界面。

## 历史 Vivado 结果

见 `provenance/board-measurements.json`：32,827 LUT、26,218 FF、5 BRAM Tile、14 DSP；50/40/200 MHz 三组时钟，setup +0.741 ns、hold +0.037 ns，54,648 条可布线网络全部已布线。

- 报告仍有 CDC-6、CDC-15 等告警。同步器、Gray 指针、held snapshot、VIO 控制和复位存在单独的路径/握手审查。
- PS USB 的 hard-macro IRQ 没有普通源时钟，常规 `report_cdc` 不覆盖其全部来源；需要实际 IRQP2F[15]→两级 ASYNC_REG→PLIC 的补充检查。
- BRAM REQP-1839 的展开报告为 13,124 条路径，针对四个 cache RAM 的读地址/使能。审查依赖共同复位及复位期丢弃无效读数据，不证明任意局部异步复位都安全。
- TMDS 外部眼图、抖动和所有板卡电气条件不能由内部 STA 替代。已有实际显示确认只适用于测试过的板卡和连接。

## 此公开目录重新执行的检查

执行结果保存在 `provenance/public-release-checks.json`。包括导入源哈希、文档/构建路径、公开内容检查、原生视频时序测试、Linux/OpenSBI 上游解包与 overlay 校验、设备树编译及原包缓存哈希核验。未重新执行全量 Vivado、完整 Linux 模型或新一轮物理启动。

这次发布没有连接板卡、复位、重编程或写启动介质。CI 仅运行源码检查和视频时序模块测试，不应被解释为 Linux / FPGA 全系统验收。
