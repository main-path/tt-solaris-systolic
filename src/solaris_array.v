`default_nettype none
module pe (
	clk,
	rst_n,
	en,
	drain,
	a_in,
	b_in,
	clr_in,
	acc_in,
	a_out,
	b_out,
	clr_out,
	acc_out
);
	parameter signed [31:0] DW = 8;
	parameter signed [31:0] AW = 32;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire drain;
	input wire signed [DW - 1:0] a_in;
	input wire signed [DW - 1:0] b_in;
	input wire clr_in;
	input wire signed [AW - 1:0] acc_in;
	output reg signed [DW - 1:0] a_out;
	output reg signed [DW - 1:0] b_out;
	output reg clr_out;
	output wire signed [AW - 1:0] acc_out;
	reg signed [AW - 1:0] acc;
	wire signed [(2 * DW) - 1:0] prod = a_in * b_in;
	function automatic signed [AW - 1:0] sv2v_cast_DE851_signed;
		input reg signed [AW - 1:0] inp;
		sv2v_cast_DE851_signed = inp;
	endfunction
	wire signed [AW - 1:0] prod_ext = sv2v_cast_DE851_signed(prod);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			a_out <= 1'sb0;
			b_out <= 1'sb0;
			clr_out <= 1'b0;
			acc <= 1'sb0;
		end
		else if (drain)
			acc <= acc_in;
		else if (en) begin
			a_out <= a_in;
			b_out <= b_in;
			clr_out <= clr_in;
			acc <= (clr_in ? {AW {1'b0}} : acc) + prod_ext;
		end
	assign acc_out = acc;
endmodule
`default_nettype wire
`default_nettype none
module systolic_array (
	clk,
	rst_n,
	en,
	clr,
	drain,
	a_west,
	b_north,
	c_south
);
	parameter signed [31:0] N = 4;
	parameter signed [31:0] DW = 8;
	parameter signed [31:0] AW = 32;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire clr;
	input wire drain;
	input wire [(N * DW) - 1:0] a_west;
	input wire [(N * DW) - 1:0] b_north;
	output wire [(N * AW) - 1:0] c_south;
	wire signed [DW - 1:0] a_in [0:N - 1];
	wire signed [DW - 1:0] b_in [0:N - 1];
	wire signed [DW - 1:0] a_skew [0:N - 1];
	wire signed [DW - 1:0] b_skew [0:N - 1];
	wire clr_skew [0:N - 1];
	genvar _gv_i_1;
	genvar _gv_j_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < N; _gv_i_1 = _gv_i_1 + 1) begin : g_unpack
			localparam i = _gv_i_1;
			assign a_in[i] = a_west[i * DW+:DW];
			assign b_in[i] = b_north[i * DW+:DW];
		end
		for (_gv_i_1 = 0; _gv_i_1 < N; _gv_i_1 = _gv_i_1 + 1) begin : g_a_skew
			localparam i = _gv_i_1;
			if (i == 0) begin : g_a0
				assign a_skew[0] = a_in[0];
				assign clr_skew[0] = clr;
			end
			else begin : g_ai
				reg signed [DW - 1:0] sr [0:i - 1];
				reg csr [0:i - 1];
				always @(posedge clk or negedge rst_n)
					if (!rst_n) begin : sv2v_autoblock_1
						reg signed [31:0] q;
						for (q = 0; q < i; q = q + 1)
							begin
								sr[q] <= 1'sb0;
								csr[q] <= 1'b0;
							end
					end
					else if (en) begin
						sr[0] <= a_in[i];
						csr[0] <= clr;
						begin : sv2v_autoblock_2
							reg signed [31:0] q;
							for (q = 1; q < i; q = q + 1)
								begin
									sr[q] <= sr[q - 1];
									csr[q] <= csr[q - 1];
								end
						end
					end
				assign a_skew[i] = sr[i - 1];
				assign clr_skew[i] = csr[i - 1];
			end
		end
		for (_gv_j_1 = 0; _gv_j_1 < N; _gv_j_1 = _gv_j_1 + 1) begin : g_b_skew
			localparam j = _gv_j_1;
			if (j == 0) begin : g_b0
				assign b_skew[0] = b_in[0];
			end
			else begin : g_bj
				reg signed [DW - 1:0] sr [0:j - 1];
				always @(posedge clk or negedge rst_n)
					if (!rst_n) begin : sv2v_autoblock_3
						reg signed [31:0] q;
						for (q = 0; q < j; q = q + 1)
							sr[q] <= 1'sb0;
					end
					else if (en) begin
						sr[0] <= b_in[j];
						begin : sv2v_autoblock_4
							reg signed [31:0] q;
							for (q = 1; q < j; q = q + 1)
								sr[q] <= sr[q - 1];
						end
					end
				assign b_skew[j] = sr[j - 1];
			end
		end
	endgenerate
	wire signed [DW - 1:0] a_h [0:N - 1][0:N + 0];
	wire c_h [0:N - 1][0:N + 0];
	wire signed [DW - 1:0] b_v [0:N + 0][0:N - 1];
	wire signed [AW - 1:0] a_ch [0:N + 0][0:N - 1];
	generate
		for (_gv_i_1 = 0; _gv_i_1 < N; _gv_i_1 = _gv_i_1 + 1) begin : g_west_edge
			localparam i = _gv_i_1;
			assign a_h[i][0] = a_skew[i];
			assign c_h[i][0] = clr_skew[i];
		end
		for (_gv_j_1 = 0; _gv_j_1 < N; _gv_j_1 = _gv_j_1 + 1) begin : g_north_edge
			localparam j = _gv_j_1;
			assign b_v[0][j] = b_skew[j];
			assign a_ch[0][j] = 1'sb0;
		end
		for (_gv_i_1 = 0; _gv_i_1 < N; _gv_i_1 = _gv_i_1 + 1) begin : g_row
			localparam i = _gv_i_1;
			for (_gv_j_1 = 0; _gv_j_1 < N; _gv_j_1 = _gv_j_1 + 1) begin : g_col
				localparam j = _gv_j_1;
				pe #(
					.DW(DW),
					.AW(AW)
				) u_pe(
					.clk(clk),
					.rst_n(rst_n),
					.en(en),
					.drain(drain),
					.a_in(a_h[i][j]),
					.b_in(b_v[i][j]),
					.clr_in(c_h[i][j]),
					.acc_in(a_ch[i][j]),
					.a_out(a_h[i][j + 1]),
					.b_out(b_v[i + 1][j]),
					.clr_out(c_h[i][j + 1]),
					.acc_out(a_ch[i + 1][j])
				);
			end
		end
		for (_gv_j_1 = 0; _gv_j_1 < N; _gv_j_1 = _gv_j_1 + 1) begin : g_south_edge
			localparam j = _gv_j_1;
			assign c_south[j * AW+:AW] = a_ch[N][j];
		end
	endgenerate
endmodule
`default_nettype wire