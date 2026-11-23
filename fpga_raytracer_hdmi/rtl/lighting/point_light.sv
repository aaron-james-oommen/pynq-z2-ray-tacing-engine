// =============================================================
// point_light.sv - unit vector from a surface point to a point light
//
//   d = Lpos - P            (vector_sub)
//   len = sqrt(d . d)       (dot_product, fixed_sqrt)
//   inv = 1 / len           (fixed_div)
//   u = d * inv             (vector_scale)      -> unit vector toward the light
//
// Because u depends on P, moving the object changes the light direction at every
// surface point -- that is what makes highlights track the object, unlike a
// directional light.  The result feeds lambert.sv as its L input.
//
// Inputs must be held stable from `start` until `valid`.  Latency about 90 cycles
// (1 sub + 4 dot + 26 sqrt + 52 divide + 2 scale + control).
// =============================================================
import fixed_pkg::*;

module point_light (
    input  logic  clk,
    input  logic  rst_n,
    input  logic  start,
    input  fixed_t px, py, pz,            // surface point
    input  fixed_t lpx, lpy, lpz,         // light position
    output fixed_t ux, uy, uz,            // unit vector toward the light
    output logic  valid
);
    typedef enum logic [2:0] {P_IDLE, P_SUB_W, P_DOT_W, P_SQRT_W, P_DIV_W, P_SCL_W} state_t;
    state_t state;

    fixed_t dx, dy, dz;

    logic vsub_en; fixed_t vsub_ax, vsub_ay, vsub_az, vsub_bx, vsub_by, vsub_bz, vsub_rx, vsub_ry, vsub_rz; logic vsub_valid;
    vector_sub u_vsub (.clk, .rst_n, .en(vsub_en),
        .ax(vsub_ax), .ay(vsub_ay), .az(vsub_az), .bx(vsub_bx), .by(vsub_by), .bz(vsub_bz),
        .rx(vsub_rx), .ry(vsub_ry), .rz(vsub_rz), .valid(vsub_valid));

    logic dot_en; fixed_t dot_ax, dot_ay, dot_az, dot_result; logic dot_valid;
    dot_product u_dot (.clk, .rst_n, .en(dot_en),
        .ax(dot_ax), .ay(dot_ay), .az(dot_az), .bx(dot_ax), .by(dot_ay), .bz(dot_az),
        .result(dot_result), .valid(dot_valid));

    logic sqrt_start; fixed_t sqrt_in, sqrt_result; logic sqrt_done;
    fixed_sqrt u_sqrt (.clk, .rst_n, .start(sqrt_start), .radicand(sqrt_in), .result(sqrt_result), .done(sqrt_done));

    logic div_start; fixed_t div_a, div_b, div_result; logic div_done, div_dz;
    fixed_div u_div (.clk, .rst_n, .start(div_start), .a(div_a), .b(div_b),
                     .result(div_result), .done(div_done), .div_by_zero(div_dz));

    logic vscl_en; fixed_t vscl_s, vscl_rx, vscl_ry, vscl_rz; logic vscl_valid;
    vector_scale u_vscl (.clk, .rst_n, .en(vscl_en), .vx(dx), .vy(dy), .vz(dz), .s(vscl_s),
        .rx(vscl_rx), .ry(vscl_ry), .rz(vscl_rz), .valid(vscl_valid));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= P_IDLE; valid <= 1'b0;
            vsub_en <= 1'b0; dot_en <= 1'b0; sqrt_start <= 1'b0; div_start <= 1'b0; vscl_en <= 1'b0;
            ux <= '0; uy <= '0; uz <= '0;
        end else begin
            vsub_en <= 1'b0; dot_en <= 1'b0; sqrt_start <= 1'b0; div_start <= 1'b0; vscl_en <= 1'b0;
            valid <= 1'b0;
            case (state)
                P_IDLE: if (start) begin
                    vsub_ax <= lpx; vsub_ay <= lpy; vsub_az <= lpz;
                    vsub_bx <= px;  vsub_by <= py;  vsub_bz <= pz;
                    vsub_en <= 1'b1;
                    state   <= P_SUB_W;
                end
                P_SUB_W: if (vsub_valid) begin
                    dx <= vsub_rx; dy <= vsub_ry; dz <= vsub_rz;
                    dot_ax <= vsub_rx; dot_ay <= vsub_ry; dot_az <= vsub_rz;
                    dot_en <= 1'b1;
                    state  <= P_DOT_W;
                end
                P_DOT_W: if (dot_valid) begin
                    sqrt_in <= dot_result; sqrt_start <= 1'b1;
                    state   <= P_SQRT_W;
                end
                P_SQRT_W: if (sqrt_done) begin
                    div_a <= FIXED_ONE; div_b <= sqrt_result; div_start <= 1'b1;
                    state <= P_DIV_W;
                end
                P_DIV_W: if (div_done) begin
                    vscl_s <= div_result; vscl_en <= 1'b1;
                    state  <= P_SCL_W;
                end
                P_SCL_W: if (vscl_valid) begin
                    ux <= vscl_rx; uy <= vscl_ry; uz <= vscl_rz;
                    valid <= 1'b1;
                    state <= P_IDLE;
                end
                default: state <= P_IDLE;
            endcase
        end
    end
endmodule
