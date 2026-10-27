# Third-party components and license scope

The root MIT license covers original project RTL, standalone project tools and documentation. It does **not** replace copyright notices, SPDX identifiers or upstream licenses in imported or derived material.

| Component | Location / use | License |
|---|---|---|
| Berkeley HardFloat Release 1 | `third_party/HardFloat-1-compat/`; floating-point arithmetic | BSD-3-Clause; full terms retained in source headers and `LICENSE.txt` |
| Linux 6.6.80 | `software/linux/overlay/`, kernel-derived material in `software/reference/` and `reference/` | GPL-2.0-only / applicable original kernel file license; see `software/linux/COPYING` and SPDX headers |
| OpenSBI 1.6 | Cadence UART derivative in `software/opensbi/overlay/` | BSD-2-Clause; original author attribution and `COPYING.BSD` retained |
| Debian 13 packages | Package names, upstream URLs, versions and SHA256 hashes only | Each package's own license; no DEB files or desktop image distributed here |
| BusyBox 1.36.1 | Source URL / version lock and project configuration | GPL-2.0; upstream source and license fetched separately |
| musl 1.2.5 | Source URL / version lock | MIT; upstream source fetched separately |
| AMD / Xilinx tools and IP | PS7, AXI adapters, reset, VIO, FPGA primitives referenced by board Tcl / BD | Respective vendor licenses; generated implementation code, FSBL/BSP and tool installations are not redistributed |

`reference/` contains original research software and recipes retained for traceability. A file derived from Linux, OpenSBI or other upstream code remains under its original license even when outside the directories above. Existing file-level notices take precedence over the repository default.

The board `.bd` stores project PS/interface configuration and references vendor IP; it is not an open implementation of the Zynq hard macros or vendor IP. Rebuilding those portions requires the appropriate local AMD tools and rights.

This initial public release is source-only. It does not bundle Linux Image, OpenSBI binaries, Debian root filesystems, proprietary FPGA IP products, board manuals, vendor demonstration projects or binary toolchains.

OpenAI / GPT, AMD / Xilinx, Debian and Berkeley names describe tools, compatibility or upstream components; they do not imply endorsement.
