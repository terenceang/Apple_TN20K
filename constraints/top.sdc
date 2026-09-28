## Timing constraints for Apple //e on Tang Nano 20K
##
## Without this file nextpnr-gowin has no declared clock frequency and
## falls back to an internal 12 MHz default target. Constrain the real
## input clock; nextpnr-gowin automatically propagates this through the
## rPLL and the CLKDIV that derives clk_pixel, so both domains get
## analyzed against their real frequencies (confirmed in build output:
## clocks 'u_clk_gen.clk_in' and 'clk_pixel' are both reported).
create_clock -name clk -period 37.037 [get_ports {clk}]
create_clock -name clk_in -period 37.037 [get_nets {u_clk_gen.clk_in}]
create_clock -name clk_pixel -period 37.037 [get_nets {clk_pixel}]
