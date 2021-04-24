/*
 * NS Train Displays
 *
 * Very similar to a RGB LED matrix, except for the weird layout,
 * four bit address and only a single channel instead of RGB.
 */
//`include "util.v"
//`include "uart.v"

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

	always @(posedge rd_clk)
		rd_data <= mem[rd_addr];

	always @(posedge wr_clk)
		if (wr_enable)
			mem[wr_addr] <= wr_data;
endmodule


module top(
	output serial_txd,
	input serial_rxd,
	output spi_cs,
	output led_r,

	output gpio_38,

	output gpio_23, // data out
	output gpio_25, // latch
	output gpio_26, // clk
	output gpio_27, // !enable
	output gpio_32, // a3
	output gpio_35, // a2
	output gpio_31, // a1
	output gpio_37 // a0
);
	assign spi_cs = 1; // it is necessary to turn off the SPI flash chip
	reg reset = 0;
	wire clk_48mhz;
	SB_HFOSC inthosc(.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(clk_48mhz));

/*
	reg clk;
	always @(posedge clk_48mhz)
		clk = !clk;
*/
	wire clk = clk_48mhz;

	// dual port block ram for the frame buffer
	// 128 * 48 == 6114 bytes
	parameter ADDR_WIDTH = 13;
	wire [ADDR_WIDTH-1:0] read_addr;
	wire [7:0] read_data;

	reg write_enable = 0;
	reg [12:0] write_addr = 0;
	reg [7:0] write_data = 0;

	reg [7:0] mem[0:128*48-1];
        initial $readmemh("fb-init.hex", mem);
	assign read_data = mem[read_addr];

	reg led_r = 1;

/*
	ram #(
		.DATA_WIDTH(8),
		.ADDR_WIDTH(ADDR_WIDTH),
		.NUM_BYTES(128 * 48)
	) fb0(
		.rd_clk(clk),
		.rd_addr(read_addr),
		.rd_data(read_data),
		.wr_clk(clk),
		.wr_enable(write_enable),
		.wr_addr(write_addr),
		.wr_data(write_data)
	);
*/

	led_matrix #(
		.DISP_ADDR_WIDTH(4),
		.DISPLAY_WIDTH(13'd384),
		.FB_ADDR_WIDTH(ADDR_WIDTH)
	) disp0(
		.clk(clk),
		.reset(reset),
		// physical interface
		.data_out(gpio_23),
		.clk_out(gpio_26),
		.latch_out(gpio_25),
		.enable_out(gpio_27),
		.addr_out({gpio_32, gpio_35, gpio_31, gpio_37}),
		// logical interface
		.data_in(read_data),
		.data_addr(read_addr)
	);

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
				brightness <= brightness + 8'h1c;
			end

			// latch this data and ensure that the correct matrix row is selected
			latch_out <= 1;
			addr_out <= addr;
			latch_counter <= latch_counter + 1;

			// start a new scan line
			x_index <= 0;

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
		end else begin
			// rising edge of the clock, new data should be ready
			// and stable, so mark it
			clk_out <= 1;
			data_addr <= data_addr + 1;
		end
	end
endmodule
