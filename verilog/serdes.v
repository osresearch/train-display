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
 * V+H sync and audio header on Blue (D0)
 * Audio data on Red and Green
 * Data island period is encoded with TERC4; can we ignore it?
 *
 * sync pulses are active low
 * H sync keeps pulsing while V is low (twice)
 * V sync is 63 usec, every 60 Hz
 * H sync is 4 usec, every 32 usec
 *
 */
`default_nettype none
`include "hdmi_pll.v"
`include "tmds.v"
`include "mem.v"
`include "uart.v"


// Deserialize 10 input bits into a 10-bit register,
// clocking on the rising edge of the bit clock using a DDR pin
// to capture two bits per clock (the PLL clock runs at 5x the TMDS clock)
// the bits are sent LSB first
module tmds_shift_register_ddr(
	input bit_clk,
	input in_p,
	output [9:0] out
);
	reg [9:0] out;
	wire in0, in1;

	SB_IO #(
		.PIN_TYPE(6'b000000),
		.IO_STANDARD("SB_LVDS_INPUT")
	) diff_io (
		.PACKAGE_PIN(in_p),
		.INPUT_CLK(bit_clk),
		.D_IN_0(in0), // pos edge of bit_clk
		.D_IN_1(in1)  // neg edge of bit_clk
	);

	always @(posedge bit_clk)
		out <= { in0, in1, out[9:2] };
endmodule

// non ddr version
module tmds_shift_register(
	input bit_clk,
	input in_p,
	output [9:0] out
);
	reg [9:0] out;
	wire in0;

	SB_IO #(
		.PIN_TYPE(6'b000000),
		.IO_STANDARD("SB_LVDS_INPUT")
	) diff_io (
		.PACKAGE_PIN(in_p),
		.INPUT_CLK(bit_clk),
		.D_IN_0(in0) // pos edge of bit_clk
	);

	always @(posedge bit_clk)
		out <= { in0, out[9:1] };
endmodule

// detect a control messgae in the shift register and use it to resync our pixel clock
// tracks if our clock is still in sync with the old values
module tmds_sync_recognizer(
	input bit_clk,
	input [9:0] in,
	output pixel_strobe,
	output valid
);
	//parameter CTRL_00 = 10'b1101010100; // 354
	//parameter CTRL_01 = 10'b0010101011; // 0AB
	//parameter CTRL_10 = 10'b0101010100; // 154
	parameter CTRL_11 = 10'b1010101011; // 2AB

	//reg [9:0] counter = 0;
	//wire pixel_clk = counter[9];
	reg [3:0] counter = 0;
	reg pixel_strobe;
	reg valid = 1; // fuck it we're always valid

	always @(posedge bit_clk)
	begin
		// one time step before the final one so that in contains the word
		// in the same cycle that pixel_strobe is high
		pixel_strobe <= counter == 4'h09;

		// if pixel_strobe is high this cycle, then the next bit is the
		// zeroth of the next word
		if (pixel_strobe)
			counter <= 0;
		else
			counter <= counter + 1;

/*
		// this control word has the most transitions to sync on
		if (in == CTRL_11)
		begin
			if (pixel_strobe)
			begin
				// we are in sync! wonderful.
				valid <= 1;
			end else begin
				// we are not in sync, reset the clk
				valid <= 0;
				//counter <= 0;
				//pixel_strobe <= 0;
			end
		end
*/
	end
endmodule

// Synchronize the three channels with the TMDS clock and unknown phase
// of the bits.  Returns the raw 8b10b encoded values for futher processing
// and a TMDS synchronize clock for the data stream.  The data are only valid
// when locked
module hdmi_raw(
	input d0_p,
	input d1_p,
	input d2_p,
	input clk_p,
	input [3:0] pll_delay,
	output [9:0] d0,
	output [9:0] d1,
	output [9:0] d2,
	output valid, // good pixel data
	output locked, // only timing data
	output clk,
	output bit_clk
);
	wire clk; // 25 MHz decoded from TDMS input
	wire bit_clk; // 250 MHz PLL'ed from TMDS clock (or 125 MHz if DDR)
	wire pixel_strobe, pixel_valid; // when new pixels are detected by the synchronizer
	wire hdmi_locked;
	assign locked = hdmi_locked;
	//assign valid = hdmi_locked && pixel_valid;
	reg valid;

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
		.locked(hdmi_locked),
		.delay(pll_delay)
	);

	// bit_clk domain
	wire [9:0] d0_data;
	wire [9:0] d1_data;
	wire [9:0] d2_data;

	tmds_shift_register d0_shift(
		.bit_clk(bit_clk),
		.in_p(d0_p),
		.out(d0_data)
	);

	tmds_shift_register d1_shift(
		.bit_clk(bit_clk),
		.in_p(d1_p),
		.out(d1_data)
	);

	tmds_shift_register d2_shift(
		.bit_clk(bit_clk),
		.in_p(d2_p),
		.out(d2_data)
	);

	// detect the pixel clock from the PLL'ed bit_clk
	// only channel 0 carries the special command words
	tmds_sync_recognizer d0_sync_recognizer(
		.bit_clk(bit_clk),
		.in(d0_data),
		.pixel_strobe(pixel_strobe),
		.valid(pixel_valid)
	);

	// if we have TMDS clock lock and pixel clock lock,
	// start capturing pixel data in the bit_clk domain
	// when the pixel_strobe signal strobes
	// and transfering it to the clk domain using a flag
	reg pixel_flag = 0, last_pixel_flag;
	reg [9:0] d0_latched = 0;
	reg [9:0] d1_latched = 0;
	reg [9:0] d2_latched = 0;

	// clk domain for output
	reg [9:0] d0 = 0;
	reg [9:0] d1 = 0;
	reg [9:0] d2 = 0;

	always @(posedge bit_clk)
	begin
		// if we have good timing and the pixel clock is valid
		// latched the data and flag it for the clk domain
		if (pixel_strobe)
		begin
			pixel_flag <= ~pixel_flag;
			d0_latched <= d0_data;
			d1_latched <= d1_data;
			d2_latched <= d2_data;
		end
	end

	always @(posedge clk)
	begin
		last_pixel_flag <= pixel_flag;
		valid <= hdmi_locked && pixel_valid;

		// new pixel data! copy it from the latched data into clk domain
		// it may not be valid, but that's not our problem
		if (last_pixel_flag != pixel_flag)
		begin
			d0 <= d0_latched;
			d1 <= d1_latched;
			d2 <= d2_latched;
		end
	end
endmodule

module hdmi_decode(
	input clk,
	input [9:0] hdmi_d0,
	input [9:0] hdmi_d1,
	input [9:0] hdmi_d2,

	output data_valid,
	output [7:0] d0,
	output [7:0] d1,
	output [7:0] d2,

	// these hold value so sync_valid is not necessary
	output sync_valid,
	output hsync,
	output vsync,

	// terc4 data is not used yet
	output ctrl_valid,
	output [3:0] ctrl
);
	tmds_decode d0_decoder(
		.clk(clk),
		.in(hdmi_d0),
		.data(d0),
		.sync({vsync,hsync}),
		.ctrl(ctrl),
		.data_valid(data_valid),
		.sync_valid(sync_valid),
		.ctrl_valid(ctrl_valid),
	);

	// audio data is on d1 and d2, but we don't handle it yet
	tmds_decode d1_decoder(
		.clk(clk),
		.in(hdmi_d1),
		.data(d1),
	);

	tmds_decode d2_decoder(
		.clk(clk),
		.in(hdmi_d2),
		.data(d2),
	);

endmodule


module hdmi_framebuffer(
	input clk,
	input valid,
	input hsync,
	input vsync,
	input data_valid,
	input [7:0] d0,
	input [7:0] d1,
	input [7:0] d2,

	output [ADDR_WIDTH-1:0] waddr,
	output [7:0] wdata,
	output wen
);
	parameter ADDR_WIDTH = 13;
	parameter [11:0] MIN_X = 200;
	parameter [11:0] MIN_Y = 150;
	parameter [11:0] WIDTH = 128;
	parameter [11:0] HEIGHT = 100;

	reg [11:0] xaddr;
	reg [11:0] yaddr;
	reg [ADDR_WIDTH-1:0] waddr;
	reg [7:0] wdata;
	reg wen;

	always @(posedge clk)
	begin
		wen <= 0;

		if (!valid)
		begin
			// literally nothing to do
		end else
		if (!vsync)
		begin
			xaddr <= 0;
			yaddr <= 0;
		end else
		if (!hsync) begin
			xaddr <= 0;
			yaddr <= yaddr + 1;
		end else
		if (data_valid) begin
			xaddr <= xaddr + 1;

			if (MIN_X <= xaddr && xaddr < MIN_X+WIDTH
			&&  MIN_Y <= yaddr && yaddr < MIN_Y+HEIGHT)
				wen <= 1;

			// we only have one channel right now
			// width should be a power of two
			waddr <= (xaddr - MIN_X) + ((yaddr - MIN_Y) * WIDTH);
			wdata <= d0;
		end
	end
endmodule
	

module top(
	output serial_txd,
	input serial_rxd,
	output spi_cs,
	output led_r,
	output led_g,

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
	wire clk = clk_48mhz;


	wire hdmi_clk, hdmi_locked, hdmi_bit_clk;
	wire hdmi_valid;
	wire [9:0] hdmi_d0;
	wire [9:0] hdmi_d1;
	wire [9:0] hdmi_d2;

	wire data_valid;
	wire [7:0] d0;
	wire [7:0] d1;
	wire [7:0] d2;
	wire hsync, vsync;

	// unused for now
	reg [3:0] pll_delay = 0;

	hdmi_raw hdmi_raw_i(
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
		.valid(hdmi_valid),
		.d0(hdmi_d0),
		.d1(hdmi_d1),
		.d2(hdmi_d2),
	);

	hdmi_decode hdmi_decode_i(
		.clk(hdmi_clk),
		.hdmi_d0(hdmi_d0),
		.hdmi_d1(hdmi_d1),
		.hdmi_d2(hdmi_d2),

		// outputs
		.hsync(hsync),
		.vsync(vsync),
		.d0(d0),
		.d1(d1),
		.d2(d2),
		.data_valid(data_valid)
	);

	parameter ADDR_WIDTH = 14;
	parameter WIDTH = 128;
	parameter HEIGHT = 100;

	wire [ADDR_WIDTH-1:0] waddr;
	wire [7:0] wdata;
	wire wen;
	reg [ADDR_WIDTH-1:0] raddr;
	wire [7:0] rdata;
	ram #(
		.ADDR_WIDTH(ADDR_WIDTH),
		.DATA_WIDTH(8),
		.NUM_WORDS(WIDTH*HEIGHT)
	) fb_ram(
		.rd_clk(clk),
		.rd_addr(raddr),
		.rd_data(rdata),
		.wr_clk(hdmi_clk),
		.wr_addr(waddr),
		.wr_enable(wen),
		.wr_data(wdata)
	);

	hdmi_framebuffer #(
		.ADDR_WIDTH(ADDR_WIDTH),
		.WIDTH(WIDTH),
		.HEIGHT(HEIGHT)
	) hdmi_fb(
		.clk(hdmi_clk),
		.valid(hdmi_valid),
		.hsync(hsync),
		.vsync(vsync),
		.data_valid(data_valid),
		.d0(d0),
		.d1(d1),
		.d2(d2),

		// outputs to the ram
		.waddr(waddr),
		.wdata(wdata),
		.wen(wen),
	);


/*
	// store the d0 raw data into a buffer packed with the current delay setting
	reg [11:0] waddr;
	reg [11:0] raddr;
	wire [15:0] rdata;
	ram #(
		.ADDR_WIDTH(12),
		.DATA_WIDTH(16)
	) d0_buf(
		.rd_clk(clk),
		.rd_addr(raddr),
		.rd_data(rdata),
		.wr_clk(hdmi_bit_clk),
		.wr_addr(waddr),
		.wr_enable(hdmi_valid),
		.wr_data({ pll_delay, 2'b00, hdmi_d0})
	);

	always @(posedge hdmi_clk)
	if (hdmi_valid)
		waddr <= waddr + 1;
*/

	// generate a 3 MHz/12 MHz serial clock from the 48 MHz clock
	// this is the 3 Mb/s maximum supported by the FTDI chip
	reg [3:0] baud_clk;
	always @(posedge clk_48mhz)
		baud_clk <= baud_clk + 1;

	wire [7:0] uart_rxd;
	wire uart_rxd_strobe;

	reg [7:0] uart_txd;
	reg uart_txd_strobe;
	wire uart_txd_ready;

	uart_rx rxd(
		.mclk(clk),
		.reset(reset),
		.baud_x4(baud_clk[1]), // 48 MHz / 4 == 12 Mhz
		.serial(serial_rxd),
		.data(uart_rxd),
		.data_strobe(uart_rxd_strobe)
	);

	uart_tx txd(
		.mclk(clk),
		.reset(reset),
		.baud_x1(baud_clk[3]), // 48 MHz / 16 == 3 Mhz
		.serial(serial_txd),
		.ready(uart_txd_ready),
		.data(uart_txd),
		.data_strobe(uart_txd_strobe)
	);

	reg [7:0] extra_data;
	reg wdata_more = 0;
	always @(posedge clk)
	begin
		uart_txd_strobe <= 0;

/*
		if (uart_txd_ready && hdmi_valid && !uart_txd_strobe)
		begin
			if (wdata_more) begin
				uart_txd <= extra_data;
				wdata_more <= 0;
				uart_txd_strobe <= 1;
			end else begin
				{ uart_txd, extra_data } <= rdata;
				raddr <= raddr + 1;
				wdata_more <= 1;
				uart_txd_strobe <= 1;
			end
		end
*/
		if (uart_txd_ready && hdmi_valid && !uart_txd_strobe)
		begin
			uart_txd <= rdata;
			uart_txd_strobe <= 1;

			if (raddr == WIDTH*HEIGHT - 1)
				raddr <= 0;
			else
				raddr <= raddr + 1;
		end
	end

	

	reg [24:0] hdmi_bit_counter;
	reg [24:0] hdmi_clk_counter;
	wire pulse = hdmi_locked && hdmi_clk_counter[24];
	assign led_r = !(pulse && !hdmi_valid); // red means TDMS sync, no pixel data
	assign led_g = !(pulse &&  hdmi_valid); // green means good pixel data

	//assign gpio_28 = hdmi_clk;
	assign gpio_2 = wen; //hsync; // hdmi_valid;
	assign gpio_28 = hsync;

	always @(posedge hdmi_clk)
	begin
		if (hdmi_locked)
			hdmi_clk_counter <= hdmi_clk_counter + 1;
		else
			hdmi_clk_counter <= 0;

		if (hdmi_clk_counter == 25'h1FFFFFF)
			pll_delay <= pll_delay + 1;

		//gpio_28 <= hsync;
	end

	always @(posedge hdmi_bit_clk)
	begin
		if (hdmi_locked)
			hdmi_bit_counter <= hdmi_bit_counter + 1;
		else
			hdmi_bit_counter <= 0;
	end
endmodule
