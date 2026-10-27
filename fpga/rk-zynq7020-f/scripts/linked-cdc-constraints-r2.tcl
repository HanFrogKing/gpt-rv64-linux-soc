# Executed with actual linked board netlist before opt/place/route.
set root D:/ysyx/projects/rk-zynq7020-bringup/rv64gc-scanout-r106
set hpd [get_pins -hier -regexp {.*cpu.*/inst/hpd_q_reg\[0\]/D}]
if {[llength $hpd]!=1} {error "Expected one actual HPD first-stage D"}
foreach {lane pos neg} {0 AA17 AB17 1 U17 V17 2 U15 U16 3 W16 Y16} {
 foreach {pol want} [list p $pos n $neg] {
  set port [get_ports [format {hdmi_%s[%d]} $pol $lane]]
  if {[get_property PACKAGE_PIN $port] ne $want || [get_property IOSTANDARD $port] ne "TMDS_33"} {error "Explicit HDMI constraint failed"}
 }
}
set specs {
 {.*cpu.*/inst/system/video_control/request_sync_q_reg\[0\]} 20.000 1
 {.*cpu.*/inst/system/video_control/ack_sync_q_reg\[0\]} 25.000 1
 {.*cpu.*/inst/system/video_control/data_meta_q_reg\[[0-9]+\]} 20.000 256
 {.*cpu.*/inst/system/scanout/fifo/wr_gray_meta_q_reg\[[0-9]+\]} 20.000 11
 {.*cpu.*/inst/system/scanout/fifo/rd_gray_meta_q_reg\[[0-9]+\]} 25.000 11
}
set f [open $root/reports/full-r1/linked-cdc-contract.txt w]
foreach {dest bound count} $specs {
 set dc [get_cells -hier -regexp $dest]
 if {[llength $dc]!=$count} {error "CDC count $dest wanted$count actual[llength $dc]"}
 set d [get_pins -of_objects $dc -filter {REF_PIN_NAME == D}]
 set q [get_pins -leaf -of_objects [get_nets -segments -of_objects $d] -filter {DIRECTION == OUT}]
 if {[llength $q]!=$count} {error "CDC source count $dest"}
 foreach pin $q {if {[get_property REF_PIN_NAME $pin] ne "Q"} {error "CDC source not registered $pin"}}
 set sc [get_cells -of_objects $q]
 set_max_delay -datapath_only $bound -from $sc -to $dc
 set_false_path -hold -from $sc -to $dc
 if {$count>1} {set_bus_skew $bound -from $sc -to $dc}
 puts $f "$dest count$count bound$bound"
 foreach c $dc {puts $f "DEST $c"}
 foreach p $q {puts $f "SOURCE $p"}
}
close $f
write_xdc -force $root/reports/full-r1/linked-constraints.xdc
puts R106_LINKED_CDC_280_REGISTERED_PATHS_AND_EXPLICIT_HDMI_PINS_CONSTRAINED
