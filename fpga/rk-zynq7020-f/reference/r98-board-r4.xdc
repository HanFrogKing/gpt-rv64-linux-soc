set_property -dict {PACKAGE_PIN W17 IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -name sys_clk -period 20.000 [get_ports sys_clk]
set_input_jitter [get_clocks sys_clk] 0.200
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports key1_n]
set_false_path -from [get_ports key1_n]

# Explicit physical assignments, no control-flow in XDC. User sys/key clock
# constraints are retained from the frozen top synthesis checkpoint.
set_property -dict {PACKAGE_PIN AA17 IOSTANDARD TMDS_33} [get_ports {hdmi_p[0]}]
set_property -dict {PACKAGE_PIN AB17 IOSTANDARD TMDS_33} [get_ports {hdmi_n[0]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD TMDS_33} [get_ports {hdmi_p[1]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD TMDS_33} [get_ports {hdmi_n[1]}]
set_property -dict {PACKAGE_PIN U15 IOSTANDARD TMDS_33} [get_ports {hdmi_p[2]}]
set_property -dict {PACKAGE_PIN U16 IOSTANDARD TMDS_33} [get_ports {hdmi_n[2]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD TMDS_33} [get_ports {hdmi_p[3]}]
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD TMDS_33} [get_ports {hdmi_n[3]}]
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports hdmi_hpd]

# Only the asynchronous external HPD input to its actual first-stage D.
set_false_path -from [get_ports hdmi_hpd] -to [get_pins -hier -regexp {.*video.*/inst/hpd_q_reg\[0\]/D}]
