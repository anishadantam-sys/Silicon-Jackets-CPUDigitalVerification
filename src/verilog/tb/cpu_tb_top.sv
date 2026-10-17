/*
 * Top-level testbench
 */
module cpu_tb_top;

    import cpu_tb_pkg::*;

    parameter int DataSize = DATA_W;
    parameter int AddrSize = XBAR_AW;

    string requested_seed = "default";

    int assertion_errors = 0;

    logic clk = 0;
    always #5 clk = ~clk;

    // IF instantiation
    cpu_if #(.DataSize(DataSize), .AddrSize(AddrSize)) cpu_if(.clk(clk));

    // DUT instantiation
    chip_top dut (
        .clk_i(clk),
        .rst_i(cpu_if.cpu.reset),
        .en_cpu_i(cpu_if.cpu.en_cpu),
        .halt_cpu_i(cpu_if.cpu.halt_cpu),
        .cpu_halted_o(cpu_if.cpu.cpu_halted),
        .addr_i(cpu_if.cpu.addr),
        .wdata_i(cpu_if.cpu.wdata),
        .w_en_i(cpu_if.cpu.w_en),
        .r_en_i(cpu_if.cpu.r_en),
        .rdata_o(cpu_if.cpu.rdata),
        .rready_o(cpu_if.cpu.rready)
    );

    // Observation signals from the DUT memory path
    assign cpu_if.cpu_active     = dut.cpu_enable_q;
    assign cpu_if.dsram_en       = dut.dsram_en;
    assign cpu_if.dsram_write_en = dut.dsram_write_en;
    assign cpu_if.dsram_addr     = dut.dsram_addr;
    assign cpu_if.dsram_wdata    = dut.dsram_wdata;
    assign cpu_if.dsram_rdata    = dut.dsram_rdata;

    cpu_tb_pkg::cpu_sequencer #(.DataSize(DataSize), .AddrSize(AddrSize)) seqr;
    cpu_tb_pkg::cpu_driver #(.DataSize(DataSize), .AddrSize(AddrSize))    drv;
    cpu_tb_pkg::cpu_monitor #(.DataSize(DataSize), .AddrSize(AddrSize))   mon;
    cpu_tb_pkg::cpu_sb #(.DataSize(DataSize), .AddrSize(AddrSize))        sb;

    // Record failed assertion
    function void assertion_fail(input string message);
        assertion_errors++;
        $error($stime, " ASSERT: %s\n", message);
    endfunction: assertion_fail

    // Initialize both memories through the DUT's external memory port
    task automatic init_memories();
        $display($stime, " TB: Initializing instruction and data memories\n");
        mon.log_transactions = 1'b0;
        sb.log_transactions = 1'b0;
        for (int i = 0; i < ISRAM_WORDS; i++) begin
            seqr.send_write_trans(word_addr(ISRAM_BASE, i), EBREAK_WORD);
        end
        for (int i = 0; i < DSRAM_WORDS; i++) begin
            seqr.send_write_trans(word_addr(DSRAM_BASE, i), $urandom());
        end
        seqr.wait_for_empty();
        repeat (2) @(cpu_if.cb);
        mon.log_transactions = 1'b1;
        sb.log_transactions = 1'b1;
        $display($stime, " TB: Memory initialization complete\n");
    endtask: init_memories

    // Queue external reads on a memory window
    task automatic readback(input int window, input int num_words, input int start_word=0);
        logic [AddrSize-1:0] base;

        case (window)
            0: base = ISRAM_BASE;
            1: base = DSRAM_BASE;
            2: base = REG_BASE;
            default: base = REG_BASE;
        endcase

        for (int i = 0; i < num_words; i++) begin
            seqr.send_read_trans(word_addr(base, start_word + i));
        end
        seqr.wait_for_empty();
        repeat (4) @(cpu_if.cb);
    endtask: readback

    task automatic preload_dmem(input logic [31:0] values [$], input int start_word=0);
        foreach (values[i]) begin
            seqr.send_write_trans(word_addr(DSRAM_BASE, start_word + i), values[i]);
        end
        seqr.wait_for_empty();
        repeat (2) @(cpu_if.cb);
    endtask: preload_dmem

    // Run a directed test
    task automatic run_directed(input string name, const ref logic [31:0] program_words [$],
            input int max_cycles=2000, input int dmem_words=16);
        $display("");
        $display("=================================================================");
        $display(" TEST: %s", name);
        $display("=================================================================");
        sb.set_test(name);

        drv.reset_task();
        seqr.load_program(program_words);
        seqr.wait_for_empty();
        repeat (2) @(cpu_if.cb);
        drv.run_program(max_cycles);

        if (drv.last_run_completed) begin
            readback(2, REG_COUNT);
            readback(1, dmem_words);
        end else begin
            $display($stime, " TB: Skipping %s readback after CPU timeout\n", name);
            drv.reset_task();
        end
    endtask: run_directed

    // Basic smoke test for loading, running, and observing a program that halts
    task automatic run_smoke_test();
        logic [31:0] smoke_prog [$];
        smoke_prog = '{ EBREAK_WORD };
        run_directed("smoke_ebreak", smoke_prog, 100, 1);
    endtask: run_smoke_test

    // Smoke test for stopping the CPU from outside the program
    // Readback is skipped because the CPU stops before the program completes
    task automatic run_external_halt_smoke();
        logic [31:0] long_prog [$];

        for (int i = 0; i < 32; i++) begin
            long_prog.push_back(asm_instr(.op(OP_ADDI), .rd(1), .rs1(1), .imm(1)));
        end
        long_prog.push_back(EBREAK_WORD);

        $display("");
        $display("=================================================================");
        $display(" TEST: smoke_external_halt");
        $display("=================================================================");
        sb.set_test("smoke_external_halt");

        drv.reset_task();
        seqr.load_program(long_prog);
        seqr.wait_for_empty();
        repeat (2) @(cpu_if.cb);
        drv.start_cpu();
        repeat (12) @(cpu_if.cb);
        drv.halt_cpu_now();
        drv.reset_task();
    endtask: run_external_halt_smoke

    // counts how many cycles cpu_halted is high (expected should be one cycle) --> used by Test 1.16
    int halted_cycles = 0; 
    always @(cpu_if.cb) begin
	if (cpu_if.cb.cpu_halted == 1'b1)
		halted_cycles++; 
    end

    // TEST PROGRAM
    logic [31:0] prog [$];
    logic [31:0] data [$];

    int NUM_RANDOM_PROGRAMS = 20;
    int NUM_RANDOM_XBAR = 300;


    initial begin
        int total_errors;

        mon = new(cpu_if);
        sb = new(mon.mon_box);
        seqr = new();
        drv = new(cpu_if, seqr.xbar_box);

        void'($value$plusargs("NUM_RANDOM_PROGRAMS=%d", NUM_RANDOM_PROGRAMS));
        void'($value$plusargs("NUM_RANDOM_XBAR=%d", NUM_RANDOM_XBAR));
        if ($test$plusargs("REF_TRACE")) begin
            sb.ref_model.trace = 1'b1;
        end

        fork
            mon.run();
            sb.run();
            drv.run();
        join_none

        drv.reset_task();
        init_memories();

        run_smoke_test();
        run_external_halt_smoke();


        // DIRECTED TESTS
        drv.reset_task();
        init_memories();

        // TODO: Add directed test cases from the test plan
        // Use the existing helpers
        
        // Example Test: addi with a positive immediate
        //prog = '{
            //asm_instr(.op(OP_ADDI), .rd(1), .rs1(0), .imm(5)),
            //asm_instr(.op(OP_ADDI), .rd(2), .rs1(1), .imm(100)),
            //EBREAK_WORD
        //};
        //run_directed("addi_positive", prog);

	// Test 1.1: basic_ADD
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(22)), 
	    asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(6)), 
	    asm_instr(.op(OP_ADD), .rd(5'd3), .rs1(5'd1), .rs2(5'd2)),
	    EBREAK_WORD
	};
	run_directed("basic_ADD", prog);

	// Test 1.2: ADDI_pos
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(13)),
	    EBREAK_WORD
	};
	run_directed("ADDI_pos", prog);

	// Test 1.3: ADDI_neg
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(-37)),
	    EBREAK_WORD
	};
	run_directed("ADD_neg", prog);

	// Test 1.4: SUB_rs1NEG
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(5)), 
	    asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(8)),
	    asm_instr(.op(OP_SUB), .rd(5'd3), .rs1(5'd1), .rs2(5'd2)),
	    EBREAK_WORD
	};
	run_directed("SUB_rs1NEG", prog);

	// Test 1.5: SUB_zero
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(7)),
	    asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(7)), 
	    asm_instr(.op(OP_SUB), .rd(5'd3), .rs1(5'd1), .rs2(5'd2)),
	    EBREAK_WORD
	};
	run_directed("SUB_zero", prog);

	// Test 1.6: SLL_amounts
	prog = '{ 
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(2)),
	    asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(0)), 
	    asm_instr(.op(OP_SLL), .rd(5'd5), .rs1(5'd1), .rs2(5'd2)),

	    asm_instr(.op(OP_ADDI), .rd(5'd3), .rs1(5'd0), .imm(3)), 
	    asm_instr(.op(OP_SLL), .rd(5'd6), .rs1(5'd1), .rs2(5'd3)),

	    asm_instr(.op(OP_ADDI), .rd(5'd4), .rs1(5'd0), .imm(31)), 
	    asm_instr(.op(OP_SLL), .rd(5'd7), .rs1(5'd1), .rs2(5'd4)),

	    // testing shift amounds 32 & 33
	    asm_instr(.op(OP_ADDI), .rd(5'd8), .rs1(5'd0), .imm(32)),
	    asm_instr(.op(OP_SLL), .rd(5'd10), .rs1(5'd1), .rs2(5'd8)),
	    asm_instr(.op(OP_ADDI), .rd(5'd9), .rs1(5'd0), .imm(33)), 
	    asm_instr(.op(OP_SLL), .rd(5'd11), .rs1(5'd1), .rs2(5'd9)),
	    EBREAK_WORD
	};
	run_directed("SLL_amounts", prog);

	// Test 1.7: SRL_negOp
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(-1)),
	    asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(1)), 
	    asm_instr(.op(OP_SRL), .rd(5'd3), .rs1(5'd1), .rs2(5'd2)),
	    EBREAK_WORD
	};
	run_directed("SRL_negOP", prog);

	// Test 1.8: LOADandSTORE
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(40)), 
	    asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(42)), 
	    asm_instr(.op(OP_SW), .rs1(5'd1), .rs2(5'd2), .imm(0)), 
	    asm_instr(.op(OP_LW), .rd(5'd3), .rs1(5'd1), .imm(0)), 
	    EBREAK_WORD
	};
	run_directed("LOADandSTORE", prog);

	// Test 1.9: memory_bounds
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(0)),
	    asm_instr(.op(OP_ADDI), .rd(5'd3), .rs1(5'd0), .imm(17)), 
	    asm_instr(.op(OP_SW), .rs1(5'd1), .rs2(5'd3), .imm(0)),
	    
	    asm_instr(.op(OP_ADDI), .rd(5'd4), .rs1(5'd0), .imm(2)),
	    asm_instr(.op(OP_ADDI), .rd(5'd5), .rs1(5'd0), .imm(1023)),
	    asm_instr(.op(OP_SLL), .rd(5'd2), .rs1(5'd5), .rs2(5'd4)),
	    asm_instr(.op (OP_ADDI), .rd(5'd6), .rs1(5'd0), .imm(99)),

	    asm_instr(.op(OP_SW), .rs1(5'd2), .rs2(5'd6), .imm(0)),
	    asm_instr(.op(OP_LW), .rd(5'd7), .rs1(5'd1), .imm(0)),
	    asm_instr(.op(OP_LW), .rd(5'd8), .rs1(5'd2), .imm(0)),
	    EBREAK_WORD
	};
	run_directed("memory_bounds", prog);

	// Test 1.10: BEQ_taken
	prog = '{
	   asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(0)),
	   asm_instr(.op(OP_BEQ), .rs1(5'd1), .rs2(5'd0), .imm(8)),
	   asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(45)),
	   asm_instr(.op(OP_ADDI), .rd(5'd3), .rs1(5'd0), .imm(3)), 
	   EBREAK_WORD
	};
	run_directed("BEQ_taken", prog);

	// Test 1.11: BEQ_notTaken
	prog = '{ 
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(7)),
	    asm_instr(.op(OP_BEQ), .rs1(5'd1), .rs2(5'd0), .imm(8)),
	    asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(45)),
	    EBREAK_WORD
	};
	run_directed("BEQ_notTaken", prog);

	// Test 1.12: BEQ_regsEq
	prog = '{
	   asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(4)),
	   asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(4)),
	   asm_instr(.op(OP_BEQ), .rs1(5'd1), .rs2(5'd2), .imm(8)),

	   asm_instr(.op(OP_ADDI), .rd(5'd3), .rs1(5'd0), .imm(45)),
	   asm_instr(.op(OP_ADDI), .rd(5'd4), .rs1(5'd0), .imm(3)),
	   EBREAK_WORD
	};
	run_directed("BEQ_regsEq", prog);

	// Test 1.13: x0_fixed
	prog = '{
	   asm_instr(.op(OP_ADDI), .rd(5'd0), .rs1(5'd0), .imm(55)),
	   EBREAK_WORD
	};
	run_directed("x0_fixed", prog);

	// Test 1.14: instr_dependent
	prog = '{
	   asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(9)),
	   asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(4)), 
	   asm_instr(.op(OP_ADD), .rd(5'd1), .rs1(5'd1), .rs2(5'd2)),
	   asm_instr(.op(OP_SUB), .rd(5'd1), .rs1(5'd1), .rs2(5'd1)), 
	   asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd1), .imm(11)),
	   EBREAK_WORD
	};
	run_directed("instr_dependent", prog);

	// Test 1.15: branch_dependent
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(0)), 
	    asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(5)), 
	    asm_instr(.op(OP_BEQ), .rs1(5'd1), .rs2(5'd0), .imm(8)), 

	    asm_instr(.op(OP_ADD), .rd(5'd2), .rs1(5'd2), .rs2(5'd2)), 
	    asm_instr(.op(OP_ADDI), .rd(5'd3), .rs1(5'd2), .imm(1)),
	    EBREAK_WORD
	};
	run_directed("branch_dependent", prog); 
	
	// Test 1.16: EBREAK_haltsOnce
	halted_cycles = 0;
	prog = '{
	   asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(1)),
	   EBREAK_WORD
	};
	run_directed("EBREAK_haltsOnce", prog);

	if (halted_cycles != 1) begin 
		$error("cpu_halted was high for %0d cycles, expected only 1", halted_cycles); 
	end

	//tests made  during coverage closure

	// Test 1.17: SRL_upperBitsIgnored
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(-1)), 
	    asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(32)),
	    asm_instr(.op(OP_ADDI), .rd(5'd3), .rs1(5'd0), .imm(33)),
	    asm_instr(.op(OP_SRL), .rd(5'd4), .rs1(5'd1), .rs2(5'd2)),
	    asm_instr(.op(OP_SRL), .rd(5'd5), .rs1(5'd1), .rs2(5'd3)),
	    EBREAK_WORD	
	};
	run_directed("SRL_upperBitsIgnored", prog);

	// Test 1.18 BEQ_backwardLoop
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(0)),
	    asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(3)),
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd1), .imm(1)),
	    asm_instr(.op(OP_BEQ), .rs1(5'd1), .rs2(5'd2), .imm(8)),
	    asm_instr(.op(OP_BEQ), .rs1(5'd0), .rs2(5'd0), .imm(-8)), 
	    asm_instr(.op(OP_BEQ), .rd(5'd3), .rs1(5'd0), .imm(99)),
	    EBREAK_WORD
	};
	run_directed("BEQ_backwardLoop", prog);

	// Test 1.19 high_register_access
	prog = '{
	   asm_instr(.op(OP_ADDI), .rd(5'd28), .rs1(5'd0), .imm(15)),
	   asm_instr(.op(OP_ADDI), .rd(5'd29), .rs1(5'd28), .imm(10)),
	   asm_instr(.op(OP_ADD), .rd(5'd30), .rs1(5'd28), .rs2(5'd29)),
	   asm_instr(.op(OP_SUB), .rd(5'd31), .rs1(5'd30), .rs2(5'd28)),
	   EBREAK_WORD
	}; 
	run_directed("high_register_access", prog);

	// Test 1.20:  BEQ_farForward
	prog = '{
	   asm_instr(.op(OP_BEQ), .rs1(5'd0), .rs2(5'd0), .imm(4092)),
	   EBREAK_WORD
	};
	run_directed("BEQ_farForward", prog);

	// Test 1.21: value_extremes
	prog = '{
	    asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(1)), 
	    asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(31)), 
	    asm_instr(.op(OP_SLL), .rd(5'd3), .rs1(5'd1), .rs2(5'd2)), 
	    asm_instr(.op(OP_ADDI), .rd(5'd4), .rs1(5'd3), .imm(-1)), 
	    asm_instr(.op(OP_ADD), .rd(5'd5), .rs1(5'd4), .rs2(5'd4)), 
	    asm_instr(.op(OP_ADD), .rd(5'd6), .rs1(5'd3), .rs2(5'd3)),
	    asm_instr(.op(OP_SUB), .rd(5'd7), .rs1(5'd6), .rs2(5'd1)),
	    asm_instr(.op(OP_SUB), .rd(5'd8), .rs1(5'd3), .rs2(5'd1)),
	    asm_instr(.op(OP_SRL), .rd(5'd9), .rs1(5'd3), .rs2(5'd2)), 
	    asm_instr(.op(OP_ADDI), .rd(5'd10), .rs1(5'd0), .imm(-2048)), 
	    asm_instr(.op(OP_ADDI), .rd(5'd11), .rs1(5'd0), .imm(2047)),
	    EBREAK_WORD
	};
	run_directed("value_extremes", prog);

	// tests for finding bugs in encrypted cpu
	prog = '{
		asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(0)), 
		asm_instr(.op(OP_BEQ), .rs1(5'd1), .rs2(5'd0), .imm(8)), 
		asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(99)), 
		asm_instr(.op(OP_ADDI), .rd(5'd3), .rs1(5'd0), .imm(3)),
		EBREAK_WORD
	};
	run_directed("Branch_target_LW", prog);

	prog = '{
		asm_instr(.op(OP_ADDI), .rd(5'd1), .rs1(5'd0), .imm(12'h111)), 
		asm_instr(.op(OP_ADDI), .rd(5'd2), .rs1(5'd0), .imm(12'h222)), 
		asm_instr(.op(OP_SW), .rs1(5'd0), .rs2(5'd1), .imm(0)), 
		asm_instr(.op(OP_SW), .rs1(5'd0), .rs2(5'd2), .imm(4)),
		EBREAK_WORD
	};
	run_directed("store_drop", prog);

	prog = '{
		asm_instr(.op(OP_ADDI), .rd(1), .rs1(0), .imm(12'h080)),
		asm_instr(.op(OP_ADDI), .rd(2), .rs1(0), .imm(12'h111)), 
		asm_instr(.op(OP_SW), .rs1(1), .rs2(2), .imm(12'h080)),
		EBREAK_WORD
	};
	run_directed("SW_carryOutbit7", prog); 

	
	 

        // CONSTRAINED-RANDOM TESTS
        // TODO: Add constrained-randomized testing for cpu_seq_item and cpu_xbar_item
        // For every random CPU program:
        //   1. print an iteration label so the seed and failure are reproducible,
        //   2. reset the CPU and call init_memories() before gen_program(),
        //   3. wait for program writes, run with the supplied bounded helper,
        //   4. queue the register and relevant memory reads needed by the scoreboard.
        // Keep randomized external-port traffic in a phase where the CPU is stopped.
        // The README explains why memory must be reinitialized every iteration.

	$display(""); 
	$display("====================================");
	$display("Running Constrained-Random Tests");
	$display("====================================");

	for (int i = 0; i < NUM_RANDOM_PROGRAMS; i++) begin
		$display($stime, " TB: Starting Random Iteration %0d/%0d ", i + 1, NUM_RANDOM_PROGRAMS);
		sb.set_test($sformatf("random_prog_%0d", i));
		drv.reset_task();
		init_memories();
		seqr.gen_program($urandom_range(10,40));

		seqr.wait_for_empty();
		repeat (2) @(cpu_if.cb);

		drv.run_program(2000);

		// readbacks with scoreboard
		if (drv.last_run_completed) begin
			readback(2, REG_COUNT); 
			readback(1, DSRAM_WORDS);
		end else begin
			$display( "TB: random program %0d timed out, skipping readback", i);
			drv.reset_task();
		end
	end

	// External Memory Port Traffic while CPU is halted
	$display("\n======================================");
	$display(" Running Random External Xbar Traffic ");
	$display("========================================");
	sb.set_test("random_xbar_traffic"); 
	drv.reset_task();
	seqr.gen_xbar(NUM_RANDOM_XBAR);
	seqr.wait_for_empty();
	repeat (10) @(cpu_if.cb);


        // TEST FINISH
        repeat (20) @(cpu_if.cb);
        total_errors = sb.errors + drv.timeouts + mon.errors + assertion_errors;
        if (sb.checks == 0) begin
            $error("Testbench performed zero checks; no results were verified");
        end

        $display("=================================================================");
        $display("  Scoreboard mismatches : %0d", sb.errors);
        $display("  Driver timeouts       : %0d", drv.timeouts);
        $display("  Monitor protocol errs : %0d", mon.errors);
        $display("  Assertion failures    : %0d", assertion_errors);
        $display("=================================================================");
        $display();

        if (total_errors == 0) begin
            $display("=================================================================");
            $display(" TEST PASSED!");
            $display("=================================================================");
        end else begin
            $display("=================================================================");
            $display(" TEST FAILED: %0d error(s)", total_errors);
            $display("=================================================================");
        end
        $finish;
    end

    // ASSERTION VIOLATION TESTS

    //task automatic violation_test_single_cycle_halt();
	//logic [31:0] prog[$];
	//$display("");
	//$display("VIOLATION TEST: single_cycle_halt"); 
	//sb.set_test("violation_single_cycle_halt");
	//drv.reset_task(); 
	//prog = '{EBREAK_WORD};
	//seqr.load_program(prog); 
	//seqr.wait_for_empty(); 
	//repeat (2) @(cpu_if.cb); 
	//drv.start_cpu();

	//@(posedge cpu_if.cpu_halted);
	//force cpu_if.cpu_halted = 1'b1; 
	//repeat (3) @(posedge clk);
	//release cpu_if.cpu_halted;

	//repeat (2) @(cpu_if.cb); 
	//drv.reset_task();
    //endtask: violation_test_single_cycle_halt

   // task automatic violation_test_addr_stable();
	//logic [31:0] prog[$];
	//$display(""); 
	//$display("VIOLATION TEST: addr_stable_during_read"); 
	//sb.set_test("violation_addr_stable"); 
	//drv.reset_task();
	
	//fork
	    //seqr.send_read_trans(word_addr(ISRAM_BASE, 0));
	    //begin
		//@(posedge clk iff cpu_if.r_en);
		//force cpu_if.addr = 14'h3FFC; 
		//repeat (2) @(posedge clk); 
		//release cpu_if.addr;
	    //end
	//join_any

	//seqr.wait_for_empty();
	//repeat (2) @(cpu_if.cb);
	//drv.reset_task(); 
    //endtask: violation_test_addr_stable

      //task automatic violation_test_en_cpu_pulse();
	//$display("");
	//$display(" VIOLATION TEST: en_cpu_single_cycle"); 
	//sb.set_test("violation_en_cpu_pulse"); 
	//drv.reset_task();

	//@(posedge clk); 
	//force cpu_if.en_cpu = 1'b1; 
	//repeat (2) @(posedge clk); 
	//release cpu_if.en_cpu; 

	//repeat (5) @(cpu_if.cb); 
	//drv.reset_task(); 
      //endtask: violation_test_en_cpu_pulse

    //initial begin
	//violation_test_single_cycle_halt();
	//violation_test_addr_stable();
	//violation_test_en_cpu_pulse();
    //end

    // Stop a broken DUT or testbench instead of letting the simulation run forever
    initial begin
        #10ms;
        $display(" TEST FAILED - global timeout");
        $fatal(1, "global timeout");
    end

    initial begin
        void'($value$plusargs("SEED_LABEL=%s", requested_seed));
        if ($test$plusargs("BUG_HUNT_WAVES")) begin
            $shm_open("bug_hunt_waves.shm");
        end else begin
            $shm_open("waves.shm");
        end
        $shm_probe("AC");
    end

    wire rst = cpu_if.reset;
    // TODO: Add the required protocol or control assertions from the testplan

    // Example assertion
    // It checks one interface rule and sends failures through the testbench counter
    NO_SIMULTANEOUS_READ_WRITE:
        assert property (@(posedge clk) disable iff (rst)
            !(cpu_if.w_en && cpu_if.r_en))
        else assertion_fail("w_en_i and r_en_i were asserted together");
	
    //single_cycle_halt: 
	//assert property (@(posedge clk) disable iff (rst)
		//cpu_if.cpu_halted |=> !cpu_if.cpu_halted)
	//else assertion_fail("cpu_halted_o stayed high for more than one cycle");

     addrStable_duringRead: 
	assert property (@(posedge clk) disable iff (rst)
		($past(cpu_if.r_en) && cpu_if.r_en && !$past(cpu_if.rready)) |-> $stable(cpu_if.addr))
	else assertion_fail("addr changed while a read was still pending");

    en_cpu_single_cycle:
	assert property (@(posedge clk) disable iff (rst)
		cpu_if.en_cpu |=> !cpu_if.en_cpu)
	else assertion_fail("en_cpu_i was held for more than one cycle"); 

endmodule: cpu_tb_top
