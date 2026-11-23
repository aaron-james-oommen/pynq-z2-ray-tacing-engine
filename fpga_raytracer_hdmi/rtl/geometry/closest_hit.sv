import fixed_pkg::*;

module closest_hit #(
    parameter int NUM_SPHERES = 4
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic  [NUM_SPHERES-1:0]    hit_in,
    input  fixed_t                     t_in     [NUM_SPHERES],
    input  fixed_t                     hitx_in  [NUM_SPHERES],
    input  fixed_t                     hity_in  [NUM_SPHERES],
    input  fixed_t                     hitz_in  [NUM_SPHERES],
    input  fixed_t                     normx_in [NUM_SPHERES],
    input  fixed_t                     normy_in [NUM_SPHERES],
    input  fixed_t                     normz_in [NUM_SPHERES],
    input  logic  [$clog2(NUM_SPHERES)-1:0] id_in [NUM_SPHERES],
    input  logic                       valid_in,

    output logic                       any_hit,
    output fixed_t                     t_out,
    output fixed_t                     hitx_out, hity_out, hitz_out,
    output fixed_t                     normx_out, normy_out, normz_out,
    output logic  [$clog2(NUM_SPHERES)-1:0] object_id,
    output logic                       valid_out
);
    fixed_t best_t;
    int     best_idx;
    logic   t_is_negative;

    always_comb begin
        best_t   = {1'b0, {(FIXED_WIDTH-1){1'b1}}};
        best_idx = -1;
        for (int i = 0; i < NUM_SPHERES; i++) begin
            t_is_negative = (t_in[i] < 0);
            if (hit_in[i] && !t_is_negative && (t_in[i] < best_t)) begin
                best_t   = t_in[i];
                best_idx = i;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            any_hit   <= 1'b0;
            valid_out <= 1'b0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) begin
                any_hit <= (best_idx != -1);
                if (best_idx != -1) begin
                    t_out      <= t_in[best_idx];
                    hitx_out   <= hitx_in[best_idx];
                    hity_out   <= hity_in[best_idx];
                    hitz_out   <= hitz_in[best_idx];
                    normx_out  <= normx_in[best_idx];
                    normy_out  <= normy_in[best_idx];
                    normz_out  <= normz_in[best_idx];
                    object_id  <= id_in[best_idx];
                end
            end
        end
    end
endmodule
