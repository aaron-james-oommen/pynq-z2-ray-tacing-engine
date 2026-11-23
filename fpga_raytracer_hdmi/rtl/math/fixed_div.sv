import fixed_pkg::*;

module fixed_div (
    input  logic  clk,
    input  logic  rst_n,
    input  logic  start,
    input  fixed_t a,
    input  fixed_t b,
    output fixed_t result,
    output logic  done,
    output logic  div_by_zero
);
    localparam int EXT = FIXED_WIDTH + FRAC_BITS;

    logic [EXT-1:0] dividend;
    logic [EXT-1:0] divisor;
    logic [EXT-1:0] remainder;
    logic [EXT-1:0] quotient;
    logic [$clog2(EXT+1)-1:0] count;
    logic busy, sign_result;
    logic [EXT-1:0] rem_shifted;
    logic [EXT-1:0] final_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy        <= 1'b0;
            done        <= 1'b0;
            div_by_zero <= 1'b0;
            result      <= '0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                if (b == 0) begin
                    div_by_zero <= 1'b1;
                    done        <= 1'b1;
                    result      <= '0;
                end else begin
                    div_by_zero <= 1'b0;
                    sign_result <= a[FIXED_WIDTH-1] ^ b[FIXED_WIDTH-1];
                    dividend    <= ({{(FRAC_BITS){1'b0}}, (a[FIXED_WIDTH-1] ? -a : a)}) <<< FRAC_BITS;
                    divisor     <= {{(FRAC_BITS){1'b0}}, (b[FIXED_WIDTH-1] ? -b : b)};
                    remainder   <= '0;
                    quotient    <= '0;
                    count       <= '0;
                    busy        <= 1'b1;
                end
            end else if (busy) begin
                rem_shifted = (remainder <<< 1) | dividend[EXT-1];
                if (rem_shifted >= divisor) begin
                    remainder <= rem_shifted - divisor;
                    quotient  <= (quotient <<< 1) | 1'b1;
                end else begin
                    remainder <= rem_shifted;
                    quotient  <= quotient <<< 1;
                end
                dividend <= dividend <<< 1;
                count    <= count + 1'b1;

                if (count == EXT-1) begin
                    busy       <= 1'b0;
                    done       <= 1'b1;
                    final_q     = ((quotient <<< 1) | (rem_shifted >= divisor));
                    result     <= sign_result ? -final_q[FIXED_WIDTH-1:0] : final_q[FIXED_WIDTH-1:0];
                end
            end
        end
    end
endmodule
