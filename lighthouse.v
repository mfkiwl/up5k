/** \file
 * Print the lengths of timer pulses from the lighthouse sensors.
 */
`include "util.v"
`include "uart.v"

module top(
	output led_r,
	output led_g,
	output led_b,
	output serial_txd,
	input serial_rxd,
	output spi_cs,
	input gpio_9,
	input gpio_18,
	input gpio_28,
	input gpio_38,
	input gpio_2,
	input gpio_46,
	input gpio_47,
	input gpio_45,
	input gpio_48,
	input gpio_3,
	input gpio_4,
	input gpio_44,
	input gpio_6,
	input gpio_42,
	input gpio_36,
	input gpio_34
);
	assign spi_cs = 1; // it is necessary to turn off the SPI flash chip

	// map the sensor
	parameter NUM_SENSORS = 4;
	wire [15:0] lighthouse_pin = {
		gpio_48,
		gpio_3,
		gpio_4,
		gpio_44,

		gpio_6,
		gpio_42,
		gpio_34,
		gpio_36,

		gpio_2,
		gpio_46,
		gpio_47,
		gpio_45,

		// really hooked up
		gpio_28,
		gpio_18,
		gpio_38,
		gpio_9
	};

	wire clk_48;
	wire reset = 0;
	SB_HFOSC u_hfosc (
		.CLKHFPU(1'b1),
		.CLKHFEN(1'b1),
		.CLKHF(clk_48)
	);

	// pulse the green LED to know that we're alive
	reg [31:0] counter;
	always @(posedge clk_48)
		counter <= counter + 1;
	wire pwm_g;
	pwm pwm_g_driver(clk_48, 1, pwm_g);
	assign led_g = !(counter[25:23] == 0 && pwm_g);

	assign led_b = serial_rxd; // idles high

	// generate a 3 MHz/12 MHz serial clock from the 48 MHz clock
	// this is the 3 Mb/s maximum supported by the FTDI chip
	wire clk_1, clk_4;
	divide_by_n #(.N(16)) div1(clk_48, reset, clk_1);
	divide_by_n #(.N( 4)) div4(clk_48, reset, clk_4);

	wire [7:0] uart_rxd;
	wire uart_rxd_strobe;

	uart_rx rxd(
		.mclk(clk_48),
		.reset(reset),
		.baud_x4(clk_4),
		.serial(serial_rxd),
		.data(uart_rxd),
		.data_strobe(uart_rxd_strobe)
	);

	assign led_r = serial_txd;

	reg [7:0] uart_txd;
	reg uart_txd_strobe = 0;

	uart_tx_fifo #(.NUM(256)) txd(
		.clk(clk_48),
		.reset(reset),
		.baud_x1(clk_1),
		.serial(serial_txd),
		.data(uart_txd),
		.data_strobe(uart_txd_strobe)
	);

	// output buffer
	parameter FIFO_WIDTH = 28;
	reg [FIFO_WIDTH-1:0] fifo_write;
	reg fifo_write_strobe;
	wire fifo_available;
	wire [FIFO_WIDTH-1:0] fifo_read;
	reg fifo_read_strobe;

	fifo #(.WIDTH(FIFO_WIDTH),.NUM(32)) timer_fifo(
		.clk(clk_48),
		.reset(reset),
		.data_available(fifo_available),
		.write_data(fifo_write),
		.write_strobe(fifo_write_strobe),
		.read_data(fifo_read),
		.read_strobe(fifo_read_strobe)
	);

	wire [19:0] angle0 [0:NUM_SENSORS-1];
	wire [19:0] angle1 [0:NUM_SENSORS-1];
	wire [19:0] angle2 [0:NUM_SENSORS-1];
	wire [19:0] angle3 [0:NUM_SENSORS-1];
	wire [3:0] strobe [0:NUM_SENSORS-1];

	genvar i;
	for(i = 0 ; i < NUM_SENSORS ; i = i+1)
	begin

		lighthouse_sensor sensor(
			.clk(clk_48),
			.reset(reset),
			.raw_pin(lighthouse_pin[i]),
			.angle0(angle0[i]),
			.angle1(angle1[i]),
			.angle2(angle2[i]),
			.angle3(angle3[i]),
			.strobe(strobe[i])
		);
	end

`define SHORT_OUTPUT(i) \
	if (strobe[i][0]) begin \
		fifo_write <= { 4'hA + i, 4'h0, angle0[i] }; \
		fifo_write_strobe <= 1; \
	end else

`define OUTPUT(i) \
	if (strobe[i][0]) begin \
		fifo_write <= { 4'hA + i, 4'h0, angle0[i] }; \
		fifo_write_strobe <= 1; \
	end else \
	if (strobe[i][1]) begin \
		fifo_write <= { 4'hA + i, 4'h1, angle1[i] }; \
		fifo_write_strobe <= 1; \
	end else \
	if (strobe[i][2]) begin \
		fifo_write <= { 4'hA + i, 4'h2, angle2[i] }; \
		fifo_write_strobe <= 1; \
	end else \
	if (strobe[i][3]) begin \
		fifo_write <= { 4'hA + i, 4'h3, angle3[i] }; \
		fifo_write_strobe <= 1; \
	end else

	always @(posedge clk_48)
	begin
		fifo_write_strobe <= 0;

		`OUTPUT(0)
		`OUTPUT(1)
		`OUTPUT(2)
		`OUTPUT(3)
/*
		`OUTPUT(4)
		`OUTPUT(5)
		`OUTPUT(6)
		`OUTPUT(7)
		`OUTPUT(8)
		`OUTPUT(9)
		`OUTPUT(10)
		`OUTPUT(11)
		`OUTPUT(12)
		`OUTPUT(13)
		`OUTPUT(14)
		`OUTPUT(15)
*/
		begin end
	end


	reg [FIFO_WIDTH-1:0] out;
	reg [5:0] out_bytes;

	always @(posedge clk_48)
	begin
		uart_txd_strobe <= 0;
		fifo_read_strobe <= 0;

		// convert timer deltas to hex digits
		if (out_bytes != 0)
		begin
			uart_txd_strobe <= 1;
			out_bytes <= out_bytes - 1;
			if (out_bytes == 1)
				uart_txd <= "\r";
			else
			if (out_bytes == 2)
				uart_txd <= "\n";
			else
			if (out_bytes == 3+5)
				uart_txd <= " ";
			else begin
				uart_txd <= hexdigit(out[FIFO_WIDTH-1:FIFO_WIDTH-4]);
				out <= { out[FIFO_WIDTH-5:0], 4'b0 };
			end

		end else
		if (fifo_available)
		begin
			out <= fifo_read;
			fifo_read_strobe <= 1;
			out_bytes <= 2 + 1 + FIFO_WIDTH/4;
		end
	end

endmodule


module lighthouse_sensor(
	input clk,
	input reset,
	input raw_pin,
	output [19:0] angle0,
	output [19:0] angle1,
	output [19:0] angle2,
	output [19:0] angle3,
	output [1:0] ootx,
	output [3:0] strobe
);
	parameter WIDTH = 20;
	parameter MHZ = 48;

	wire sweep_strobe;
	wire [10:0] sync0;
	wire [10:0] sync1;
	wire [20-1:0] sweep;

	reg [19:0] angles[0:3];
	assign angle0 = angles[0];
	assign angle1 = angles[1];
	assign angle2 = angles[2];
	assign angle3 = angles[3];

	wire skip0, axis0, valid0;
	wire skip1, axis1, valid1;

	lighthouse_sweep #(
		.WIDTH(WIDTH),
		.CLOCKS_PER_MICROSECOND(MHZ)
	) lh_sweep(
		.clk(clk),
		.reset(reset),
		.raw_pin(raw_pin),
		.sync0(sync0),
		.sync1(sync1),
		.sweep(sweep),
		.sweep_strobe(sweep_strobe)
	);

	lighthouse_sync_decode #(.MHZ(MHZ)) sync0_decode(
		sync0, skip0, ootx[0], axis0, valid0);

	lighthouse_sync_decode #(.MHZ(MHZ)) sync1_decode(
		sync1, skip1, ootx[1], axis1, valid1);


	always @(posedge clk)
	begin
		strobe <= 0;

		if (reset || !valid0 || !valid1) begin
			// nothing; ignore any pulses
		end else
		if (sweep_strobe) begin
			if (!skip0 && !skip1) begin
				// should never happen.
			end else
			if (!skip0 && axis0) begin
				angles[0] <= sweep;
				strobe[0] <= 1;
			end else
			if (!skip0 && !axis0) begin
				angles[1] <= sweep;
				strobe[1] <= 1;
			end else
			if (!skip1 && axis1) begin
				angles[2] <= sweep;
				strobe[2] <= 1;
			end else
			if (!skip1 && !axis1) begin
				angles[3] <= sweep;
				strobe[3] <= 1;
			end
		end
	end

endmodule


// at 48 MHz every sync pulse is a 512 tick window
// so we only look at the top few bits,
// which encode the skip/data/axis bits:
//
// length = 3072 + axis*512 + data*1024 + skip*2048
//
// This disagrees with https://github.com/nairol/LighthouseRedox/blob/master/docs/Light%20Emissions.md
// but matches what I've seen on my lighthouses.
//
module lighthouse_sync_decode(
	input [10:0] sync,
	output skip,
	output data,
	output axis,
	output valid
);
	parameter MHZ = 48; // we should do something with this

	assign valid = (6 <= sync) && (sync <= 13);

	wire [2:0] type = sync - 6;
	assign skip = type[2];
	assign data = type[1];
	assign axis = type[0];
endmodule

/*
 * Measure the raw sweep times for the sensor.
 * This also reports the lengths of the two sync pulses so that
 * the correct axis and OOTX can be assigned.

                 Data      Data      Angle
                <----->   <-----><------------>
_____   ________       ___       _____________   ___________
     |_|        |_____|   |_____|             |_|
    Sweep        Sync0     Sync1             Sweep

 * Sync0 is from lighthouse A, sync1 is from lighthouse B
 */
module lighthouse_sweep(
	input clk,
	input reset,
	input raw_pin,
	output reg [10:0] sync0,
	output reg [10:0] sync1,
	output reg [WIDTH-1:0] sweep,
	output sweep_strobe
);
	parameter WIDTH = 24;
	parameter CLOCKS_PER_MICROSECOND = 48;

	wire rise_strobe;
	wire fall_strobe;
	reg [WIDTH-1:0] counter;
	reg [WIDTH-1:0] last_rise;
	reg [WIDTH-1:0] last_fall;
	reg got_sweep;
	reg got_sync1;

	// time low
	wire [WIDTH-1:0] len = counter - last_fall;
	wire [WIDTH-1:0] duty = counter - last_rise;

	edge_capture edge(
		.clk(clk),
		.reset(reset),
		.raw_pin(raw_pin),
		.rise_strobe(rise_strobe),
		.fall_strobe(fall_strobe)
	);

	always @(posedge clk)
	begin
		sweep_strobe <= 0;
		counter <= counter + 1;

		if (reset)
		begin
			counter <= 0;
			last_fall <= 0;
			last_rise <= 0;
			got_sweep <= 0;
			got_sync1 <= 0;
		end else
		if (fall_strobe)
		begin
			// record the time of the falling strobe
			last_fall <= counter;
		end else
		if (rise_strobe)
		begin
			if (len < 15 * CLOCKS_PER_MICROSECOND) begin
				// signal that we have something
				// if we've seen the sync pulses
				if (got_sync1)
					sweep_strobe <= 1;

				// time is from the last rising edge to
				// the midpoint of the sweep pulse
				sweep <= counter - len/2 - last_rise;

				// indicate that we have a sweep
				got_sweep <= 1;
				got_sync1 <= 0;
			end else
			if (got_sweep) begin
				// first non-sweep pulse after a sweep
				sync0 <= len[10+9:9];
				got_sweep <= 0;
				got_sync1 <= 0;
			end else begin
				// second non-sweep pulse
				sync1 <= len[10+9:9];
				got_sync1 <= 1;
			end

			last_rise <= counter;
		end
	end

endmodule


module edge_capture(
	input clk,
	input reset,
	input raw_pin,
	output rise_strobe,
	output fall_strobe
);
	reg pin0;
	reg pin1;
	reg pin2;

	always @(posedge clk)
	begin
		// defaults
		rise_strobe <= 0;
		fall_strobe <= 0;

		// flop the raw pin the ensure stability
		pin0 <= raw_pin;
		pin1 <= pin0;
		pin2 <= pin1;

		if (reset) begin
			// nothing to do
		end else
		if (pin2 != pin1) begin
			rise_strobe <= !pin2;
			fall_strobe <=  pin2;
		end
	end

endmodule