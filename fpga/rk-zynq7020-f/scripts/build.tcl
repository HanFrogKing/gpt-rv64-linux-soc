# R106 independent board candidate: own GC CPU/cache/fabric on actual PS HP0/GP0.
proc build {} {
 global argv
 set root [file normalize [lindex $argv 0]]
 set repo [file normalize $root/../..]
 set work $root/build/full-r1
 if {[file exists $work]} {error "Preserve previous candidate build"}
 file mkdir $work/bd/design_1
 file mkdir $root/reports/full-r1
 create_project rk7020_gc_scanout_r1 $work/vivado -part xc7z020clg484-2
 set_param general.maxThreads 1
 add_files [list $repo/rtl/rv64/rv64_alu.sv $repo/rtl/rv64/rv64_decode.sv $repo/rtl/rv64/dual/rv64_dual_regfile.sv $repo/rtl/rv64/turnpayload/rv64_lsu.sv $repo/rtl/rv64/fastmul/rv64_muldiv.sv $repo/rtl/rv64/seip/rv64_dual_csr.sv $repo/rtl/rv64/rv64_atomic.sv $repo/rtl/rv64/rv64_mmu.sv $repo/rtl/rv64/seip/rv64_dual_core.sv $repo/rtl/rv64/rv64_axi_transfer.sv $repo/rtl/rv64/dual/rv64_dual_icache.sv $repo/rtl/rv64/dual/rv64_dual_cache_arbiter.sv $repo/rtl/rv64/rv64_cache_fence.sv $repo/rtl/rv64/takenbp/rv64_branch_predictor.sv $repo/rtl/rv64/rvc/rv64_rvc_decode.sv $repo/rtl/rv64/fp/rv64_fp_state.sv $repo/rtl/rv64/fpintpipe/rv64_fp_execute.sv $repo/third_party/HardFloat-1-compat/source/HardFloat_primitives.v $repo/third_party/HardFloat-1-compat/source/HardFloat_rawFN.v $repo/third_party/HardFloat-1-compat/source/addRecFN.v $repo/third_party/HardFloat-1-compat/source/compareRecFN.v $repo/third_party/HardFloat-1-compat/source/divSqrtRecFN_small.v $repo/third_party/HardFloat-1-compat/source/fNToRecFN.v $repo/third_party/HardFloat-1-compat/source/iNToRecFN.v $repo/third_party/HardFloat-1-compat/source/isSigNaNRecFN.v $repo/third_party/HardFloat-1-compat/source/mulAddRecFN.v $repo/third_party/HardFloat-1-compat/source/mulRecFN.v $repo/third_party/HardFloat-1-compat/source/recFNToFN.v $repo/third_party/HardFloat-1-compat/source/recFNToIN.v $repo/third_party/HardFloat-1-compat/source/recFNToRecFN.v $repo/third_party/HardFloat-1-compat/source/RISCV/HardFloat_specialize.v $repo/rtl/rv64/board/rv64_ddr_window.sv $repo/rtl/rv64/board/rv64_clint.sv $repo/rtl/rv64/board/rv64_boot_rom.sv $repo/rtl/rv64/board/rv64_board_system_video.sv $repo/rtl/rv64/dmacache/rv64_dcache.sv $repo/rtl/rv64/board/rv64_dma_cache_control.sv $repo/rtl/rv64/board/rv64_board_decode_video.sv $repo/rtl/rv64/board/rv64_plic.sv $repo/rtl/rv64/video/rv64_scanout_control.sv $repo/rtl/rv64/video/rv64_ddr_scanout.sv $repo/rtl/rv64/video/rv64_frame_axi_reader.sv $repo/rtl/rv64/video/rv64_pixel_async_fifo.sv $repo/rtl/rv64/video/rv64_pixel_consumer.sv $repo/rtl/rv64/video/rv64_video_timing.sv $repo/rtl/rv64/video/rv64_tmds_encoder.sv $repo/third_party/HardFloat-1-compat/source/HardFloat_consts.vi $repo/third_party/HardFloat-1-compat/source/HardFloat_localFuncs.vi $repo/third_party/HardFloat-1-compat/source/RISCV/HardFloat_specialize.vi $root/rtl/gc_video_board.v $root/rtl/rv64_tmds_serializer_7series.sv]
 set_property file_type {Verilog Header} [get_files *.vi]
 set_property include_dirs [list $repo/third_party/HardFloat-1-compat/source $repo/third_party/HardFloat-1-compat/source/RISCV] [current_fileset]
 file copy $root/reference/board.bd $work/bd/design_1/design_1.bd
 add_files $work/bd/design_1/design_1.bd
 open_bd_design $work/bd/design_1/design_1.bd
 set ps [get_bd_cells processing_system7_0]
 set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 0 CONFIG.PCW_USE_S_AXI_HP0 1 CONFIG.PCW_S_AXI_HP0_DATA_WIDTH 64 CONFIG.PCW_USE_S_AXI_HP1 1 CONFIG.PCW_S_AXI_HP1_DATA_WIDTH 64 CONFIG.PCW_USE_S_AXI_GP0 1 CONFIG.PCW_USE_FABRIC_INTERRUPT 1 CONFIG.PCW_P2F_USB0_INTR 1] $ps
 if {[llength [get_bd_pins -quiet processing_system7_0/IRQ_P2F_USB0]]!=1} {error "Missing USB0 PS-to-fabric IRQ"}
 set cpu [create_bd_cell -type module -reference gc_video_board cpu]
 foreach interface {DDR_AXI PS_AXI SCAN_AXI} {if {[llength [get_bd_intf_pins -quiet cpu/$interface]]!=1} {error "Missing CPU $interface interface"}}
 connect_bd_net [get_bd_pins processing_system7_0/IRQ_P2F_USB0] [get_bd_pins cpu/usb_irq_i]
 set ddr [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 ddr_protocol]
 set_property -dict [list CONFIG.SI_PROTOCOL AXI4 CONFIG.MI_PROTOCOL AXI3 CONFIG.DATA_WIDTH 64 CONFIG.ADDR_WIDTH 32 CONFIG.ID_WIDTH 1 CONFIG.TRANSLATION_MODE 2] $ddr
 set scan [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 scan_protocol]
 set_property -dict [list CONFIG.SI_PROTOCOL AXI4 CONFIG.MI_PROTOCOL AXI3 CONFIG.DATA_WIDTH 64 CONFIG.ADDR_WIDTH 32 CONFIG.ID_WIDTH 1 CONFIG.TRANSLATION_MODE 2] $scan
 connect_bd_intf_net [get_bd_intf_pins cpu/SCAN_AXI] [get_bd_intf_pins scan_protocol/S_AXI]
 connect_bd_intf_net [get_bd_intf_pins scan_protocol/M_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP1]
 set mmio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 mmio_protocol]
 set_property -dict [list CONFIG.SI_PROTOCOL AXI4 CONFIG.MI_PROTOCOL AXI3 CONFIG.DATA_WIDTH 32 CONFIG.ADDR_WIDTH 32 CONFIG.ID_WIDTH 1 CONFIG.TRANSLATION_MODE 2] $mmio
 set width [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dwidth_converter:2.1 mmio_width]
 set_property -dict [list CONFIG.PROTOCOL AXI4 CONFIG.ADDR_WIDTH 32 CONFIG.SI_DATA_WIDTH 64 CONFIG.MI_DATA_WIDTH 32 CONFIG.SI_ID_WIDTH 1 CONFIG.ACLK_ASYNC 0] $width
 connect_bd_intf_net [get_bd_intf_pins cpu/DDR_AXI] [get_bd_intf_pins ddr_protocol/S_AXI]
 connect_bd_intf_net [get_bd_intf_pins ddr_protocol/M_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]
 connect_bd_intf_net [get_bd_intf_pins cpu/PS_AXI] [get_bd_intf_pins mmio_width/S_AXI]
 connect_bd_intf_net [get_bd_intf_pins mmio_width/M_AXI] [get_bd_intf_pins mmio_protocol/S_AXI]
 connect_bd_intf_net [get_bd_intf_pins mmio_protocol/M_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_GP0]
 set reset [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 reset]
 set_property -dict [list CONFIG.C_AUX_RESET_HIGH 1] $reset
 set zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 zero]
 set_property -dict [list CONFIG.CONST_WIDTH 1 CONFIG.CONST_VAL 0] $zero
 set vio [create_bd_cell -type ip -vlnv xilinx.com:ip:vio:3.0 control]
 set_property -dict [list CONFIG.C_NUM_PROBE_IN 14 CONFIG.C_NUM_PROBE_OUT 2 CONFIG.C_PROBE_OUT1_WIDTH 1 CONFIG.C_PROBE_OUT1_INIT_VAL 0x1 CONFIG.C_PROBE_IN8_WIDTH 32 CONFIG.C_PROBE_IN9_WIDTH 32 CONFIG.C_PROBE_IN10_WIDTH 32 CONFIG.C_PROBE_IN11_WIDTH 32 CONFIG.C_PROBE_IN12_WIDTH 32 CONFIG.C_PROBE_IN13_WIDTH 1 CONFIG.C_PROBE_OUT0_WIDTH 1 CONFIG.C_PROBE_OUT0_INIT_VAL 0x1 CONFIG.C_PROBE_IN0_WIDTH 64 CONFIG.C_PROBE_IN1_WIDTH 64 CONFIG.C_PROBE_IN2_WIDTH 64 CONFIG.C_PROBE_IN3_WIDTH 32 CONFIG.C_PROBE_IN4_WIDTH 32 CONFIG.C_PROBE_IN5_WIDTH 32 CONFIG.C_PROBE_IN6_WIDTH 32 CONFIG.C_PROBE_IN7_WIDTH 32] $vio
 foreach {p q} {commit_pc 0 commit_cause 1 time_value 2 status 3 fence_complete 4 icache_miss 5 dcache_miss 6 dcache_writeback 7 scan_status_o 8 scan_bursts_o 9 scan_beats_o 10 scan_frames_o 11 scan_failed_o 12 clocks_locked_o 13} {connect_bd_net [get_bd_pins cpu/$p] [get_bd_pins control/probe_in$q]}
 set clk [create_bd_port -dir I -type clk -freq_hz 50000000 sys_clk]
 set key [create_bd_port -dir I -type rst key1_n]
 set_property CONFIG.POLARITY ACTIVE_LOW $key
 connect_bd_net $clk [get_bd_pins cpu/clk] [get_bd_pins control/clk] [get_bd_pins reset/slowest_sync_clk] [get_bd_pins scan_protocol/aclk] [get_bd_pins processing_system7_0/S_AXI_HP1_ACLK] [get_bd_pins ddr_protocol/aclk] [get_bd_pins mmio_protocol/aclk] [get_bd_pins mmio_width/s_axi_aclk] [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK] [get_bd_pins processing_system7_0/S_AXI_GP0_ACLK]
 connect_bd_net $key [get_bd_pins reset/ext_reset_in] [get_bd_pins cpu/clock_resetn]
 # VIO holds the CPU, fabric and BOTH AXI adapters in one common reset during load.
 connect_bd_net [get_bd_pins control/probe_out0] [get_bd_pins reset/aux_reset_in]
 connect_bd_net [get_bd_pins cpu/clocks_locked_o] [get_bd_pins reset/dcm_locked]
 connect_bd_net [get_bd_pins control/probe_out1] [get_bd_pins cpu/commit_enable]
 connect_bd_net [get_bd_pins zero/dout] [get_bd_pins reset/mb_debug_sys_rst]
 connect_bd_net [get_bd_pins reset/peripheral_aresetn] [get_bd_pins cpu/resetn] [get_bd_pins scan_protocol/aresetn] [get_bd_pins ddr_protocol/aresetn] [get_bd_pins mmio_protocol/aresetn] [get_bd_pins mmio_width/s_axi_aresetn]
 # Pixel scanout continues while commit_enable=0; common reset is coordinated.
 set hp [create_bd_port -dir I hdmi_hpd]
 connect_bd_net $hp [get_bd_pins cpu/hpd_i]
 foreach {port pin} {hdmi_p tmds_p_o hdmi_n tmds_n_o} {
  set ext [create_bd_port -dir O -from 3 -to 0 $port]
  connect_bd_net $ext [get_bd_pins cpu/$pin]
 }
 set vm [create_bd_cell -type ip -vlnv xilinx.com:ip:vio:3.0 video_monitor]
 set_property -dict [list CONFIG.C_NUM_PROBE_IN 10 CONFIG.C_NUM_PROBE_OUT 1 CONFIG.C_PROBE_OUT0_WIDTH 1 CONFIG.C_PROBE_OUT0_INIT_VAL 0x0 CONFIG.C_PROBE_IN0_WIDTH 32 CONFIG.C_PROBE_IN1_WIDTH 32 CONFIG.C_PROBE_IN2_WIDTH 32 CONFIG.C_PROBE_IN3_WIDTH 32 CONFIG.C_PROBE_IN4_WIDTH 32 CONFIG.C_PROBE_IN5_WIDTH 32 CONFIG.C_PROBE_IN6_WIDTH 32 CONFIG.C_PROBE_IN7_WIDTH 32 CONFIG.C_PROBE_IN8_WIDTH 11 CONFIG.C_PROBE_IN9_WIDTH 10] $vm
 connect_bd_net [get_bd_pins cpu/pixel_clk_o] [get_bd_pins video_monitor/clk]
 foreach {p q} {video_status_o 0 video_crc_o 1 video_good_o 2 video_bad_o 3 video_underflow_o 4 video_marker_o 5 video_dropped_o 6 video_pixels_o 7 video_hpos_o 8 video_vpos_o 9} {connect_bd_net [get_bd_pins cpu/$p] [get_bd_pins video_monitor/probe_in$q]}
 assign_bd_address
 validate_bd_design
 if {[get_property CONFIG.C_EXT_RESET_HIGH $reset]!=0 || [get_property CONFIG.C_AUX_RESET_HIGH $reset]!=1} {error "Actual inferred common-reset polarities changed"}

 proc same_net {pins} {
  set want ""
  foreach p $pins {
   set pin [get_bd_pins $p];set net [get_bd_nets -of_objects $pin]
   if {[llength $pin]!=1 || [llength $net]!=1} {error "Missing exact BD pin/net: $p"}
   if {$want eq ""} {set want $net} elseif {$want ne $net} {error "BD net differs: $pins"}
  }
 }
 same_net {cpu/clocks_locked_o reset/dcm_locked control/probe_in13}
 same_net {cpu/clock_resetn reset/ext_reset_in}
 same_net {control/probe_out0 reset/aux_reset_in}
 same_net {control/probe_out1 cpu/commit_enable}
 same_net {reset/peripheral_aresetn cpu/resetn ddr_protocol/aresetn scan_protocol/aresetn mmio_protocol/aresetn mmio_width/s_axi_aresetn}
 same_net {cpu/clk scan_protocol/aclk processing_system7_0/S_AXI_HP1_ACLK}
 same_net {cpu/pixel_clk_o video_monitor/clk}
 same_net {cpu/usb_irq_i processing_system7_0/IRQ_P2F_USB0}
 if {[get_property CONFIG.PCW_S_AXI_HP1_DATA_WIDTH $ps]!=64} {error "HP1 not64bit"}
 save_bd_design
 write_bd_tcl -force $root/reports/full-r1/recreate-board-r1.tcl
 set f [open $root/reports/full-r1/ip-contract-r1.txt w]
 foreach cell [list $cpu $ddr $scan $width $mmio $ps $reset $vio $vm] {puts $f [report_property -return_string $cell]}
 puts $f [get_bd_addr_spaces]
 puts $f [get_bd_addr_segs]
 close $f
 add_files -fileset constrs_1 $root/constraints/board-r1.xdc
 set_property top design_1_wrapper [current_fileset]

 generate_target all [get_files design_1.bd]
 add_files [make_wrapper -files [get_files design_1.bd] -top]
 set_property top design_1_wrapper [current_fileset]
 update_compile_order -fileset sources_1
 set_property STEPS.OPT_DESIGN.TCL.PRE $root/scripts/linked-cdc-constraints-r2.tcl [get_runs impl_1]
 launch_runs synth_1 -jobs 1
 wait_on_run synth_1
 if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "R106 synthesis failed"}
 launch_runs impl_1 -to_step route_design -jobs 1
 wait_on_run impl_1
 if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "R106 implementation failed"}
 open_run impl_1
 write_checkpoint -force $root/reports/full-r1/routed.dcp
 report_timing_summary -report_unconstrained -file $root/reports/full-r1/timing-summary.rpt
 report_utilization -file $root/reports/full-r1/utilization.rpt
 report_utilization -hierarchical -file $root/reports/full-r1/hierarchy.rpt
 check_timing -verbose -file $root/reports/full-r1/timing-checks.rpt
 report_clocks -file $root/reports/full-r1/clocks.rpt
 report_clock_interaction -file $root/reports/full-r1/clock-interaction.rpt
 report_bus_skew -file $root/reports/full-r1/bus-skew.rpt
 report_exceptions -file $root/reports/full-r1/exceptions.rpt
 report_drc -file $root/reports/full-r1/drc.rpt
 report_route_status -file $root/reports/full-r1/route-status.rpt
 report_cdc -details -file $root/reports/full-r1/cdc.rpt
 foreach kind {max min} {
  report_timing -from [all_registers -clock_pins] -to [all_registers -data_pins] -delay_type $kind -max_paths 30 -file $root/reports/full-r1/internal-$kind.rpt
  set p [get_timing_paths -from [all_registers -clock_pins] -to [all_registers -data_pins] -delay_type $kind -max_paths 1]
  if {[llength $p]!=1 || [get_property SLACK $p]<0} {error "R106 internal $kind timing failed"}
 }
 set f [open $root/reports/full-r1/cdc.rpt r];set cdc [read $f];close $f
 if {[regexp {CDC-[0-9]+[ 	]+Critical} $cdc]} {error "R106 critical CDC requires diagnosis"}
 if {[llength [get_drc_violations -quiet -filter {SEVERITY == "Error" || SEVERITY == "Critical Warning"}]]} {error "R106 DRC error/critical"}
 write_debug_probes -force $root/reports/full-r1/debug.ltx
 # No bitstream until independent routed reset/CDC/PS-source and external IO audit.
 puts R106_ROUTED_CHECKPOINT_READY_REQUIRES_INDEPENDENT_AUDIT_NO_BITSTREAM_OR_DEPLOYMENT
 close_project
}
if {[catch build message options]} {puts stderr "R106_FULL_BOARD_FAIL: $message";puts stderr [dict get $options -errorinfo];exit 1}
exit 0
