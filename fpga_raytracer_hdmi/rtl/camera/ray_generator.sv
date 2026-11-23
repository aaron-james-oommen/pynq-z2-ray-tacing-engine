// =============================================================
// ray_generator.sv  -  pixel (px,py) -> camera ray
//
//   ndc_x = (2*px+1)/W - 1                     in [-1, 1]
//   ndc_y = 1 - (2*py+1)/H
//   dir   = ( ndc_x * aspect * tan(fov/2),
//             ndc_y *          tan(fov/2),  1 )
//
// The direction is deliberately NOT normalised: the sphere intersection solves
// the general quadratic (a = D.D), so the ray length does not matter, and
// skipping normalisation saves a square root and three divisions per ray.
//
// Fixed-point bookkeeping (this is what the previous version got wrong):
//  * 1/W is NOT stored in Q12.20 (only ~6553 for W=160 -> 0.01 pixel of error
//    after multiplying by up to 319).  It is stored with 40 fraction bits and
//    shifted down AFTER the multiply, so the divide-by-W is accurate to <1 LSB.
//  * Every product is formed in a 64-bit signed variable before shifting back
//    to Q12.20.  In SystemVerilog the width of a product is set by the widest
//    operand/target in the expression, so a 32-bit target silently truncates
//    a 32x32 multiply to 32 bits BEFORE any right shift is applied.
//
// Latency: 2 cycles (en at cycle E -> valid at E+2).
// =============================================================
import fixed_pkg::*;

module ray_generator #(
    parameter int SCREEN_W = 160,
    parameter int SCREEN_H = 120
) (
    input  logic  clk,
    input  logic  rst_n,
    input  logic  en,

    input  logic [$clog2(SCREEN_W)-1:0] px,
    input  logic [$clog2(SCREEN_H)-1:0] py,

    input  fixed_t cam_x, cam_y, cam_z,
    input  fixed_t tan_half_fov,           // Q12.20
    input  fixed_t aspect_ratio,           // Q12.20  (W/H)

    output fixed_t origin_x, origin_y, origin_z,
    output fixed_t dir_x, dir_y, dir_z,    // NOT normalised
    output logic  valid
);
    // 1/W and 1/H with 40 fraction bits, rounded to nearest (integer constant arithmetic only)
    localparam logic [39:0] INV_W40 = 40'(((64'd1 << 40) + (SCREEN_W / 2)) / SCREEN_W);
    localparam logic [39:0] INV_H40 = 40'(((64'd1 << 40) + (SCREEN_H / 2)) / SCREEN_H);

    // ---------------- stage 1: NDC and the combined x scale ----------------
    // (plain continuous assigns on purpose: simulators infer always_comb sensitivity
    //  unreliably when a block writes and then reads its own temporaries)
    logic [10:0]  odd_x, odd_y;                 // 2*p+1  (<= 2*max(W,H)+1)
    logic [51:0]  prod_x, prod_y;               // odd * 1/W (Q.40)
    fixed_t       ndc_x_c, ndc_y_c;
    logic signed [63:0] aspect_tan;

    assign odd_x  = {2'b00, px, 1'b1};          // 2*px + 1
    assign odd_y  = {2'b00, py, 1'b1};
    assign prod_x = odd_x * INV_W40;
    assign prod_y = odd_y * INV_H40;
    // Q.40 -> Q.20 with rounding;  (2p+1)/W  is in (0, 2)
    assign ndc_x_c = fixed_t'((prod_x + 52'd524288) >> FRAC_BITS) - FIXED_ONE;
    assign ndc_y_c = FIXED_ONE - fixed_t'((prod_y + 52'd524288) >> FRAC_BITS);
    assign aspect_tan = ($signed(aspect_ratio) * $signed(tan_half_fov) + 64'sd524288) >>> FRAC_BITS;

    fixed_t ndc_x, ndc_y, scale_x, scale_y;
    fixed_t cx_d, cy_d, cz_d;
    logic   v1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0;
            ndc_x <= '0; ndc_y <= '0; scale_x <= '0; scale_y <= '0;
            cx_d <= '0; cy_d <= '0; cz_d <= '0;
        end else begin
            v1 <= en;
            if (en) begin
                ndc_x   <= ndc_x_c;
                ndc_y   <= ndc_y_c;
                scale_x <= aspect_tan[FIXED_WIDTH-1:0];
                scale_y <= tan_half_fov;
                cx_d <= cam_x; cy_d <= cam_y; cz_d <= cam_z;
            end
        end
    end

    // ---------------- stage 2: scale to camera space ----------------
    logic signed [63:0] sx_wide, sy_wide;
    assign sx_wide = ($signed(ndc_x) * $signed(scale_x) + 64'sd524288) >>> FRAC_BITS;
    assign sy_wide = ($signed(ndc_y) * $signed(scale_y) + 64'sd524288) >>> FRAC_BITS;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid <= 1'b0;
            origin_x <= '0; origin_y <= '0; origin_z <= '0;
            dir_x <= '0; dir_y <= '0; dir_z <= '0;
        end else begin
            valid <= v1;
            if (v1) begin
                origin_x <= cx_d;
                origin_y <= cy_d;
                origin_z <= cz_d;
                dir_x    <= sx_wide[FIXED_WIDTH-1:0];
                dir_y    <= sy_wide[FIXED_WIDTH-1:0];
                dir_z    <= FIXED_ONE;
            end
        end
    end
endmodule
