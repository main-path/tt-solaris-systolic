// -----------------------------------------------------------------------------
// tt_um_mainpath_solaris.v -- Tiny Tapeout wrapper for the Solaris systolic array.
//
// THE PIN PROBLEM
//   Tiny Tapeout gives you 8 dedicated inputs, 8 dedicated outputs and 8
//   bidirectional pins. An N x N int8 array wants N*8 bits of A and N*8 bits of
//   B *every cycle* -- 64 bits at N=4. You cannot feed it directly.
//
//   So the chip is: byte-serial load -> on-chip operand buffer -> array runs at
//   full internal rate from the buffer -> results held -> byte-serial readout.
//
//   That is not a workaround, it is the correct architecture in miniature. A real
//   accelerator is exactly this: a scratchpad feeding the array, because off-chip
//   bandwidth is always the binding constraint.
//
// TIMING: WHY THE OPERAND FETCH IS PIPELINED
//   The obvious implementation reads opmem combinationally from the step counter
//   and drives the array in the same cycle:
//       a_west = opmem[k*N + cnt]
//   That makes `cnt` the select of a 2*N*N-byte multiplexer whose output feeds
//   the array's first rank of flops. A real LibreLane run on sky130 showed this
//   as THE critical path -- startpoint cnt[0], -19.7 ns setup slack at the slow
//   corner (~25 MHz instead of the intended 50 MHz), with 5236 max-slew
//   violations from the counter's fanout.
//
//   The fix is to cut the path with a register: the mux now drives a pipeline
//   register (a_west/b_north) and the array is fed from that register the
//   following cycle. Fetch index and array enable are staged to match, so the
//   array still sees one operand pair per cycle -- the sequence is shifted by
//   one cycle, at the cost of a single extra cycle per matmul.
//
//   uo_out is registered for the same reason: rd_ptr -> 16:1 word mux -> 4:1
//   byte mux -> output pad is a long combinational path to a chip pin.
//
// PROTOCOL
//   Load    : hold wr=1, present one byte on ui_in per clock.
//             First N*N bytes fill A (row-major), next N*N fill B (row-major).
//   Compute : pulse start. busy is high while running, done latches when finished.
//   Read    : hold rd=1. uo_out is REGISTERED, so the first byte appears one
//             clock after rd is asserted; thereafter one byte per clock.
//             Little-endian within each 32-bit accumulator, C row-major.
//   rst_ptr : clears both pointers without disturbing stored data.
//
// PIN MAP
//   ui_in [7:0] : data byte in
//   uo_out[7:0] : data byte out (registered)
//   uio_in[2]   : wr        uio_out[0] : busy
//   uio_in[3]   : start     uio_out[1] : done
//   uio_in[4]   : rd        (uio_oe = 8'b0000_0011)
//   uio_in[5]   : rst_ptr
//
// Deliberately plain Verilog-2005. The array underneath is SystemVerilog
// converted by sv2v; keeping the harness-facing wrapper simple removes one
// class of open-flow surprise.
// -----------------------------------------------------------------------------
`default_nettype none

module tt_um_mainpath_solaris #(
    parameter integer N  = 4,   // array dimension -- set by tile budget
    parameter integer DW = 8,   // operand width
    parameter integer AW = 32   // accumulator width
) (
    input  wire [7:0] ui_in,    // dedicated inputs
    output wire [7:0] uo_out,   // dedicated outputs
    input  wire [7:0] uio_in,   // bidirectional: input path
    output wire [7:0] uio_out,  // bidirectional: output path
    output wire [7:0] uio_oe,   // bidirectional: 1 = drive out
    input  wire       ena,      // high while the design is selected
    input  wire       clk,
    input  wire       rst_n
);

    localparam integer NN       = N * N;
    localparam integer OPBYTES  = 2 * NN;          // A then B
    localparam integer BPW      = AW / 8;          // bytes per accumulator
    localparam integer RESBYTES = NN * BPW;
    // Array-enable cycles needed after the last operand is registered, so the
    // wavefront reaches PE(N-1,N-1). The +1 covers the fetch pipeline stage.
    localparam integer FLUSH    = 2*(N-1) + 1;

    localparam integer WPW = (OPBYTES  > 1) ? $clog2(OPBYTES  + 1) : 1;
    localparam integer RPW = (RESBYTES > 1) ? $clog2(RESBYTES + 1) : 1;
    localparam integer CTW = (N        > 1) ? $clog2(2*N + 2)      : 2;
    localparam integer IXW = (NN       > 1) ? $clog2(NN + 1)       : 1;

    // ---- control decode -----------------------------------------------------
    wire wr      = uio_in[2];
    wire start   = uio_in[3];
    wire rd      = uio_in[4];
    wire rst_ptr = uio_in[5];

    // ---- buffers ------------------------------------------------------------
    // Flops, not SRAM macros: at N<=4 this is tens of bytes, and a macro would
    // cost more area and more flow risk than it saves.
    reg [DW-1:0] opmem  [0:OPBYTES-1];
    reg [AW-1:0] resmem [0:NN-1];

    reg [WPW-1:0] wr_ptr;
    reg [RPW-1:0] rd_ptr;

    // ---- sequencer ----------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0,
                     S_FEED = 2'd1,
                     S_FLSH = 2'd2,
                     S_DRAN = 2'd3;

    reg [1:0]     state;
    reg [CTW-1:0] fetch_idx;   // operand index being READ from opmem this cycle
    reg [CTW-1:0] cnt;         // FLUSH step counter
    reg [IXW-1:0] row_idx;     // DRAIN row counter
    reg           drain_ph;    // 0 = capture, 1 = the shift is happening
    reg           done_r;

    // ---- array interface ----------------------------------------------------
    // a_west/b_north are REGISTERED -- this is the pipeline stage that breaks
    // the fetch-mux critical path.
    reg  [N*DW-1:0] a_west;
    reg  [N*DW-1:0] b_north;
    reg             arr_en, arr_clr, arr_drain;
    wire [N*AW-1:0] c_south;

    systolic_array #(.N(N), .DW(DW), .AW(AW)) u_array (
        .clk    (clk),
        .rst_n  (rst_n),
        .en     (arr_en),
        .clr    (arr_clr),
        .drain  (arr_drain),
        .a_west (a_west),
        .b_north(b_north),
        .c_south(c_south)
    );

    // Combinational operand fetch. Feeds a register, never the array directly.
    //   A row-major at [0 .. NN-1]     -> A[i][t] = opmem[i*N + t]
    //   B row-major at [NN .. 2*NN-1]  -> B[t][j] = opmem[NN + t*N + j]
    reg [N*DW-1:0] a_fetch;
    reg [N*DW-1:0] b_fetch;
    integer k;
    always @(*) begin
        a_fetch = {(N*DW){1'b0}};
        b_fetch = {(N*DW){1'b0}};
        for (k = 0; k < N; k = k + 1) begin
            a_fetch[k*DW +: DW] = opmem[k*N + fetch_idx];
            b_fetch[k*DW +: DW] = opmem[NN + fetch_idx*N + k];
        end
    end

    integer r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr    <= {WPW{1'b0}};
            rd_ptr    <= {RPW{1'b0}};
            state     <= S_IDLE;
            fetch_idx <= {CTW{1'b0}};
            cnt       <= {CTW{1'b0}};
            row_idx   <= {IXW{1'b0}};
            drain_ph  <= 1'b0;
            done_r    <= 1'b0;
            a_west    <= {(N*DW){1'b0}};
            b_north   <= {(N*DW){1'b0}};
            arr_en    <= 1'b0;
            arr_clr   <= 1'b0;
            arr_drain <= 1'b0;
            for (r = 0; r < NN; r = r + 1) resmem[r] <= {AW{1'b0}};
        end else begin
            arr_en    <= 1'b0;
            arr_clr   <= 1'b0;
            arr_drain <= 1'b0;
            a_west    <= {(N*DW){1'b0}};
            b_north   <= {(N*DW){1'b0}};

            if (rst_ptr) begin
                wr_ptr <= {WPW{1'b0}};
                rd_ptr <= {RPW{1'b0}};
            end

            case (state)
                // -------------------------------------------------------------
                S_IDLE: begin
                    if (wr && !rst_ptr && (wr_ptr < OPBYTES[WPW-1:0])) begin
                        opmem[wr_ptr] <= ui_in;
                        wr_ptr        <= wr_ptr + 1'b1;
                    end
                    if (rd && !rst_ptr && (rd_ptr < RESBYTES[RPW-1:0]))
                        rd_ptr <= rd_ptr + 1'b1;

                    if (start) begin
                        state     <= S_FEED;
                        fetch_idx <= {CTW{1'b0}};   // operand 0 is read next cycle
                        cnt       <= {CTW{1'b0}};
                        row_idx   <= {IXW{1'b0}};
                        drain_ph  <= 1'b0;
                        done_r    <= 1'b0;
                    end
                end

                // -------------------------------------------------------------
                // Register the operand pair currently on a_fetch/b_fetch and
                // enable the array to consume it next cycle. The array applies
                // its own i/j skew internally.
                S_FEED: begin
                    a_west  <= a_fetch;
                    b_north <= b_fetch;
                    arr_en  <= 1'b1;
                    arr_clr <= (fetch_idx == {CTW{1'b0}});

                    if (fetch_idx == N[CTW-1:0] - 1'b1) begin
                        cnt   <= {CTW{1'b0}};
                        state <= S_FLSH;
                    end else begin
                        fetch_idx <= fetch_idx + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Keep the array enabled with zero operands so the wavefront
                // reaches the far corner. a_west/b_north already default to 0.
                S_FLSH: begin
                    arr_en <= 1'b1;
                    if (cnt == FLUSH[CTW-1:0] - 1'b1) begin
                        cnt   <= {CTW{1'b0}};
                        state <= S_DRAN;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Capture and shift must ALTERNATE. `drain` shifts the array at
                // the next clock edge, and a capture on that same edge would
                // sample the pre-shift value -- recording row N-1 twice. So:
                //   phase 0: latch c_south (row N-1-row_idx), request a shift
                //   phase 1: the shift lands; advance row_idx
                S_DRAN: begin
                    if (!drain_ph) begin
                        for (r = 0; r < N; r = r + 1)
                            resmem[(N-1-row_idx)*N + r] <= c_south[r*AW +: AW];

                        if (row_idx == (N[IXW-1:0] - 1'b1)) begin
                            state    <= S_IDLE;
                            done_r   <= 1'b1;
                            row_idx  <= {IXW{1'b0}};
                            drain_ph <= 1'b0;
                        end else begin
                            arr_drain <= 1'b1;
                            drain_ph  <= 1'b1;
                        end
                    end else begin
                        row_idx  <= row_idx + 1'b1;
                        drain_ph <= 1'b0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- readout ------------------------------------------------------------
    // Registered: rd_ptr -> word mux -> byte mux -> pad is otherwise a long
    // combinational path straight to a chip output.
    wire [RPW-1:0] word_ix = rd_ptr >> 2;
    wire [1:0]     byte_ix = rd_ptr[1:0];
    wire [AW-1:0]  res_sel = resmem[word_ix[IXW-1:0]];

    reg [7:0] uo_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) uo_r <= 8'b0;
        else        uo_r <= res_sel[byte_ix*8 +: 8];
    end

    assign uo_out  = uo_r;
    assign uio_out = {6'b0, done_r, (state != S_IDLE)};
    assign uio_oe  = 8'b0000_0011;   // [1:0] drive out, [7:2] are inputs

    // ena is driven by the harness and is constant-1 while this design is selected.
    wire _unused = &{ena, uio_in[1:0], uio_in[7:6], 1'b0};

endmodule

`default_nettype wire
