# Exact routed checkpoint only. No new synth/route, waiver or hardware I/O.
if {[catch {
 set root [file normalize [lindex $argv 0]]
 set out $root/reports/bitstream-r1
 if {[file exists $out]} {error "Preserve previous bitstream attempt"}
 file mkdir $out
 set_param general.maxThreads 1
 open_checkpoint $root/reports/full-r1/routed.dcp
 if {[get_property PART [current_design]] ne "xc7z020clg484-2"} {error "Wrong FPGA part"}
 write_bitstream $out/rv64gc-scanout.bit
 file copy $root/reports/full-r1/debug.ltx $out/debug.ltx
 puts R106_EXACT_ROUTED_BITSTREAM_GENERATED_NOT_PROGRAMMED
 close_design
} msg opts]} {puts stderr "R106_BITSTREAM_FAIL: $msg";puts stderr [dict get $opts -errorinfo];exit 1}
exit 0
