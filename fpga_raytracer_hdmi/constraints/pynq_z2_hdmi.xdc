# =============================================================
# pynq_z2_hdmi.xdc
#
# HDMI-out pin constraints for the PYNQ-Z2, confirmed against a
# published PYNQ-Z2-compatible base.xdc (the pin locations below
# were read directly out of that file during this session, not
# recalled from memory) and cross-checked against the board
# schematic and official PYNQ base-overlay documentation, both of
# which confirm there is NO external HDMI transmitter chip on this
# board -- the FPGA drives real TMDS differential pairs directly.
#
# Note what's absent: there are no separate hsync/vsync/DE pin
# constraints here, and that's correct, not an oversight -- HDMI/DVI
# uses "embedded sync": hsync and vsync travel inside the TMDS data
# stream itself (as the ctrl bits during blanking -- see
# tmds_encoder.sv), not as separate physical pins the way VGA needs.
#
# Still get the exact pin numbers from YOUR board's current master
# XDC before trusting this blindly -- revisions exist, and Digilent/
# TUL are the authoritative source, not this file.
# =============================================================

## Pixel clock input to the design (drive this from your MMCM/PLL
## output, not directly from a board oscillator pin)
# create_clock -period 40.000 -name pixel_clk [get_ports pixel_clk]

## HDMI TMDS clock channel (differential pair)
set_property PACKAGE_PIN L17 [get_ports hdmi_out_clk_n]
set_property PACKAGE_PIN L16 [get_ports hdmi_out_clk_p]
set_property IOSTANDARD TMDS_33 [get_ports hdmi_out_clk_n]
set_property IOSTANDARD TMDS_33 [get_ports hdmi_out_clk_p]

## HDMI TMDS data channel 0 (blue, by convention)
set_property PACKAGE_PIN K18 [get_ports {hdmi_out_data_n[0]}]
set_property PACKAGE_PIN K17 [get_ports {hdmi_out_data_p[0]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_out_data_n[0]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_out_data_p[0]}]

## HDMI TMDS data channel 1 (green)
set_property PACKAGE_PIN J19 [get_ports {hdmi_out_data_n[1]}]
set_property PACKAGE_PIN K19 [get_ports {hdmi_out_data_p[1]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_out_data_n[1]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_out_data_p[1]}]

## HDMI TMDS data channel 2 (red)
set_property PACKAGE_PIN H18 [get_ports {hdmi_out_data_n[2]}]
set_property PACKAGE_PIN J18 [get_ports {hdmi_out_data_p[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_out_data_n[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_out_data_p[2]}]

## Hot-plug detect (single-ended input from the monitor/cable)
set_property PACKAGE_PIN R19 [get_ports hdmi_out_hpd]
set_property IOSTANDARD LVCMOS33 [get_ports hdmi_out_hpd]

# ---------------- board clock, reset button, LEDs (pins checked against the PYNQ-Z2 pinout) ----------------
set_property PACKAGE_PIN H16 [get_ports sysclk]
set_property IOSTANDARD LVCMOS33 [get_ports sysclk]
create_clock -period 8.000 -name sysclk [get_ports sysclk]
# the MMCM's 125 MHz and 25 MHz outputs are derived automatically by Vivado

set_property PACKAGE_PIN D19 [get_ports btn0]
set_property IOSTANDARD LVCMOS33 [get_ports btn0]
set_false_path -from [get_ports btn0]

# ---------------- walker controls: BTN1..BTN3 and SW0..SW1 ----------------
set_property PACKAGE_PIN D20 [get_ports btn1]
set_property PACKAGE_PIN L20 [get_ports btn2]
set_property PACKAGE_PIN Y16 [get_ports btn3]
set_property PACKAGE_PIN M20 [get_ports {sw[0]}]
set_property PACKAGE_PIN M19 [get_ports {sw[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {btn1 btn2 btn3 sw[*]}]
set_false_path -from [get_ports {btn1 btn2 btn3 sw[*]}]

set_property PACKAGE_PIN R14 [get_ports {led[0]}]
set_property PACKAGE_PIN P14 [get_ports {led[1]}]
set_property PACKAGE_PIN N16 [get_ports {led[2]}]
set_property PACKAGE_PIN M14 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
