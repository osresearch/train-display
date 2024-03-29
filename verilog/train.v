/*
 * NS Train Displays
 *
 * Very similar to a RGB LED matrix, except for the weird layout,
 * four bit address and only a single channel instead of RGB.
 */
//`include "util.v"
`include "uart.v"
`include "spi_display.v"

`define HDMI_DISPLAY
`undef SPI_DISPLAY
`undef UART_DISPLAY

`define MIN_X 2
`define MIN_Y 64
`define PANEL_WIDTH 104
`define PANEL_HEIGHT 32
`define PANEL_PITCH 128


module ram(
	// read domain
	input rd_clk,
	input [ADDR_WIDTH-1:0] rd_addr,
	output [DATA_WIDTH-1:0] rd_data,
	// write domain
	input wr_clk,
	input wr_enable,
	input [ADDR_WIDTH-1:0] wr_addr,
	input [DATA_WIDTH-1:0] wr_data,
);
	parameter ADDR_WIDTH=8;
	parameter DATA_WIDTH=8;
	parameter NUM_BYTES=256;

	reg [DATA_WIDTH-1:0] mem[0:NUM_BYTES-1];
	reg [DATA_WIDTH-1:0] rd_data;

        //initial $readmemh("packed0.hex", mem);
        initial $readmemh("fb-init.hex", mem);

	always @(posedge rd_clk)
		rd_data <= mem[rd_addr];
	//assign rd_data = mem[rd_addr];

	always @(posedge wr_clk)
		if (wr_enable)
			mem[wr_addr] <= wr_data;
endmodule

// for speed of receiving the HDMI signals, the framebuffer is stored in
// normal layout with a power-of-two pitch.
// the actual LED matrix might be weird, so turn a linear offset
// into a framebuffer offset.
//
// external display is 104 wide 32 high, but mapped like:
//
// 10 skip eight    30 repeat 13 times 190
// |           \    |                  |
// 1f           \   3f                 19f -> go back to second column
// 00 1a0        \->20                 180
// |  |             |                  |
// 0f 1af           2f                 18f
// 

module display_mapper(
	input [12:0] linear_addr,
	output [12:0] ram_addr
);
	parameter PANEL_SHIFT_WIDTH = (13 * 32) / 32;

	wire y_bank = linear_addr[4];
	wire [4:0] y_addr = linear_addr[3:0] + (y_bank ? 0 : 16);

	wire [12:0] x_value = linear_addr[12:5];
	wire [12:0] x_offset;
	reg [2:0] x_minor;
	reg [12:0] x_major;

	always @(*)
	begin
		if (x_value >= 7 * PANEL_SHIFT_WIDTH) begin
			x_minor = 7;
			x_major = x_value - 7 * PANEL_SHIFT_WIDTH;
		end else
		if (x_value >= 6 * PANEL_SHIFT_WIDTH) begin
			x_minor = 6;
			x_major = x_value - 6 * PANEL_SHIFT_WIDTH;
		end else
		if (x_value >= 5 * PANEL_SHIFT_WIDTH) begin
			x_minor = 5;
			x_major = x_value - 5 * PANEL_SHIFT_WIDTH;
		end else
		if (x_value >= 4 * PANEL_SHIFT_WIDTH) begin
			x_minor = 4;
			x_major = x_value - 4 * PANEL_SHIFT_WIDTH;
		end else
		if (x_value >= 3 * PANEL_SHIFT_WIDTH) begin
			x_minor = 3;
			x_major = x_value - 3 * PANEL_SHIFT_WIDTH;
		end else
		if (x_value >= 2 * PANEL_SHIFT_WIDTH) begin
			x_minor = 2;
			x_major = x_value - 2 * PANEL_SHIFT_WIDTH;
		end else
		if (x_value >= 1 * PANEL_SHIFT_WIDTH) begin
			x_minor = 1;
			x_major = x_value - 1 * PANEL_SHIFT_WIDTH;
		end else begin
			x_minor = 0;
			x_major = x_value;
		end
	end

	wire [12:0] x_addr = x_major*8 + x_minor;

	assign ram_addr = x_addr + y_addr * `PANEL_PITCH;
endmodule


module top(
	output serial_txd,
	input serial_rxd,
	output spi_cs,
	output led_r,

	output gpio_38, // debug
	output gpio_42, // debug

	// SPI display input from Pi
	input gpio_45, // cs
	input gpio_47, // dc
	input gpio_46, // di
	input gpio_2, // clk

	// LED display module
	output gpio_23, // data out
	output gpio_25, // latch
	output gpio_26, // clk
	output gpio_27, // !enable
	output gpio_32, // a3
	output gpio_35, // a2
	output gpio_31, // a1
	output gpio_37, // a0
	output gpio_34 // data out 2
);
	assign spi_cs = 1; // it is necessary to turn off the SPI flash chip
	reg reset = 0;
	wire clk_48mhz;
	SB_HFOSC inthosc(.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(clk_48mhz));

	// 12 Mhz output clock
	reg clk;
	always @(posedge clk_48mhz)
		clk = !clk;
/*
	// 24 Mhz output clock, needs better wires
	wire clk = clk_48mhz;
*/

	reg led_r;

	// dual port block ram for the frame buffer
	// 128 * 48 == 6114 bytes (inside display)
	// 2 * 104 * 32 == 6656 bytes (ouside display)
	parameter ADDR_WIDTH = 13;
	wire [ADDR_WIDTH-1:0] read_addr;
	wire [7:0] read_data0;
	wire [7:0] read_data1;

	reg write_enable0 = 0;
	reg write_enable1 = 0;
	reg [ADDR_WIDTH-1:0] write_addr = 0;
	reg [7:0] write_data = 0;

/*
	reg [7:0] mem[0:128*48-1];
        initial $readmemh("fb-init.hex", mem);
	assign read_data = mem[read_addr];
*/

`ifdef UART_DISPLAY
	// memory writes are in the uart domain
	wire wr_clk = clk;
`endif
`ifdef SPI_DISPLAY
	// memory writes are in the spi_clk domain
	wire spi_tft_cs = gpio_45;
	wire spi_tft_dc = gpio_47;
	wire spi_tft_di = gpio_46;
	wire spi_tft_clk = gpio_2;
	wire wr_clk = spi_tft_clk;
`endif
`ifdef HDMI_DISPLAY
	// memory writes are in the hdmi pclk domain
	// todo: wider inputs for the incoming data
	wire hdmi_vsync = gpio_2;
	wire hdmi_en = gpio_46;
	wire hdmi_clk = gpio_47;
	wire hdmi_di = gpio_45;
	wire wr_clk = hdmi_clk;
`endif


	ram #(
		.DATA_WIDTH(8),
		.ADDR_WIDTH(ADDR_WIDTH),
		.NUM_BYTES(`PANEL_PITCH * `PANEL_HEIGHT)
	) fb0(
		.rd_clk(clk),
		.rd_addr(read_addr),
		.rd_data(read_data0),
		.wr_clk(wr_clk),
		.wr_enable(write_enable0),
		.wr_addr(write_addr),
		.wr_data(write_data)
	);
	ram #(
		.DATA_WIDTH(8),
		.ADDR_WIDTH(ADDR_WIDTH),
		.NUM_BYTES(`PANEL_PITCH * `PANEL_HEIGHT)
	) fb1(
		.rd_clk(clk),
		.rd_addr(read_addr),
		.rd_data(read_data1),
		.wr_clk(wr_clk),
		.wr_enable(write_enable1),
		.wr_addr(write_addr),
		.wr_data(write_data)
	);


	// outside display module has 3 address lines, force addr3 == 0
	assign gpio_32 = 0;

	// turn the linear addresses from the led matrix into frame buffer read addresses for the RAM
	wire [ADDR_WIDTH-1:0] linear_addr;
	display_mapper mapper(linear_addr, read_addr);

	led_matrix #(
		// internal display 4 address lines, 32 * 128
		//.DISP_ADDR_WIDTH(4),
		//.DISPLAY_WIDTH(13'd384), // 24 * 16
		// external display is 3 address lines, 32 * 104
		.DISP_ADDR_WIDTH(3),
		.DISPLAY_WIDTH(416), // 13 columns * 16 * 2
		.FB_ADDR_WIDTH(ADDR_WIDTH)
	) disp0(
		.clk(clk),
		.reset(reset),
		// physical interface
		.data_out(gpio_34),
		.clk_out(gpio_26),
		.latch_out(gpio_25),
		.enable_out(gpio_27),
		//.addr_out({gpio_32, gpio_35, gpio_31, gpio_37}), // inside 4 bits
		.addr_out({gpio_35, gpio_31, gpio_37}), // outside 3 address bits
		// logical interface
		.data_in(read_data0),
		.data_addr(linear_addr)
	);

	led_matrix #(
		// internal display 4 address lines, 32 * 128
		//.DISP_ADDR_WIDTH(4),
		//.DISPLAY_WIDTH(13'd384), // 24 * 16
		// external display is 3 address lines, 32 * 104
		.DISP_ADDR_WIDTH(3),
		.DISPLAY_WIDTH(416), // 26 * 16 * 2
		.FB_ADDR_WIDTH(ADDR_WIDTH)
	) disp1(
		.clk(clk),
		.reset(reset),
		// physical interface (only data is used)
		.data_out(gpio_23),
		// logical interface
		.data_in(read_data1),
		//.data_addr(read_addr)
	);

	// generate a 3 MHz/12 MHz serial clock from the 48 MHz clock
	// this is the 3 Mb/s maximum supported by the FTDI chip
	reg [3:0] baud_clk;
	always @(posedge clk_48mhz) baud_clk <= baud_clk + 1;
	//assign gpio_38 = baud_clk[3];
	reg gpio_38;
	reg gpio_42;

	wire [7:0] uart_rxd;
	wire uart_rxd_strobe;

	reg [7:0] uart_txd;
	reg uart_txd_strobe;

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
		.data(uart_txd),
		.data_strobe(uart_txd_strobe)
	);

`ifdef UART_DISPLAY
	reg [11:0] addr_x = 0;
	reg [11:0] addr_y = 0;

	always @(posedge clk)
		if (!uart_rxd_strobe)
		begin
			led_r <= 1;
			write_enable0 <= 0;
			write_enable1 <= 0;
			uart_txd_strobe <= 0;
		end else
		begin
			led_r <= 0;
			write_enable0 <= 1;
			write_enable1 <= 1;
			write_data <= uart_rxd;

			write_addr <= addr_x + `PANEL_PITCH * addr_y;

			// echo it
			uart_txd <= uart_rxd;
			uart_txd_strobe <= 1;

			if (addr_x >= `PANEL_WIDTH)
			begin
				addr_x <= 0;

				if (addr_y >= `PANEL_HEIGHT)
					addr_y <= 0;
				else
					addr_y <= addr_y + 1;
			end else begin
				addr_x <= addr_x + 1;
			end
		end
`endif
`ifdef SPI_DISPLAY
	// SPI display from the Raspberry Pi
	wire spi_tft_strobe;
	wire [15:0] spi_tft_pixels;
	wire [15:0] addr_x;
	wire [15:0] addr_y;
	wire [5:0] spi_tft_r = { spi_tft_pixels[15:11], 1'b0 };
	wire [5:0] spi_tft_g = spi_tft_pixels[10:5];
	wire [5:0] spi_tft_b = { spi_tft_pixels[4:0], 1'b0 };

	spi_display spi_display0(
		// windowing is not yet supported
		//.x_start(x_start),
		//.y_start(y_start),
		//.x_end(x_end),
		//.y_end(y_end),

		// debug serial port
		.debug(led_r),
		.uart_strobe(uart_txd_strobe),
		.uart_data(uart_txd),

		// physical interface
		.spi_cs(spi_tft_cs),
		.spi_dc(spi_tft_dc),
		.spi_di(spi_tft_di),
		.spi_clk(spi_tft_clk),

		// incoming data
		.pixels(spi_tft_pixels),
		.strobe(spi_tft_strobe),
		.x(addr_x),
		.y(addr_y)
	);

	wire [15:0] addr_y_offset = addr_y - `MIN_Y;
	wire [15:0] addr_x_offset0 = addr_x - `MIN_X;
	wire [15:0] addr_x_offset1 = addr_x - `MIN_X - `PANEL_WIDTH;
	wire panel = `MIN_X + `PANEL_WIDTH <= addr_x;
	wire [15:0] addr_x_offset = panel ? addr_x_offset1 : addr_x_offset0;

	always @(posedge spi_tft_clk)
	if (spi_tft_strobe
	&& `MIN_Y <= addr_y && addr_y < `MIN_Y + `PANEL_HEIGHT
	&& `MIN_X <= addr_x && addr_x < `MIN_X + 2 * `PANEL_WIDTH
	) begin
		// new pixel!
		write_enable0 <= panel == 0;
		write_enable1 <= panel == 1;

		if (addr_y_offset < 16)
			write_addr <= addr_x_offset[2:0] * 4 * `PANEL_WIDTH + addr_x_offset[7:3] * `PANEL_HEIGHT + (addr_y_offset + 16);
		else
			write_addr <= addr_x_offset[2:0] * 4 * `PANEL_WIDTH + addr_x_offset[7:3] * `PANEL_HEIGHT+ (addr_y_offset - 16);
	
		// average the RGB to make grayscale
		write_data <= spi_tft_r + spi_tft_b + spi_tft_r;
	end else begin
		write_enable0 <= 0;
		write_enable1 <= 0;
	end
`endif
`ifdef HDMI_DISPLAY
	reg [11:0] addr_x; // up to 4k
	reg [11:0] addr_y; // up to 4k
	reg last_hdmi_en;

	// todo: cut down the number of bits in the offset values
	wire [6:0] addr_y_offset = addr_y - `MIN_Y;
	wire [11:0] addr_x_offset0 = addr_x - `MIN_X;
	wire [11:0] addr_x_offset1 = addr_x - `MIN_X - `PANEL_WIDTH;
	wire panel = `MIN_X + `PANEL_WIDTH <= addr_x;
	wire [11:0] addr_x_offset = panel ? addr_x_offset1 : addr_x_offset0;
	wire x_in_range = (`MIN_X <= addr_x) && (addr_x < `MIN_X + 2 * `PANEL_WIDTH);
	wire y_in_range = (`MIN_Y <= addr_y) && (addr_y < `MIN_Y + 1 * `PANEL_HEIGHT);
	wire in_range = x_in_range && y_in_range;
	//wire write_enable0 = in_range && panel == 0;
	//wire write_enable1 = in_range && panel == 1;


	// vsync  000010000000000000000
	// en     111000000101010101010
	always @(posedge hdmi_clk)
	begin
		gpio_38 <= hdmi_vsync;
		gpio_42 <= hdmi_en;
	end

	always @(posedge hdmi_clk)
	begin
		write_enable0 <= 0;
		write_enable1 <= 0;
		last_hdmi_en <= hdmi_en;

		if (hdmi_vsync == 1)
		begin
			// high vsync restarts the x and y, DE is not set yet
			led_r <= 0;
			addr_x <= 0;
			addr_y <= 0;
		end
		else
		if (hdmi_en == 0)
		begin
			// do nothing until we have pixel data
			led_r <= 1;
		end
		else if (last_hdmi_en == 0)
		begin
			// start of a new scan line
			last_hdmi_en <= 1;
			addr_x <= 0;
			addr_y <= addr_y + 1;
		end else begin
			// normal pixel data, EN=1 and last EN=1
			addr_x <= addr_x + 1;

			// store this new pixel if it is in range
			write_enable0 <= (panel == 0) && in_range;
			write_enable1 <= (panel == 1) && in_range;

			// store this with a fixed pitch
			write_addr <= addr_x_offset + addr_y_offset * `PANEL_PITCH;
		
			// todo: average the RGB to make grayscale
			write_data <= !hdmi_di ? 8'h80 : 8'h00;
			//write_data <= addr_x_offset[0] ^ addr_y_offset[0] ? 8'h80 : 8'h00;
		end
	end
`endif

endmodule


module led_matrix(
	input clk,
	input reset,
	// physical
	output data_out,
	output clk_out,
	output latch_out,
	output enable_out,
	output [DISP_ADDR_WIDTH-1:0] addr_out,
	// framebuffer
	output [FB_ADDR_WIDTH-1:0] data_addr,
	input [DATA_WIDTH-1:0] data_in
);
	parameter DISP_ADDR_WIDTH = 4;
	parameter DISPLAY_WIDTH = 32;
	parameter FB_ADDR_WIDTH = 8;
	parameter DATA_WIDTH = 8;

	reg clk_out;
	reg latch_out;
	reg data_out;
	reg enable_out;
	reg [DISP_ADDR_WIDTH-1:0] addr_out;
	reg [DISP_ADDR_WIDTH-1:0] addr;

	reg [FB_ADDR_WIDTH-1:0] x_index;
	reg [FB_ADDR_WIDTH-1:0] data_addr;

	reg [FB_ADDR_WIDTH-1:0] counter;
	reg [30:0] counter_timer;

	// usable brightness values start around 0x40
	reg [2:0] latch_counter = 0;
	reg [7:0] brightness = 8'hFF;

	always @(posedge clk)
	begin
		clk_out <= 0;

		counter_timer <= counter_timer + 1;
		enable_out <= !(brightness > counter_timer[7:0]);

		if (reset)
		begin
			counter <= 0;
			enable_out <= 1;
			data_addr <= ~0;
			x_index <= 0;
			addr_out <= 0;
			addr <= 0;
			data_out <= 0;
			latch_counter <= 0;
			brightness <= 8'h80;
		end else
		if (latch_out)
		begin
			// unlatch and re-enable the display
			latch_out <= 0;
			//enable_out <= 0;

			// if this has wrapped the display,
			// start over on reading the frame buffer
			if (addr == 0)
				data_addr <= 0;
			// hold the clock high
			clk_out <= 1;
		end else
		if (x_index == DISPLAY_WIDTH)
		begin
			if (latch_counter == 7)
			begin
				// done with this scan line, reset for the next time
				addr <= addr + 1;
				brightness <= 8'hFF; // last one, so make it bright
			end else begin
				// redraw the same scan line a few times at different brightness levels
				data_addr <= data_addr - DISPLAY_WIDTH;
				brightness <= brightness + 8'h18;
			end

			// latch this data and ensure that the correct matrix row is selected
			latch_out <= 1;
			addr_out <= addr;
			latch_counter <= latch_counter + 1;

			// start a new scan line
			x_index <= 0;
			// hold the clock high
			clk_out <= 1;
		end else
		if (clk_out == 1)
		begin
			// falling edge of the clock, prepare the next output
			// use binary-coded pulse modulation, so turn on the output
			// based on each bit and the current brightness level
			if (data_in[latch_counter])
				data_out <= 1;
			else
				data_out <= 0;

			x_index <= x_index + 1;

			// start the fetch for the next address
			data_addr <= data_addr + 1;
		end else begin
			// rising edge of the clock, new data should be ready
			// and stable, so mark it
			clk_out <= 1;
		end
	end
endmodule
