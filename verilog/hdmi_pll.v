/**
 * PLL configuration
 *
 * This Verilog module was generated automatically
 * using the icepll tool from the IceStorm project.
 * Use at your own risk.
 *
 * Given input frequency:        25.000 MHz
 * Requested output frequency:  125.000 MHz
 * Achieved output frequency:   125.000 MHz
 */

module hdmi_pll(
	input  clock_in,
	output clock_out,
	output locked,
	input [3:0] delay
	);

SB_PLL40_CORE #(
		.FEEDBACK_PATH("SIMPLE"),
		.DIVR(4'b0000),		// DIVR =  0
		.DIVF(7'b0100111),	// DIVF = 39
		.DIVQ(3'b011),		// DIVQ =  3
		.FILTER_RANGE(3'b010),	// FILTER_RANGE = 2
		//.DELAY_ADJUSTMENT_MODE_FEEDBACK("DYNAMIC")
	) uut (
		.LOCK(locked),
		.RESETB(1'b1),
		.BYPASS(1'b0),
		.REFERENCECLK(clock_in),
		.PLLOUTCORE(clock_out),
		.DYNAMICDELAY({delay,4'b0000})
		);

endmodule
