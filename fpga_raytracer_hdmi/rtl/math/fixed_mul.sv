import fixed_pkg::*;

module fixed_mul (
    input  logic   clk,
    input  logic   rst_n,
    input  logic   en,
    input  fixed_t  a,
    input  fixed_t  b,
    output fixed_t  result,
    output logic   valid
);
    localparam int WIDE = 2*FIXED_WIDTH;

    logic signed [WIDE-1:0] prod_stage1;
    logic                   valid_stage1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_stage1  <= '0;
            valid_stage1 <= 1'b0;
        end else begin
            valid_stage1 <= en;
            if (en)
                prod_stage1 <= a * b;
        end
    end

    logic signed [WIDE-1:0] shifted;
    logic signed [WIDE-1:0] max_pos, max_neg;

    assign max_pos = {{(WIDE-FIXED_WIDTH+1){1'b0}}, {(FIXED_WIDTH-1){1'b1}}};
    assign max_neg = {{(WIDE-FIXED_WIDTH+1){1'b1}}, {(FIXED_WIDTH-1){1'b0}}};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= '0;
            valid  <= 1'b0;
        end else begin
            valid   <= valid_stage1;
            shifted  = prod_stage1 >>> FRAC_BITS;
            if (shifted > max_pos)
                result <= max_pos[FIXED_WIDTH-1:0];
            else if (shifted < max_neg)
                result <= max_neg[FIXED_WIDTH-1:0];
            else
                result <= shifted[FIXED_WIDTH-1:0];
        end
    end
endmodule
