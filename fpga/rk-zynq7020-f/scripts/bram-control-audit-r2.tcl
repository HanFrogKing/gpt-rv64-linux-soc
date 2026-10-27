# Reporting-only expansion; no timing exception, design or severity change.
if {[catch {
 set root [file normalize [lindex $argv 0]]
 set out $root/reports/bram-audit-r2
 if {[file exists $out]} {error "Preserve previous BRAM audit"}
 file mkdir $out
 set_param general.maxThreads 1
 open_checkpoint $root/reports/full-r1/routed.dcp
 set check [get_drc_checks REQP-1839]
 set f [open $out/rule-properties-before.txt w];puts $f [report_property -return_string $check];close $f
 # MAX_MESSAGES is an actual writable rule property discovered locally. Raise
 # only the reporting cap, never disable a check, waive it or lower severity.
 set_property MAX_MESSAGES 100000 $check
 if {[get_property SEVERITY $check] ne "Warning" || ![get_property IS_ENABLED $check]} {error "Rule must remain enabled at original severity"}
 set f [open $out/rule-properties-after.txt w];puts $f [report_property -return_string $check];close $f
 report_drc -checks {REQP-1839} -no_waivers -verbose -file $out/async-control-expanded.rpt
 set violations [get_drc_violations]
 set warningCells {}
 set f [open $out/actual-violation-objects.txt w]
 set n 0
 foreach v $violations {
  if {[string match {REQP-1839*} [get_property NAME $v]]} {
   incr n
   foreach c [get_cells -of_objects $v] {
    if {[get_property REF_NAME $c] ne "RAMB36E1"} {dict set warningCells $c 1}
   }
   puts $f "VIOLATION $v CELLS [get_cells -of_objects $v] PINS [get_pins -of_objects $v]"
  }
 }
 puts $f "ACTUAL_REQP1839_OBJECT_COUNT $n";close $f
 if {$n==0 || $n>=100000} {error "Missing or capped actual BRAM control inventory"}
 # Check whether all actual asynchronous source controls belong to the
 # single common reset, rather than assuming that from source code alone.
 set resetPin [get_pins -hier -regexp {.*cpu.*/inst/resetn}]
 if {[llength $resetPin]!=1} {error "Missing common reset boundary"}
 set resetQ [get_pins -leaf -of_objects [get_nets -segments -of_objects $resetPin] -filter {DIRECTION == OUT}]
 if {[llength $resetQ]!=1 || [get_property REF_PIN_NAME $resetQ] ne "Q"} {error "Common reset electrical driver not Q"}
 set resetCell [get_cells -of_objects $resetQ]
 set f [open $out/warning-source-reset-origins.txt w]
 puts $f "COMMON_RESET_Q $resetQ SOURCE_CELL_COUNT [dict size $warningCells]"
 set resetNets {}
 foreach c [dict keys $warningCells] {
  set rps [get_pins -of_objects $c -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]
  if {![llength $rps]} {error "Warning source not an actual asynchronous-control cell: $c"}
  foreach rp $rps {
   set net [get_nets -segments -of_objects $rp]
   dict lappend resetNets $net $c
  }
 }
 # Query each shared control net once, not for every duplicate warning path.
 foreach net [dict keys $resetNets] {
  set driven [get_pins -leaf -of_objects $net -filter {DIRECTION == IN && (REF_PIN_NAME == CLR || REF_PIN_NAME == PRE)}]
  set rp [lindex $driven 0]
  set starts [all_fanin -flat -startpoints_only -to $rp]
  if {![llength $starts]} {error "Missing asynchronous source reset origin"}
  foreach sp $starts {
   if {[get_cells -of_objects $sp] ne $resetCell} {error "Independent async source reset discovered: $rp $sp"}
  }
  puts $f "RESET_NET $net WARNING_SOURCE_CELLS [llength [dict get $resetNets $net]] REPRESENTATIVE_PIN $rp STARTPOINTS $starts"
 }
 puts $f "RESET_NET_COUNT [dict size $resetNets]";close $f
 set brams [get_cells -hier -filter {REF_NAME == RAMB36E1}]
 if {[llength $brams]!=5} {error "Unexpected actual RAM count"}
 set f [open $out/actual-bram-control-connectivity.txt w]
 foreach c $brams {
  puts $f "RAM $c"
  puts $f [report_property -return_string $c]
  foreach p [get_pins -of_objects $c -filter {DIRECTION == IN}] {
   if {![regexp {^(ADDR|EN|WE|RST|CLK)} [get_property REF_PIN_NAME $p]]} {continue}
   set drivers [get_pins -leaf -of_objects [get_nets -segments -of_objects $p] -filter {DIRECTION == OUT}]
   puts $f "CONTROL $p LEAF_DRIVERS $drivers"
   if {[regexp {^CLK} [get_property REF_PIN_NAME $p]]} {puts $f "CLOCK $p [get_clocks -of_objects $p]"}
  }
 }
 close $f
 puts "R106_BRAM_CONTROL_RAW_AUDIT_COMPLETE_COUNT_${n}_REQUIRES_SEMANTIC_REVIEW_NOT_DEPLOYMENT"
 close_design
} msg opts]} {puts stderr "R106_BRAM_AUDIT_FAIL: $msg";puts stderr [dict get $opts -errorinfo];exit 1}
exit 0
