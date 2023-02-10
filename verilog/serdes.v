/*
 * HDMI deserializer; outputs raw 10 bit values on every pixel clock.
 *
 * Requires a 5x or 10x PLL from the pixel clock.
 * Clock input should use a global buffer input
 * -- app note says " Global Buffer Input 7 (GBIN7) is the only one that supports differential clock inputs."
 * -- but experimentally only 37 works.
 *
 * Pair Inputs must use negative pin of differential pairs.
 * The positive pin *must not be mentioned* as an input.
 *
 * The bit clock and pixel clock have a constant, but unknown phase.
 * We should have a "tracking" function that tries to ensure it lines up.
 *
 * https://www.analog.com/en/design-notes/video-display-signals-and-the-max9406-dphdmidvi-level-shifter8212part-i.html
 * H sync and audio header on Blue
 * Audio data on Red and Green
 * Data island period is encoded with TERC4; can we ignore it?
 *
 */
`default_nettype none
`include "hdmi_pll.v"
`include "tmds.v"


// Deserialize 10 input bits into a 10-bit register,
// clocking on the rising edge of the bit clock.
// the bit clock and pixel clock must be synchronized
// to avoid metastability
module hdmi_shift(
	input clk,
	input bit_clk,
	input in_p,
	output bit,
	output [7:0] data,
	output data_valid,
	output [1:0] sync,
	output sync_valid,
	output [3:0] ctrl,
	output ctrl_valid
);
	reg [9:0] shift;
	reg [9:0] latch;

	wire in0, in1;

	SB_IO #(
		.PIN_TYPE(6'b000000),
		.IO_STANDARD("SB_LVDS_INPUT")
	) diff_io (
		.PACKAGE_PIN(in_p),
		.INPUT_CLK(bit_clk),
		.D_IN_0(in0),
		.D_IN_1(in1)
	);

	// DDR on the bit clock allows us to run at half the speed
	always @(posedge bit_clk)
		shift <= { shift[7:0], in1, in0 };
	assign bit = in0;

	// capture all of the deserialized bits on the pixel clock
	always @(posedge clk)
		latch <= shift;

	// decode the TMDS encoded bits; ignore the terc4 for now
	wire [3:0] terc4;

	tmds_decode decoder(
		// inputs
		.clk(clk),
		.in(latch),

		// outputs
		.data_valid(data_valid),
		.sync_valid(sync_valid),
		.ctrl_valid(ctrl_valid),
		.data(data),
		.sync(sync),
		.ctrl(terc4)
	);
endmodule

module hdmi_raw(
	input d0_p,
	input d1_p,
	input d2_p,
	input clk_p,
	input [3:0] pll_delay,
	output [7:0] d0,
	output [7:0] d1,
	output [7:0] d2,
	output data_valid,
	output sync_valid,
	output hsync,
	output vsync,
	output locked,
	output clk,
	output bit_clk
);
	wire clk;
	wire bit_clk;

	SB_GB_IO #(
		.PIN_TYPE(6'b000000),
		.IO_STANDARD("SB_LVDS_INPUT")
	) differential_clock_input (
		.PACKAGE_PIN(clk_p),
		.GLOBAL_BUFFER_OUTPUT(clk)
	);

	hdmi_pll pll(
		.clock_in(clk),
		.clock_out(bit_clk),
		.locked(locked),
		.delay(pll_delay)
	);

	// the blue channel is where the control codes and TERC4
	// data is encoded. the d1 and d2 contain audio samples during
	// this time period
	// TODO: implement the data island detection using the
	// hdmi_control bits
	wire data_valid;
	wire sync_valid;
	wire [1:0] sync;
	wire hsync = sync[0];
	wire vsync = sync[1];

	hdmi_shift d0_shift(
		.clk(clk),
		.bit_clk(bit_clk),
		.in_p(d0_p),
		.data(d0),
		.data_valid(data_valid),
		.sync(sync),
		.sync_valid(sync_valid)
	);

	// red has audio samples in the data island period
	hdmi_shift d1_shift(
		.clk(clk),
		.bit_clk(bit_clk),
		.in_p(d1_p),
		.data(d1)
	);

	// green has audio samples in the data island period
	hdmi_shift d2_shift(
		.clk(clk),
		.bit_clk(bit_clk),
		.in_p(d2_p),
		.data(d2)
	);
endmodule


module top(
	output serial_txd,
	input serial_rxd,
	output spi_cs,
	output led_r,

	// debug output
	output gpio_28,
	output gpio_2,

	// hdmi clock 
	input gpio_37, // pair input gpio_4,

	// hdmi pairs 36/43, 38/42, 26/27
	input gpio_43, // pair input gpio_36,
	input gpio_42, // pair input gpio_38,
	input gpio_26, // pair input gpio_27
);
	assign spi_cs = 1; // it is necessary to turn off the SPI flash chip
	reg reset = 0;
	wire clk_48mhz;
	SB_HFOSC inthosc(.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(clk_48mhz));


	wire hdmi_clk, hdmi_locked, hdmi_bit_clk;
	wire [7:0] hdmi_d0;
	wire [7:0] hdmi_d1;
	wire [7:0] hdmi_d2;
	wire sync_valid, hsync, vsync;

	reg [3:0] pll_delay = 0;

	hdmi_raw hdmi(
		// physical inputs
		.clk_p(gpio_37),
		.d0_p(gpio_42),
		.d1_p(gpio_43),
		.d2_p(gpio_26),

		// tuning for bit clock
		.pll_delay(pll_delay),

		// outputs
		.clk(hdmi_clk),
		.bit_clk(hdmi_bit_clk),
		.locked(hdmi_locked),
		.d0(hdmi_d0),
		.d1(hdmi_d1),
		.d2(hdmi_d2),
		.sync_valid(sync_valid),
		.hsync(hsync),
		.vsync(vsync)
	);

	reg [24:0] hdmi_counter;
	reg [24:0] hdmi_clk_counter;
	assign led_r = !hdmi_clk_counter[24];

	assign gpio_28 = hsync;
	reg gpio_2;

	always @(posedge hdmi_clk)
	begin
		if (hdmi_locked)
			hdmi_clk_counter <= hdmi_clk_counter + 1;
		else
			gpio_2 <= 0;

		pll_delay <= hdmi_clk_counter[24:21];
		gpio_2 <= sync_valid;
	end

	always @(posedge hdmi_bit_clk)
	begin
		if (hdmi_locked)
			hdmi_counter <= hdmi_counter + 1;
		else
			hdmi_counter <= 0;
	end
endmodule
