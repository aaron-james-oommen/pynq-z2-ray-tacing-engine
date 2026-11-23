import fixed_pkg::*;

module fixed_sqrt (
    input  logic  clk,
    input  logic  rst_n,
    input  logic  start,
    input  fixed_t radicand,
    output fixed_t result,
    output logic  done
);
    localparam int EXT = FIXED_WIDTH + FRAC_BITS;

    logic [EXT-1:0] x;
    logic [EXT-1:0] root;
    logic [EXT-1:0] rem;
    logic [$clog2(EXT/2+2)-1:0] count;
    logic busy;
    logic [EXT-1:0] test_rem;
    logic [EXT-1:0] two_bits;
    logic [EXT-1:0] new_root;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            result <= '0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                x     <= {radicand[FIXED_WIDTH-2:0], {(FRAC_BITS){1'b0}}};
                root  <= '0;
                rem   <= '0;
                count <= '0;
                busy  <= 1'b1;
            end else if (busy) begin
                two_bits = {rem[EXT-3:0], x[EXT-1:EXT-2]};
                test_rem = two_bits - ((root <<< 2) | 2'b01);
                if (!test_rem[EXT-1]) begin
                    rem      <= test_rem;
                    new_root  = (root <<< 1) | 1'b1;
                end else begin
                    rem      <= two_bits;
                    new_root  = root <<< 1;
                end
                root  <= new_root;
                x     <= x <<< 2;
                count <= count + 1'b1;
                if (count == EXT/2 - 1) begin
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    result <= new_root[FIXED_WIDTH-1:0];
                end
            end
        end
    end
endmodule
