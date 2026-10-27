# 构建和软件准备

## 环境

- FPGA：Vivado / Vitis 2023.1，目标 `xc7z020clg484-2`。IP 在 Windows 板级工程生成；可移植 RTL 不引入 Vivado IP。
- 源码工具：Python 3.10+；Linux / WSL 下的 `make`、C/C++ 编译器、Verilator、dtc。
- 软件交叉编译：能生成 RV64 ELF 的 GCC/binutils；官方 Debian 用户态要求 RV64GC / LP64D。OpenSBI 采用较小的 RV64IMA / LP64 配置。
- Kernel 构建还需要 Linux 的常规依赖，如 bison、flex、bc、OpenSSL/ELF 开发包。

本仓库不会安装工具链或修改系统 PATH。测试构建会检查磁盘余量、限定超时、保存日志并清理本次生成的 Verilator PCH；默认不产生波形。

## 1. 检查公开源码

```sh
python3 tools/check_release.py
python3 tools/run_video_test.py
```

`check_release.py` 核对实板导入源码、Linux 项目差异、Vivado 源文件清单和文档链接。视频测试使用原有真实 RTL 测试台，覆盖完整帧、颜色条、同步宽度、消隐区及复位边界。它不是 CPU/Linux/全板回归。

## 2. 综合和布局布线

PowerShell，仓库根目录：

```powershell
$board = (Resolve-Path fpga/rk-zynq7020-f).Path
vivado -mode batch -source "$board/scripts/build.tcl" -tclargs "$board"
vivado -mode batch -source "$board/scripts/post-route-audit-r4.tcl" -tclargs "$board"
vivado -mode batch -source "$board/scripts/bram-control-audit-r2.tcl" -tclargs "$board"
```

第一次命令输出 `build/full-r1` 和 `reports/full-r1`。脚本拒绝覆盖已有构建目录，以保留失败和报告。公开适配只调整源码路径，并为一个 DRC 查询中的 Error 字面量补引号；原脚本保留在 `provenance/reference/`，功能 RTL 未改变。

检查 setup / hold、未约束路径、复位、USB IRQ 来源、FIFO 指针/快照 CDC 和完整 BRAM 告警。BRAM 报告是展开后的诊断材料，需要按 [validation.md](validation.md) 中的边界评估；**工具返回 0 不等于硬件无条件通过**。

确认这些检查后，生成位流：

```powershell
vivado -mode batch -source "$board/scripts/write-bitstream-r1.tcl" -tclargs "$board"
```

输出 `reports/bitstream-r1/rv64gc-scanout.bit` 和 `debug.ltx`。本流程不调用硬件管理器，不复位板卡，不写 QSPI / TF。初次公开版本没有在此新目录重新运行全量 Vivado；历史时序数据来自原 R106 实板构建。

## 3. 准备 Linux 源码

```sh
python3 tools/fetch_sources.py linux
python3 tools/prepare_kernel.py
```

也可使用已有压缩包，避免重复下载：

```sh
python3 tools/prepare_kernel.py --archive downloads/linux-6.6.80.tar.xz
```

上游来源、SHA256 和版本在 `software/sources.lock.json`；准备工具只接受不存在的新目录，并校验项目 overlay。输出为 `build/linux-source/linux-6.6.80/`。

配置 `software/linux/r111.config` 来源于实际 R111 内核。原来的绝对 initramfs 路径已清空，需要自行提供 rootfs 或 cpio，不能直接把空 initramfs 的 Image 当作桌面成品。

```sh
mkdir -p build/kernel
cp software/linux/r111.config build/kernel/.config
src="$PWD/build/linux-source/linux-6.6.80"
out="$PWD/build/kernel"
# 先准备自己的 initramfs.cpio，再指向其绝对路径：
"$src/scripts/config" --file "$out/.config" --set-str INITRAMFS_SOURCE "$PWD/build/initramfs.cpio"
make -C "$src" O="$out" ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
make -C "$src" O="$out" ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j2 Image
```

`reference/initramfs-r109.list.in`、`reference/initramfs-r109-rcS` 以及 `reference/sw/` 保留原最小用户态及测试程序来源；`${RESEARCH_ROOT}` 是原分阶段构建树的占位符，不会由 Linux 自动展开。原研究脚本保留在 `reference/build-scripts/`，依赖未随公开仓库搬运的父阶段产物。**当前公开仓库尚无从零生成原完整诊断 initramfs 和桌面镜像的一键命令**，这是明确的复现缺口。可以先使用自己构建的静态 BusyBox initramfs 验证串口，再接入 Debian 用户态。

## 4. OpenSBI

```sh
python3 tools/prepare_opensbi.py
src="$PWD/build/opensbi-source/opensbi-1.6"
out="$PWD/build/opensbi"
make -C "$src" O="$out" PLATFORM=generic PLATFORM_RISCV_XLEN=64 OPENSBI_CC_XLEN=64 \
  PLATFORM_RISCV_ISA=rv64ima_zicsr_zifencei PLATFORM_RISCV_ABI=lp64 \
  CROSS_COMPILE=riscv64-linux-gnu- RELAX_FLAG=-mno-relax \
  FW_TEXT_START=0x80200000 FW_JUMP_ADDR=0x80400000 FW_JUMP_FDT_ADDR=0x87e00000 \
  FW_DYNAMIC=n FW_PAYLOAD=n FW_JUMP=y OPENSBI_VERSION_GIT= -j2
```

确认最终配置包含 Cadence UART、FDT serial、mtimer、mswi 和所需 SBI 服务。`software/opensbi/r82.config` 是历史构建参考；准备工具把实际使用的 Cadence 分频修正应用到固定 OpenSBI 1.6 上游源码，不修改全局安装。

## 5. 设备树

```sh
python3 tools/make_dtb.py --output build/dt-boot-001
```

每个新启动包生成新的 64 字节宿主随机种子；输出目录不能复用。`software/dts/board.dts` 由实际装载过的 DT 还原，包含 PLIC、USB PHY、DMA 地址偏移和显示节点。没有模拟器门铃，也没有尚未验收的原生 SD 控制器节点。改变内存布局、IRQ 编号或外设时必须同步检查 RTL。

## 6. Debian 桌面软件

```sh
python3 tools/fetch_debian.py
```

`packages.lock.json` 锁定当时使用的 228 个官方包的版本、大小、URL 和 SHA256。此工具只下载和校验，不安装、不执行目标程序。旧版本若从 Debian 镜像移除，应从 Debian snapshot 恢复对应版本并检查相同 SHA，不能悄悄换新版本。

`software/desktop/rootfs/` 提供原有最小桌面配置，`software/desktop/desktop-session.sh` 是 R115 入口。需要将 BusyBox、依赖、设备节点、proc/sys/dev/run、可写临时目录和 Xorg 配置准备好后，在目标 Debian chroot 内执行。它不会挂载磁盘，也不会替换已经运行的 X 会话。

这是只读软件包集合的图形运行路径，不是 `debootstrap` 或普通 Debian 安装器的替代品；dpkg 配置、完整 systemd/D-Bus、持久用户环境和自主启动仍需单独完成。
