# ================================================================================
# OSVVM Full-BD Simulation - Questa wave set (used by run_sim.sh --full_sim
# --detailed). The observable "data in/out" of the full-BD UUT is the
# management plane (three AXI4-Lite ports), the SGMII serial lanes, and
# MDIO -- the client AXIS interfaces are internal to the BD (README 2.3).
# ================================================================================

add wave -divider "Clocks & Reset"
add wave /TbFullBd/SystemResetn
add wave /TbFullBd/ClocksLocked
add wave /TbFullBd/AxiClk

add wave -divider "SGMII serial lanes (cross-loopback)"
add wave /TbFullBd/SgmiiIngressTxP
add wave /TbFullBd/SgmiiEgressTxP

add wave -divider "MDIO"
add wave /TbFullBd/MdioIngress
add wave /TbFullBd/MdioEgress

add wave -divider "Ingress MAC AXI4-Lite (s_axi_ingress)"
add wave /TbFullBd/IngAwValid
add wave /TbFullBd/IngAwReady
add wave -hex /TbFullBd/IngAwAddr
add wave -hex /TbFullBd/IngWData
add wave /TbFullBd/IngWValid
add wave /TbFullBd/IngBValid
add wave /TbFullBd/IngArValid
add wave /TbFullBd/IngArReady
add wave -hex /TbFullBd/IngArAddr
add wave -hex /TbFullBd/IngRData
add wave /TbFullBd/IngRValid

add wave -divider "Egress MAC AXI4-Lite (s_axi_egress)"
add wave /TbFullBd/EgrAwValid
add wave /TbFullBd/EgrAwReady
add wave -hex /TbFullBd/EgrAwAddr
add wave -hex /TbFullBd/EgrWData
add wave /TbFullBd/EgrWValid
add wave /TbFullBd/EgrBValid
add wave /TbFullBd/EgrArValid
add wave /TbFullBd/EgrArReady
add wave -hex /TbFullBd/EgrArAddr
add wave -hex /TbFullBd/EgrRData
add wave /TbFullBd/EgrRValid

add wave -divider "Frame_Stats AXI4-Lite (s_axi_stats)"
add wave /TbFullBd/StsAwValid
add wave -hex /TbFullBd/StsAwAddr
add wave -hex /TbFullBd/StsWData
add wave /TbFullBd/StsArValid
add wave /TbFullBd/StsArReady
add wave -hex /TbFullBd/StsArAddr
add wave -hex /TbFullBd/StsRData
add wave /TbFullBd/StsRValid

configure wave -namecolwidth 360
configure wave -valuecolwidth 120
configure wave -signalnamewidth 1
