import fixed_pkg::*;

module fixed_addsub (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          en,
    input  fixed_t         a,
    input  fixed_t         b,
    input  logic          sub,
    output fixed_t         result,
    output logic          valid
);
    logic signed [FIXED_WIDTH:0] sum_ext;
    fixed_t sat_pos, sat_neg;

    assign sat_pos = {1'b0, {(FIXED_WIDTH-1){1'b1}}};
    assign sat_neg = {1'b1, {(FIXED_WIDTH-1){1'b0}}};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= '0;
            valid  <= 1'b0;
        end else begin
            valid <= en;
            if (en) begin
                sum_ext = sub ? ({a[FIXED_WIDTH-1], a} - {b[FIXED_WIDTH-1], b})
                              : ({a[FIXED_WIDTH-1], a} + {b[FIXED_WIDTH-1], b});
                if (sum_ext > $signed({1'b0, sat_pos[FIXED_WIDTH-1:0]}))
                    result <= sat_pos;
                else if (sum_ext < $signed({1'b1, sat_neg[FIXED_WIDTH-1:0]}))
                    result <= sat_neg;
                else
                    result <= sum_ext[FIXED_WIDTH-1:0];
            end
        end
    end
endmodule
