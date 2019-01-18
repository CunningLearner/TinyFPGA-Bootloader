 /*
  * uart.v - High-speed serial support. Includes a baud generator, UART,
  *            and a simple RFC1662-inspired packet framing protocol.
  *
  *            This module is designed a 3 Mbaud serial port.
  *            This is the highest data rate supported by
  *            the popular FT232 USB-to-serial chip.
  *
  * Copyright (C) 2009 Micah Dowty
  *           (C) 2018 Trammell Hudson
  *
  * Permission is hereby granted, free of charge, to any person obtaining a copy
  * of this software and associated documentation files (the "Software"), to deal
  * in the Software without restriction, including without limitation the rights
  * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  * copies of the Software, and to permit persons to whom the Software is
  * furnished to do so, subject to the following conditions:
  *
  * The above copyright notice and this permission notice shall be included in
  * all copies or substantial portions of the Software.
  *
  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
  * THE SOFTWARE.
  */


/*
 * Byte transmitter, RS-232 8-N-1
 *
 * Transmits on 'serial'. When 'ready' goes high, we can accept another byte.
 * It should be supplied on 'data' with a pulse on 'data_strobe'.
 */

module uart_tx(
	input clk,
	input reset,
	input baud_x1,
	output serial,
	output reg ready,
	input [7:0] data,
	input data_strobe
);

   /*
    * Left-to-right shift register.
    * Loaded with data, start bit, and stop bit.
    *
    * The stop bit doubles as a flag to tell us whether data has been
    * loaded; we initialize the whole shift register to zero on reset,
    * and when the register goes zero again, it's ready for more data.
    */
   reg [7+1+1:0]   shiftreg;

   /*
    * Serial output register. This is like an extension of the
    * shift register, but we never load it separately. This gives
    * us one bit period of latency to prepare the next byte.
    *
    * This register is inverted, so we can give it a reset value
    * of zero and still keep the 'serial' output high when idle.
    */
   reg         serial_r;
   assign      serial = !serial_r;

   //assign      ready = (shiftreg == 0);

   /*
    * State machine
    */

   always @(posedge clk)
     if (reset) begin
        shiftreg <= 0;
        serial_r <= 0;
     end
     else if (data_strobe) begin
        shiftreg <= {
		1'b1, // stop bit
		data,
		1'b0  // start bit (inverted)
	};
	ready <= 0;
     end
     else if (baud_x1) begin
        if (shiftreg == 0)
	begin
          /* Idle state is idle high, serial_r is inverted */
          serial_r <= 0;
	  ready <= 1;
	end else
          serial_r <= !shiftreg[0];
  	// shift the output register down
        shiftreg <= {1'b0, shiftreg[7+1+1:1]};
    end else
    	ready <= (shiftreg == 0);

endmodule


/*
 * Byte receiver, RS-232 8-N-1
 *
 * Receives on 'serial'. When a properly framed byte is
 * received, 'data_strobe' pulses while the byte is on 'data'.
 *
 * Error bytes are ignored.
 */

module uart_rx(clk, reset, baud_x4,
                      serial, data, data_strobe);

   input        clk, reset, baud_x4, serial;
   output [7:0] data;
   output       data_strobe;

   /*
    * Synchronize the serial input to this clock domain
    */
   wire         serial_sync;
   d_flipflop_pair input_dff(clk, reset, serial, serial_sync);

   /*
    * State machine: Four clocks per bit, 10 total bits.
    */
   reg [8:0]    shiftreg;
   reg [5:0]    state;
   reg          data_strobe;
   wire [3:0]   bit_count = state[5:2];
   wire [1:0]   bit_phase = state[1:0];

   wire         sampling_phase = (bit_phase == 1);
   wire         start_bit = (bit_count == 0 && sampling_phase);
   wire         stop_bit = (bit_count == 9 && sampling_phase);

   wire         waiting_for_start = (state == 0 && serial_sync == 1);

   wire         error = ( (start_bit && serial_sync == 1) ||
                          (stop_bit && serial_sync == 0) );

   assign       data = shiftreg[7:0];

   always @(posedge clk or posedge reset)
     if (reset) begin
        state <= 0;
        data_strobe <= 0;
     end
     else if (baud_x4) begin

        if (waiting_for_start || error || stop_bit)
          state <= 0;
        else
          state <= state + 1;

        if (bit_phase == 1)
          shiftreg <= { serial_sync, shiftreg[8:1] };

        data_strobe <= stop_bit && !error;

     end
     else begin
        data_strobe <= 0;
     end

endmodule


/*
 * Output UART with a SPRAM RAM FIFO queue.
 *
 * Add bytes to the queue and they will be printed when the line is idle.
 */
module uart_tx_fifo(
	input clk,
	input reset,
	input baud_x1,
	input [7:0] data,
	input data_strobe,
	output serial
);
	parameter NUM = 32;

	wire uart_txd_ready; // high the UART is ready to take a new byte
	reg uart_txd_strobe; // pulse when we have a new byte to transmit
	reg [7:0] uart_txd;

	uart_tx txd(
		.clk(clk),
		.reset(reset),
		.baud_x1(baud_x1),
		.serial(serial),
		.ready(uart_txd_ready),
		.data(uart_txd),
		.data_strobe(uart_txd_strobe)
	);

	wire fifo_available;
	wire fifo_read_strobe;
	wire [7:0] fifo_read_data;

	fifo_bram #(.WIDTH(8)) buffer(
		.read_clk(clk),
		.write_clk(clk),
		.reset(reset),
		.write_data(data),
		.write_strobe(data_strobe),
		.data_available(fifo_available),
		.read_data(fifo_read_data),
		.read_strobe(fifo_read_strobe)
	);

	// drain the fifo into the serial port
	reg [3:0] counter;
	always @(posedge clk)
	begin
		uart_txd_strobe <= 0;
		fifo_read_strobe <= 0;
		counter <= counter + 1;

		if (fifo_available
		&&  uart_txd_ready
		&& !data_strobe // only single port port RAM
		&& !uart_txd_strobe // don't TX twice on one byte
		&& counter == 0
		) begin
			fifo_read_strobe <= 1;
			uart_txd_strobe <= 1;
			uart_txd <= fifo_read_data;
		end
	end
endmodule


module uart_tx_hexdump(
	input clk,
	input reset = 0,
	input strobe,
	input [31:0] data,
	input [3:0] len,
	input space,
	input newline,
	output ready,
	input uart_txd_ready,
	output uart_txd_strobe,
	output [7:0] uart_txd
);
	reg [3:0] digits;
	reg [31:0] bytes;
	reg [7:0] uart_txd;
	reg in_progress = 0;
	reg [8:0] counter;

	assign ready = !in_progress;

	always @(posedge clk)
	begin
		uart_txd_strobe <= 0;

		if (reset) begin
			// nothing to do
			in_progress <= 0;
		end else
		if (strobe) begin
			digits <= len;
			bytes <= data;
			in_progress <= 1;
		end else
		if (uart_txd_strobe
		|| !uart_txd_ready
		|| !in_progress
		|| counter != 0
		) begin
			// nothing to do until uart is ready
			// or we're in progress with an output
			counter <= counter + 1;
		end else
		if (digits != 0)
		begin
			// time to generate a hex value!
			uart_txd_strobe <= 1;
			uart_txd <= hexdigit(bytes[31:28]);

			bytes <= { bytes[27:0], 4'b0 };
			digits <= digits - 1;
		end else
		begin
			// after all the digits, output any whitespace
			if (space) begin
				uart_txd_strobe <= 1;
				uart_txd <= " ";
			end else
			if (newline) begin
				uart_txd_strobe <= 1;
				uart_txd <= "\n";
			end

			in_progress <= 0;
			counter <= 0;
		end
	end
endmodule
