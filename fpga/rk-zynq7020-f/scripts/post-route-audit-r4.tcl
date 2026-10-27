# Read-only routed checkpoint audit: no timing exceptions/constraints are changed.
if {[catch {
 set root [file normalize [lindex $argv 0]]
 set out $root/reports/full-r1/post-audit-r4
 if {[file exists $out]} {error "Preserve previous audit attempt"}
 if {![file exists $root/reports/full-r1/routed.dcp]} {error "No actual routed checkpoint"}
 file mkdir $out
 set_param general.maxThreads 1
 open_checkpoint $root/reports/full-r1/routed.dcp
 report_timing_summary -report_unconstrained -file $out/timing-summary.rpt
 check_timing -verbose -file $out/timing-checks.rpt
 report_clocks -file $out/clocks.rpt
 report_clock_interaction -file $out/clock-interaction.rpt
 report_bus_skew -file $out/bus-skew.rpt
 report_exceptions -file $out/exceptions.rpt
 report_drc -file $out/drc.rpt
 report_route_status -file $out/route-status.rpt
 report_methodology -checks {TIMING-6 TIMING-7} -file $out/clock-methodology.rpt
 proc finite_slack {p why} {
  if {[llength $p]!=1} {error "Missing unique actual timing path: $why"}
  set s [get_property SLACK $p]
  if {![string is double -strict $s] || $s<0 || $s>1000} {error "Failing/unconstrained $why: $s"}
  return $s
 }
 set mm [get_cells -hier -filter {REF_NAME =~ MMCME2*}]
 if {[llength $mm]!=1} {error "Expected one actual MMCM"}
 set cf [open $out/clock-primitives.txt w]
 set pixelClock ""
 foreach {pin period} {CLKOUT0 25.000 CLKOUT1 5.000} {
  set clk [get_clocks -of_objects [get_pins $mm/$pin]]
  if {[llength $clk]!=1 || abs([get_property PERIOD $clk]-$period)>.001 || [get_property MASTER_CLOCK $clk] ne "sys_clk"} {error "Wrong MMCM generated clock $pin/$clk"}
  if {$pin eq "CLKOUT0"} {set pixelClock $clk}
  puts $cf [report_property -return_string $clk]
 }
 puts $cf [report_property -return_string $mm]
 set ser [get_cells -hier -filter {REF_NAME == OSERDESE2}]
 set ob [get_cells -hier -filter {REF_NAME == OBUFDS}]
 if {[llength $ser]!=8 || [llength $ob]!=4} {error "Wrong physical serialization primitive count"}
 foreach c [concat $ser $ob] {puts $cf [report_property -return_string $c]}
 close $cf
 foreach {lane pos neg} {0 AA17 AB17 1 U17 V17 2 U15 U16 3 W16 Y16} {
  foreach {pol want} [list p $pos n $neg] {
   set port [get_ports [format {hdmi_%s[%d]} $pol $lane]]
   if {[get_property PACKAGE_PIN $port] ne $want || [get_property IOSTANDARD $port] ne "TMDS_33"} {error "Wrong actual HDMI pin/standard"}
  }
 }
 if {[get_property PACKAGE_PIN [get_ports hdmi_hpd]] ne "Y18" || [get_property IOSTANDARD [get_ports hdmi_hpd]] ne "LVCMOS33"} {error "Wrong HPD pin"}
 proc audit_sync {meta sync out tag} {
  if {[llength $meta]!=1 || [llength $sync]!=1} {error "$tag exact synchronization pair absent"}
  foreach c [list $meta $sync] {if {![get_property ASYNC_REG $c]} {error "$tag missing ASYNC_REG"}}
  set q [get_pins -of_objects $meta -filter {REF_PIN_NAME == Q}]
  set d [get_pins -of_objects $sync -filter {REF_PIN_NAME == D}]
  set loads [get_pins -leaf -of_objects [get_nets -segments -of_objects $q] -filter {DIRECTION == IN}]
  if {[llength $loads]!=1 || $loads ne $d} {error "$tag meta extra fanout: $loads"}
  set f [open $out/$tag-chain.txt w]
  puts $f [report_property -return_string $meta];puts $f [report_property -return_string $sync]
  puts $f "FIRST_STAGE_LOADS $loads"
  foreach kind {max min} {
   set p [get_timing_paths -delay_type $kind -from $q -to $d -max_paths 1]
   finite_slack $p "$tag interstage $kind"
   puts $f [report_property -return_string $p]
   puts $f [report_timing -from $q -to $d -delay_type $kind -return_string]
  }
  close $f
 }
 set meta [get_cells -hier -filter {NAME =~ *usb_meta_q_reg}]
 set sync [get_cells -hier -filter {NAME =~ *usb_sync_q_reg}]
 audit_sync $meta $sync $out usb
 audit_sync [get_cells -hier -regexp {.*cpu.*/inst/hpd_q_reg\[0\]}] [get_cells -hier -regexp {.*cpu.*/inst/hpd_q_reg\[1\]}] $out hpd
 set md [get_pins -of_objects $meta -filter {REF_PIN_NAME == D}]
 set src [get_pins -leaf -of_objects [get_nets -segments -of_objects $md] -filter {DIRECTION == OUT}]
 if {[llength $src]!=1 || [get_property REF_NAME [get_cells -of_objects $src]] ne "PS7" || [get_property REF_PIN_NAME $src] ne {IRQP2F[15]}} {error "USB input not actual PS7 USB0 IRQ15"}
 set f [open $out/usb-hardmacro-source.txt w];puts $f [report_property -return_string $src]
 puts $f "PS hardmacro IRQ lacks standard CDC source clock; explicit driver/2ASYNC_REG/first-stage-only fanout/interstage timing supplement, not analog metastability proof."
 close $f
 set specs {
  {.*cpu.*/inst/system/video_control/request_sync_q_reg\[0\]} 20.000 1
  {.*cpu.*/inst/system/video_control/ack_sync_q_reg\[0\]} 25.000 1
  {.*cpu.*/inst/system/video_control/data_meta_q_reg\[[0-9]+\]} 20.000 256
  {.*cpu.*/inst/system/scanout/fifo/wr_gray_meta_q_reg\[[0-9]+\]} 20.000 11
  {.*cpu.*/inst/system/scanout/fifo/rd_gray_meta_q_reg\[[0-9]+\]} 25.000 11
 }
 set f [open $out/cdc-datapaths.txt w];set total 0
 foreach {pattern bound count} $specs {
  set dc [get_cells -hier -regexp $pattern]
  if {[llength $dc]!=$count} {error "Actual CDC endpoints $pattern count[llength $dc]"}
  set d [get_pins -of_objects $dc -filter {REF_PIN_NAME == D}]
  set q [get_pins -leaf -of_objects [get_nets -segments -of_objects $d] -filter {DIRECTION == OUT}]
  if {[llength $q]!=$count} {error "Actual CDC source count"}
  foreach p $q {if {[get_property REF_PIN_NAME $p] ne "Q"} {error "CDC source combinational"}}
  set ps [get_timing_paths -delay_type max -from $q -to $d -max_paths 400 -nworst 1]
  if {[llength $ps]!=$count} {error "Actual CDC paths missing"}
  foreach p $ps {
   set slack [finite_slack $p $pattern]
   set req [get_property REQUIREMENT $p]
   if {abs($req-$bound)>.001} {error "Actual max-delay requirement $req != $bound"}
   puts $f "[get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p] slack=$slack requirement=$req"
   incr total
  }
 }
 if {$total!=280} {error "CDC total not280"};close $f
 # Do not false-path the bus-common reset into the related pixel clock.
 set resetPin [get_pins -hier -regexp {.*cpu.*/inst/resetn}]
 if {[llength $resetPin]!=1} {error "Actual common reset boundary absent/ambiguous"}
 # all_fanin -startpoints_only returns clock pins for sequential startpoints
 # in Vivado. Resolve actual electrical driver Q on this reset net instead.
 set resetStarts [get_pins -leaf -of_objects [get_nets -segments -of_objects $resetPin] -filter {DIRECTION == OUT}]
 if {[llength $resetStarts]!=1} {error "Common reset must have one actual leaf driver"}
 if {![llength $resetStarts]} {error "No sequential common reset release source"}
 foreach pin $resetStarts {
  if {[get_property REF_PIN_NAME $pin] ne "Q"} {error "Common reset release not registered: $pin"}
  set c [get_cells -of_objects $pin]
  set clk [get_clocks -of_objects [get_pins -of_objects $c -filter {REF_PIN_NAME == C}]]
  if {$clk ne "sys_clk"} {error "Common reset not released on50MHz: $pin/$clk"}
 }
 set rpins {}
 foreach p [all_fanout -flat -endpoints_only -from $resetPin] {
  if {[get_property REF_PIN_NAME $p] ne "CLR"} {continue}
  set c [get_cells -of_objects $p]
  set clk [get_clocks -of_objects [get_pins -of_objects $c -filter {REF_PIN_NAME == C}]]
  if {$clk eq $pixelClock} {lappend rpins $p}
 }
 if {![llength $rpins]} {error "No common-reset pixel recovery/removal paths"}
 set f [open $out/common-reset-pixel-paths.txt w]
 puts $f "ACTUAL_BOUNDARY $resetPin ACTUAL_RELEASE_SOURCES $resetStarts ENDPOINT_COUNT [llength $rpins]"
 foreach p $rpins {
  foreach kind {max min} {
   set tp [get_timing_paths -from $resetStarts -to $p -delay_type $kind -max_paths 1]
   finite_slack $tp "common reset -> $p $kind"
   puts $f [report_property -return_string $tp]
   report_timing -from $resetStarts -to $p -delay_type $kind -append -file $out/common-reset-pixel-timing.rpt
  }
 }
 close $f
 foreach kind {max min} {
  set p [get_timing_paths -from [all_registers -clock_pins] -to [all_registers -data_pins] -delay_type $kind -max_paths 1]
  finite_slack $p "all internal $kind"
  report_timing -from [all_registers -clock_pins] -to [all_registers -data_pins] -delay_type $kind -max_paths 30 -file $out/internal-$kind.rpt
  report_timing -to [get_ports hdmi*] -delay_type $kind -max_paths 30 -file $out/hdmi-$kind.rpt
 }
 set f [open $out/synchronizers.txt w]
 foreach c [get_cells -hier -filter {ASYNC_REG == TRUE}] {puts $f "[get_property NAME $c] [get_property REF_NAME $c] [get_property LOC $c]"};close $f
 # The main run already emitted report_cdc for this immutable routed checkpoint.
 # Reuse its pinned report rather than run an identical lengthy analysis twice.
 if {![file exists $root/reports/full-r1/cdc.rpt]} {error "No main CDC report for same routed checkpoint"}
 file copy $root/reports/full-r1/cdc.rpt $out/cdc-same-routed-checkpoint.rpt
 puts R106_INDEPENDENT_ROUTED_CLOCK_PIN_USB_CDC_RESET_AUDIT_COMPLETE_REQUIRES_REPORT_REVIEW_NOT_BOARD_ACCEPTANCE
 close_design
} msg opts]} {puts stderr "R106_POSTROUTE_AUDIT_FAIL: $msg";puts stderr [dict get $opts -errorinfo];exit 1}
exit 0
