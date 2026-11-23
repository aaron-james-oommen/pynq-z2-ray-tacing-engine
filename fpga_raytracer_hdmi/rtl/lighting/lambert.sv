// =============================================================
// lambert.sv  -  Lambertian diffuse shading
//
//   brightness = max(AMBIENT, clamp(N . L, 0, 1))      (N, L unit vectors, Q12.20)
//   colour     = floor(object_colour * brightness)      per 8-bit channel
//
// Fixed-point bookkeeping: brightness is Q12.20 in [0, 1]; an 8-bit channel is a
// plain integer.  integer * Q.20 = Q.20, so one right shift by FRAC_BITS gives the
// final 0..255 value directly -- no 1/255 and *255 round trip (the previous
// version shifted the colour by 20 bits twice, which zeroed every channel).
//
// Latency: 6 cycles (dot product 4 + clamp 1 + multiply 1).
// =============================================================
import fixed_pkg::*;

module lambert #(
    // brightness floor (Q12.20, 0 .. 1): nothing is darker than this.  0 = pure Lambert.
    parameter fixed_t AMBIENT = 0
) (
    input  logic  clk,
    input  logic  rst_n,
    input  logic  en,

    input  fixed_t nx, ny, nz,       // unit surface normal  (hold stable while en is high)
    input  fixed_t lx, ly, lz,       // unit vector toward the light

    input  logic [7:0] obj_r, obj_g, obj_b,

    output logic [7:0] out_r, out_g, out_b,
    output logic  valid
);
    fixed_t ndotl;
    logic   dot_valid;

    dot_product u_dot (
        .clk, .rst_n, .en,
        .ax(nx), .ay(ny), .az(nz),
        .bx(lx), .by(ly), .bz(lz),
        .result(ndotl), .valid(dot_valid)
    );

    // clamp to [0, 1]
    logic [FRAC_BITS:0] brightness;      // 0 .. 2^20
    logic               clamp_valid;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            brightness  <= '0;
            clamp_valid <= 1'b0;
        end else begin
            clamp_valid <= dot_valid;
            if (dot_valid) begin
                if (ndotl <= 0)                brightness <= AMBIENT[FRAC_BITS:0];
                else if (ndotl >= FIXED_ONE)   brightness <= {1'b1, {FRAC_BITS{1'b0}}};
                else if (ndotl[FRAC_BITS:0] < AMBIENT[FRAC_BITS:0]) brightness <= AMBIENT[FRAC_BITS:0];
                else                           brightness <= ndotl[FRAC_BITS:0];
            end
        end
    end

    // scale each channel
    logic [FRAC_BITS+8:0] pr, pg, pb;
    assign pr = brightness * obj_r;
    assign pg = brightness * obj_g;
    assign pb = brightness * obj_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid <= 1'b0;
            out_r <= '0; out_g <= '0; out_b <= '0;
        end else begin
            valid <= clamp_valid;
            if (clamp_valid) begin
                out_r <= pr[FRAC_BITS+7:FRAC_BITS];
                out_g <= pg[FRAC_BITS+7:FRAC_BITS];
                out_b <= pb[FRAC_BITS+7:FRAC_BITS];
            end
        end
    end
endmodule
