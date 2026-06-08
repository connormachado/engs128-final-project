# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "C_S_AXI_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXI_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "G_ACC_BITS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "G_IO_BITS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "G_MAC_BITS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "G_NUM_MACS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "G_N_ATOMS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "G_N_CHUNKS" -parent ${Page_0}


}

proc update_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to update C_S_AXI_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to validate C_S_AXI_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to update C_S_AXI_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to validate C_S_AXI_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.G_ACC_BITS { PARAM_VALUE.G_ACC_BITS } {
	# Procedure called to update G_ACC_BITS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_ACC_BITS { PARAM_VALUE.G_ACC_BITS } {
	# Procedure called to validate G_ACC_BITS
	return true
}

proc update_PARAM_VALUE.G_IO_BITS { PARAM_VALUE.G_IO_BITS } {
	# Procedure called to update G_IO_BITS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_IO_BITS { PARAM_VALUE.G_IO_BITS } {
	# Procedure called to validate G_IO_BITS
	return true
}

proc update_PARAM_VALUE.G_MAC_BITS { PARAM_VALUE.G_MAC_BITS } {
	# Procedure called to update G_MAC_BITS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_MAC_BITS { PARAM_VALUE.G_MAC_BITS } {
	# Procedure called to validate G_MAC_BITS
	return true
}

proc update_PARAM_VALUE.G_NUM_MACS { PARAM_VALUE.G_NUM_MACS } {
	# Procedure called to update G_NUM_MACS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_NUM_MACS { PARAM_VALUE.G_NUM_MACS } {
	# Procedure called to validate G_NUM_MACS
	return true
}

proc update_PARAM_VALUE.G_N_ATOMS { PARAM_VALUE.G_N_ATOMS } {
	# Procedure called to update G_N_ATOMS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_N_ATOMS { PARAM_VALUE.G_N_ATOMS } {
	# Procedure called to validate G_N_ATOMS
	return true
}

proc update_PARAM_VALUE.G_N_CHUNKS { PARAM_VALUE.G_N_CHUNKS } {
	# Procedure called to update G_N_CHUNKS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_N_CHUNKS { PARAM_VALUE.G_N_CHUNKS } {
	# Procedure called to validate G_N_CHUNKS
	return true
}


proc update_MODELPARAM_VALUE.G_IO_BITS { MODELPARAM_VALUE.G_IO_BITS PARAM_VALUE.G_IO_BITS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_IO_BITS}] ${MODELPARAM_VALUE.G_IO_BITS}
}

proc update_MODELPARAM_VALUE.G_MAC_BITS { MODELPARAM_VALUE.G_MAC_BITS PARAM_VALUE.G_MAC_BITS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_MAC_BITS}] ${MODELPARAM_VALUE.G_MAC_BITS}
}

proc update_MODELPARAM_VALUE.G_NUM_MACS { MODELPARAM_VALUE.G_NUM_MACS PARAM_VALUE.G_NUM_MACS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_NUM_MACS}] ${MODELPARAM_VALUE.G_NUM_MACS}
}

proc update_MODELPARAM_VALUE.G_N_CHUNKS { MODELPARAM_VALUE.G_N_CHUNKS PARAM_VALUE.G_N_CHUNKS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_N_CHUNKS}] ${MODELPARAM_VALUE.G_N_CHUNKS}
}

proc update_MODELPARAM_VALUE.G_ACC_BITS { MODELPARAM_VALUE.G_ACC_BITS PARAM_VALUE.G_ACC_BITS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_ACC_BITS}] ${MODELPARAM_VALUE.G_ACC_BITS}
}

proc update_MODELPARAM_VALUE.G_N_ATOMS { MODELPARAM_VALUE.G_N_ATOMS PARAM_VALUE.G_N_ATOMS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_N_ATOMS}] ${MODELPARAM_VALUE.G_N_ATOMS}
}

proc update_MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH { MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_DATA_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH { MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_ADDR_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH}
}

