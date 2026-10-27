# Contributing

Please describe the exact configuration, reproduction command and observed result. Include whether the run used native RTL simulation, formal checking, Vivado implementation, JTAG loading or actual connected peripherals.

Keep CPU/software correctness separate from performance claims. Changes to C/F/D, traps, MMU, DMA visibility or interrupts should include focused regression evidence. Do not mix the non-C dual-issue research configuration with the conservative GC desktop configuration.

Portable RTL in `rtl/` must stay vendor-IP-free. FPGA primitives and Vivado IP belong in the board integration. Do not suppress a timing/CDC/DRC diagnostic merely to make a build green.

Use new build directories; retain failure logs. Do not commit waveforms, compiler PCH, models, toolchains, credentials or disk images. New tools must never automatically format storage or program nonvolatile board media.

Run `python3 tools/check_release.py` and the relevant tests before submitting a change. A source check or video timing smoke test alone is not Linux or whole-board acceptance.
