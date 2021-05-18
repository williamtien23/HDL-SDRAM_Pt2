//PC133

module SDRAM_Controller #(parameter Settings = 1)(
	Clk,
	SDRAM_Address_Bus,
	SDRAM_Command_Bus,
	SDRAM_Data_Bus,
	FIFO_In_Instruction,
	FIFO_In_Empty,
	FIFO_In_Rd_En,
	FIFO_Out_Full,
	FIFO_Out_DV,
	FIFO_Out_Data
);

generate
if (Settings == 1) begin
`define PC133
end
//else
endgenerate


`ifdef PC133
localparam CMD_BITS 			= 			6;
localparam ADDR_BITS			=			13;
localparam BA_BITS			=			2;
localparam DQ_BITS			=			16;
localparam DQM_BITS			=			2;
localparam INIT_DELAY		=			13334; //100us*clk/7.5ns = 13334 clk cyle delays @ 133MHz (2^14 bit counter)

localparam T_RP				=			2; 	//Precharge To Active
localparam T_RC				=			8;		//Refresh To Refresh, Active To Active
localparam T_RCD				=			2;		//Active To Read/Write
localparam T_MRD				=			2;		//Mode Register Set To Command
localparam T_CAS				=			2;		//CAS Latency
localparam REFRESH			=			1;
`endif
	
input wire Clk; 

output wire [ADDR_BITS+BA_BITS -1 : 0] 		SDRAM_Address_Bus; 
output wire [CMD_BITS+DQM_BITS -1 : 0] 		SDRAM_Command_Bus; 
inout wire 	[DQ_BITS -1 : 0] 						SDRAM_Data_Bus; //TO DO - Handle Tri State

input wire 	[ADDR_BITS+BA_BITS+DQ_BITS : 0] 	FIFO_In_Instruction; //Include a write enable bit (no -1)
input wire FIFO_In_Empty;
output reg FIFO_In_Rd_En;

input wire FIFO_Out_Full;
output reg FIFO_Out_DV;
output wire [DQ_BITS -1 : 0] FIFO_Out_Data;




	
//=======================================================
//  SDRAM Internal Declarations
//		-Address
//		-Command
//		-Data
//=======================================================
reg [ADDR_BITS -1 : 0] 	addr;
reg [BA_BITS -1 : 0]		bank;

reg			cke;		//clock enable
reg			cs_n;		//chip select active low
reg			cas_n;	//column access strobe active low
reg			ras_n;	//row access strobe active low
reg			we_n;		//write enable active low
reg [1:0]	dqm;		//data mask

reg [DQ_BITS -1 : 0]	data;	

assign SDRAM_Address_Bus = {addr,bank};
assign SDRAM_Command_Bus = {cke, cs_n, ras_n, cas_n, we_n, dqm[1:0]};
assign SDRAM_Data_Bus 	 = data;

//assign SDRAM_Data_Bus = (inst_we) ? data : {DQ_BITS{1'bz}};
//assign FIFO_Out_Data = SDRAM_Data_Bus;
//=======================================================
//  States
//=======================================================
localparam STATE_POWER_ON	 			=	8'd0;
localparam STATE_INIT_DELAY 			=	8'd1;
localparam STATE_INIT_PRECHARGE 		= 	8'd2; 
localparam STATE_INIT_AUTO_REFRESH 	=	8'd3;
localparam STATE_INIT_LOAD_REG 		=	8'd4;
localparam STATE_IDLE 					=	8'd5;
localparam STATE_ACTIVE					= 	8'd6;
localparam STATE_READ					=	8'd7;
localparam STATE_READ_DV				=	8'd8;
localparam STATE_WRITE					= 	8'd9;
localparam STATE_AUTO_REFRESH			= 	8'd10;


//=======================================================
//  Internal Registers
//=======================================================
reg state_machine_en = 1;						
reg [31:0] sdram_timing_target = 0;
reg [31:0] sdram_timing_counter = 0;	//Timing delay counter
reg [31:0] auto_refresh_counter = 0;	//Auto refresh counter
reg [7:0] init_refresh_counter = 0;
				
reg [7:0] current_state = STATE_POWER_ON;					//FSM States
reg [7:0] next_state = STATE_INIT_DELAY;

reg refresh_reset = 1;

reg inst_busy = 0;
reg [ADDR_BITS-1 : 0] inst_addr = 0;
reg [BA_BITS-1 : 0] inst_bank = 0;
reg [DQ_BITS-1 : 0] inst_data = 0;
reg inst_we = 0;

initial begin
	$timeformat (-9, 1, " ns", 12);
end

//Modelsim - moved assign here
assign SDRAM_Data_Bus = (inst_we) ? data : {DQ_BITS{1'bz}};
assign FIFO_Out_Data = SDRAM_Data_Bus;

//=======================================================
//  FIFO In Instruction Parse
//=======================================================
always @ (posedge Clk) begin

	if((FIFO_In_Empty == 0) && (inst_busy == 0))begin //Clock in new instruction
		$display ("%m : at time %t Register New Instruction", $time);
		inst_busy <= 1;
		FIFO_In_Rd_En <= 1;
		inst_addr <= FIFO_In_Instruction [ADDR_BITS+BA_BITS+DQ_BITS : BA_BITS+DQ_BITS+1];
		inst_bank <= FIFO_In_Instruction [BA_BITS+DQ_BITS : DQ_BITS+1];
		inst_data <= FIFO_In_Instruction [DQ_BITS : 1];
		inst_we	 <= FIFO_In_Instruction [0];	
	end
	else begin
		FIFO_In_Rd_En <= 0;
	end
	
end

//=======================================================
//  State Machine / SDRAM Timing Delay Generator
//=======================================================
always @ (posedge Clk) begin

	if(state_machine_en == 0)begin
		tsk_nop;
		if ((sdram_timing_target - sdram_timing_counter) == 0) //Like SLT OP
			state_machine_en <= 1;
		else
			sdram_timing_counter <= sdram_timing_counter+1;
	end
	else begin
		sdram_timing_counter <= 1;
	end
	
end	

//=======================================================
//  Refresh Block Delay Generator
//=======================================================
always @ (posedge Clk) begin

	if (refresh_reset == 1) auto_refresh_counter <= 0; //acknowledged by state machine
	else auto_refresh_counter <= auto_refresh_counter+1;
	
end

//=======================================================
//  State Machine
//=======================================================

always @ (posedge Clk) begin
	if (state_machine_en == 1) begin
		current_state <= next_state;
	end
end


always @ (*) begin

	case(current_state)
		STATE_POWER_ON:
		begin
			next_state = STATE_INIT_DELAY;
		end	
		STATE_INIT_DELAY:
		begin
			next_state = STATE_INIT_PRECHARGE;
		end
		
		STATE_INIT_PRECHARGE:	
		begin
			next_state = STATE_INIT_AUTO_REFRESH;
		end
		
		STATE_INIT_AUTO_REFRESH:
		begin
			if (init_refresh_counter == 8) next_state = STATE_INIT_LOAD_REG;
			else next_state = STATE_INIT_AUTO_REFRESH;
		end
		
		STATE_INIT_LOAD_REG:
		begin
			next_state = STATE_IDLE;
		end
		
		STATE_IDLE:
		begin
			if((inst_busy == 0) && (auto_refresh_counter<1000)) begin
				next_state = STATE_IDLE;
			end
			else if (auto_refresh_counter >= 1000) begin
				next_state = STATE_AUTO_REFRESH;
			end
			else next_state = STATE_ACTIVE;
		end
		
		STATE_ACTIVE:
		begin
			if(inst_we == 1) next_state = STATE_WRITE;
			else next_state = STATE_READ;
		end
		
		STATE_WRITE:
		begin
			next_state = STATE_IDLE;
		end
		
		STATE_READ:
		begin
			next_state = STATE_READ_DV;
		end
		
		STATE_READ_DV:
		begin
			next_state = STATE_IDLE;
		end
		
		STATE_AUTO_REFRESH:
		begin
			next_state = STATE_IDLE;
		end
		
		default:
		begin
			next_state = STATE_IDLE;
		end

	endcase
end


always @ (posedge Clk) begin
	if(state_machine_en == 1)begin
		case (next_state)
		
			//==================================
			// Init Routine - 100us delay
			STATE_INIT_DELAY:
			begin
				$display ("%m : at time %t Power On", $time);
				sdram_timing_target <= INIT_DELAY;
				state_machine_en <= 0;
			end		
			
			//==================================
			// Init Routine - Precharge all
			STATE_INIT_PRECHARGE:	
			begin
				$display ("%m : at time %t Precharge", $time);	
				tsk_precharge_all_bank;
				sdram_timing_target <= T_RP;
				state_machine_en <= 0;
			end
			
			//==================================
			// Init Routine - Auto Refresh x8
			STATE_INIT_AUTO_REFRESH: 
			begin
			$display ("%m : at time %t Auto Refresh N: %d", $time, auto_refresh_counter);
				tsk_auto_refresh;
				sdram_timing_target <= T_RC;
				state_machine_en <= 0;
				init_refresh_counter <= init_refresh_counter+1;
			end
			
			//==================================
			// Loading Mode Register
			STATE_INIT_LOAD_REG: 
			begin
				$display ("%m : at time %t Load", $time);
				tsk_load_mode_reg(32);
				sdram_timing_target <= T_MRD;
				state_machine_en <= 0;
			end
			
			//==================================
			// Waiting for instruction
			STATE_IDLE:
			begin
				$display ("%m : at time %t Idling", $time);
				tsk_nop;
				refresh_reset <= 0;
			end
			
			//==================================
			// Activate row
			STATE_ACTIVE:
			begin
				$display ("%m : at time %t Active", $time);
				tsk_active(inst_addr, inst_bank);
				sdram_timing_target <= T_RCD;
				state_machine_en <= 0;
			end
			
			//==================================
			// Write Data
			STATE_WRITE:
			begin
				$display ("%m : at time %t Write", $time);
				tsk_write(inst_addr, inst_bank, inst_data);
				inst_busy <= 0;
			end
			
			//==================================
			// Read Data
			STATE_READ:
			begin
				$display ("%m : at time %t Read Begin", $time);
				tsk_read(inst_addr, inst_bank);
				sdram_timing_target <= T_CAS;
				inst_busy <= 0;
				state_machine_en <= 0;
			end
			
			//==================================
			// Read Data
			STATE_READ_DV:
			begin
				$display ("%m : at time %t Read Valid", $time);
				//FIFO_Out_Data <= SDRAM_Data_Bus; //TO DO - Does timing make sense?
				FIFO_Out_DV <=1;
			end
			
			//==================================
			// Auto Refresh
			STATE_AUTO_REFRESH:
			begin
				$display ("%m : at time %t Auto Refreshing", $time);
				tsk_auto_refresh;
				sdram_timing_target <= T_RC;
				refresh_reset <= 1;
				state_machine_en <= 0;
			end
		
			default:
			begin
				tsk_nop;
			end

		endcase
	end
end


//=======================================================
//  Tasks
//=======================================================

task tsk_nop;
	begin
		//data
		data 	= {DQ_BITS{1'bz}};
		//address
		addr	= {ADDR_BITS{1'bx}};
		bank	= {BA_BITS{1'bx}};
		//control
		cke 	= 1;
		cs_n 	= 0;
		ras_n	= 1;
		cas_n	= 1;
		we_n	= 1;
		dqm	= 2'b0;
	end
endtask
 
task tsk_precharge_all_bank;
	begin
		//data
		data	 = {DQ_BITS{1'bz}};
		//address
		addr	= {ADDR_BITS{1'bx}} | 1024;
		bank	= {BA_BITS{1'bx}};
		//control		
		cke 	= 1;
		cs_n 	= 0;
		ras_n	= 0;
		cas_n	= 1;
		we_n	= 0;
		dqm	= 0;	
    end
endtask

task tsk_auto_refresh;
    begin
		//data
		data	= {DQ_BITS{1'bz}};
		//address
		addr	= {ADDR_BITS{1'bx}};
		bank	= {BA_BITS{1'bx}};
		//control		
		cke 	= 1;
		cs_n 	= 0;
		ras_n	= 0;
		cas_n	= 0;
		we_n	= 1;
		dqm	= 0;
    end
endtask
	 
task tsk_load_mode_reg;
	input [ADDR_BITS - 1 : 0] op_code;
	begin
		//data
		data 	= {DQ_BITS{1'bz}};
		//address
		addr	= op_code;
		bank	= 0;
		//control		
		cke 	= 1;
		cs_n 	= 0;
		ras_n	= 0;
		cas_n	= 0;
		we_n	= 0;
		dqm	= 0;
    end
endtask

task tsk_active;
    input [ADDR_BITS - 1 : 0] row;
    input [BA_BITS - 1 : 0] bank_in;
    begin
		//data
		data = {DQ_BITS{1'bz}};
		//address
		addr	=	row;
		bank 	=	bank_in;
		//control
      cke   = 1;
      cs_n  = 0;
      ras_n = 0;
      cas_n = 1;
      we_n  = 1;
      dqm   = 0;
    end
endtask


task tsk_read;
    input [ADDR_BITS - 1 : 0] column;
    input [BA_BITS - 1 : 0] bank_in;
    begin
		//data
		data = {DQ_BITS{1'bz}};
		//address
		addr	=	column | 1024; //A10 = 1 for auto precharge
		bank 	=	bank_in;
		//control
      cke   = 1;
      cs_n  = 0;
      ras_n = 1;
      cas_n = 0;
      we_n  = 1;
      dqm   = 0;
    end
endtask

task tsk_write;
    input [ADDR_BITS - 1 : 0] column;
	 input [BA_BITS - 1 : 0] bank_in;
    input [DQ_BITS - 1 : 0] dq_in;
	 begin
	 	//data
		data = dq_in;
		//address
		addr	=	column | 1024; //A10 = 1 for auto precharge
		bank 	=	bank_in;
		//control
      cke   = 1;
      cs_n  = 0;
      ras_n = 1;
      cas_n = 0;
      we_n  = 0;
      dqm   = 0;
    end
endtask

endmodule

