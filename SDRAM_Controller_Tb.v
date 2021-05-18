`timescale 1ns/1ps
module SDRAM_Controller_TB ();

wire [12 : 0] 	address_bus;
wire [7 : 0]	command_bus;
wire [15 : 0]	data_bus;
reg clk = 0;
reg sdr_clk = 0;

reg [31:0] fifo_in_instruction = {13'd0,2'd0,16'd0,1'd0};
reg fifo_in_empty = 1;
wire fifo_in_rd_en = 0;

reg fifo_out_full = 0;
wire [15: 0]fifo_out_data = 0;
wire fifo_out_DV = 0;

 SDRAM_Controller DUT (clk, address_bus, command_bus, data_bus, fifo_in_instruction, fifo_in_empty, fifo_in_rd_en, fifo_out_full, fifo_out_DC, fifo_out_data);

initial	begin
	#100000
	#650
	fifo_in_instruction = {13'd4,2'd0,16'd5,1'd0};
	fifo_in_empty <=0;
	#7.5
	fifo_in_empty <=1;
	#(7.5*60)
	fifo_in_instruction = {13'd2,2'd0,16'd5,1'd1};
	fifo_in_empty <=0;
	#7.5
	fifo_in_instruction = {13'd33,2'd0,16'd254,1'd0};
	#20000
	$stop;
	$finish;
end

always 
#(7.5/2) clk = ~clk;

initial begin
	#(7.5/4)
	forever sdr_clk = #(7.5/2) ~sdr_clk;
end


endmodule 

//60 cycles read, 30 cycles hold
//100us + 600ns init