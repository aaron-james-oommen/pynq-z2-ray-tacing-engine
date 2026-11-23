// =============================================================
// sphere_intersection.sv  -  ray / sphere intersection with hit point and normal
//
// Ray: P(t) = O + t*D.   D does NOT have to be unit length.
//
//   oc   = O - C
//   a    = D . D                    (>= 1 for the camera rays: D = (sx, sy, 1))
//   h    = D . oc                   (half of the usual "b")
//   c    = oc . oc - r^2
//   disc = h^2 - a*c                (the usual b^2 - 4ac, divided by 4)
//   miss if disc < 0
//   s    = sqrt(disc)
//   near root numerator  n1 = -h - s;   far root numerator  n2 = -h + s
//   take the first of n1, n2 that is > 0     (n2 handles "camera inside the sphere";
//                                             both <= 0 means "sphere behind the ray")
//   t    = n / a                    (a > 0, so the sign of t is the sign of n: one divide)
//   P    = O + t*D
//   N    = (P - C) * (1/r)          (already unit length -- no normalise needed)
//
// Using the general `a` is what lets the ray generator skip normalising D
// (saves a sqrt and three divides per ray).  1/r is supplied by the caller as a
// constant so the normal needs three multiplies instead of three divides.
//
// All inputs must be held stable from `start` until `done`.
// Outputs hit_*/normal_* are only meaningful when `hit` = 1 at `done`.
// Throughput: ~100 cycles per ray (dominated by the 52-cycle divide + 26-cycle sqrt).
// =============================================================
import fixed_pkg::*;

module sphere_intersection (
    input  logic  clk,
    input  logic  rst_n,
    input  logic  start,

    input  fixed_t ox, oy, oz,          // ray origin
    input  fixed_t dx, dy, dz,          // ray direction (any length)

    input  fixed_t cx, cy, cz,          // sphere centre
    input  fixed_t radius,
    input  fixed_t inv_radius,          // 1/radius (Q12.20)

    output logic  hit,
    output fixed_t t_hit,
    output fixed_t hit_x, hit_y, hit_z,
    output fixed_t normal_x, normal_y, normal_z,
    output logic  done
);
    typedef enum logic [4:0] {
        S_IDLE,
        S_OC_W,                 // oc = O - C
        S_A_W,                  // a = D.D
        S_H_W,                  // h = D.oc
        S_C0_W,                 // oc.oc
        S_RR_W,                 // r*r
        S_C_W,                  // c = oc.oc - r^2
        S_HH_W,                 // h*h
        S_AC_W,                 // a*c
        S_DISC_W,               // disc = h^2 - a*c
        S_SQRT_W,               // s = sqrt(disc)
        S_N1_W,                 // n1 = -h - s
        S_N2_W,                 // n2 = -h + s
        S_DIV_W,                // t = n / a
        S_TD_W,                 // t * D
        S_P_W,                  // P = O + t*D
        S_PC_W,                 // P - C
        S_N_W                   // N = (P - C) * inv_r
    } state_t;

    state_t state;

    fixed_t ocx, ocy, ocz;
    fixed_t a_val, h_val, c_val, hh_val, s_val;

    // ---- shared units (inputs are registered and set in the cycle before `en` pulses) ----
    logic   vsub_en;  fixed_t vsub_ax, vsub_ay, vsub_az, vsub_bx, vsub_by, vsub_bz;
    fixed_t vsub_rx, vsub_ry, vsub_rz;  logic vsub_valid;
    vector_sub u_vsub (.clk, .rst_n, .en(vsub_en),
        .ax(vsub_ax), .ay(vsub_ay), .az(vsub_az), .bx(vsub_bx), .by(vsub_by), .bz(vsub_bz),
        .rx(vsub_rx), .ry(vsub_ry), .rz(vsub_rz), .valid(vsub_valid));

    logic   dot_en;   fixed_t dot_ax, dot_ay, dot_az, dot_bx, dot_by, dot_bz;
    fixed_t dot_result; logic dot_valid;
    dot_product u_dot (.clk, .rst_n, .en(dot_en),
        .ax(dot_ax), .ay(dot_ay), .az(dot_az), .bx(dot_bx), .by(dot_by), .bz(dot_bz),
        .result(dot_result), .valid(dot_valid));

    logic   mul_en;   fixed_t mul_a, mul_b, mul_result; logic mul_valid;
    fixed_mul u_mul (.clk, .rst_n, .en(mul_en), .a(mul_a), .b(mul_b),
                     .result(mul_result), .valid(mul_valid));

    logic   add_en;   fixed_t add_a, add_b, add_result; logic add_sub, add_valid;
    fixed_addsub u_add (.clk, .rst_n, .en(add_en), .a(add_a), .b(add_b), .sub(add_sub),
                        .result(add_result), .valid(add_valid));

    logic   sqrt_start; fixed_t sqrt_in, sqrt_result; logic sqrt_done;
    fixed_sqrt u_sqrt (.clk, .rst_n, .start(sqrt_start), .radicand(sqrt_in),
                       .result(sqrt_result), .done(sqrt_done));

    logic   div_start; fixed_t div_a, div_b, div_result; logic div_done, div_dz;
    fixed_div u_div (.clk, .rst_n, .start(div_start), .a(div_a), .b(div_b),
                     .result(div_result), .done(div_done), .div_by_zero(div_dz));

    logic   vscl_en;  fixed_t vscl_x, vscl_y, vscl_z, vscl_s;
    fixed_t vscl_rx, vscl_ry, vscl_rz; logic vscl_valid;
    vector_scale u_vscl (.clk, .rst_n, .en(vscl_en),
        .vx(vscl_x), .vy(vscl_y), .vz(vscl_z), .s(vscl_s),
        .rx(vscl_rx), .ry(vscl_ry), .rz(vscl_rz), .valid(vscl_valid));

    logic   vadd_en;  fixed_t vadd_ax, vadd_ay, vadd_az, vadd_bx, vadd_by, vadd_bz;
    fixed_t vadd_rx, vadd_ry, vadd_rz; logic vadd_valid;
    vector_add u_vadd (.clk, .rst_n, .en(vadd_en),
        .ax(vadd_ax), .ay(vadd_ay), .az(vadd_az), .bx(vadd_bx), .by(vadd_by), .bz(vadd_bz),
        .rx(vadd_rx), .ry(vadd_ry), .rz(vadd_rz), .valid(vadd_valid));

    fixed_t neg_h;
    assign neg_h = -h_val;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done  <= 1'b0;
            hit   <= 1'b0;
            vsub_en <= 1'b0; dot_en <= 1'b0; mul_en <= 1'b0; add_en <= 1'b0;
            sqrt_start <= 1'b0; div_start <= 1'b0; vscl_en <= 1'b0; vadd_en <= 1'b0;
        end else begin
            // every "fire" strobe is one cycle wide unless a state re-asserts it below
            vsub_en <= 1'b0; dot_en <= 1'b0; mul_en <= 1'b0; add_en <= 1'b0;
            sqrt_start <= 1'b0; div_start <= 1'b0; vscl_en <= 1'b0; vadd_en <= 1'b0;
            done <= 1'b0;

            case (state)
                S_IDLE: if (start) begin
                    vsub_ax <= ox; vsub_ay <= oy; vsub_az <= oz;
                    vsub_bx <= cx; vsub_by <= cy; vsub_bz <= cz;
                    vsub_en <= 1'b1;
                    state   <= S_OC_W;
                end

                S_OC_W: if (vsub_valid) begin
                    ocx <= vsub_rx; ocy <= vsub_ry; ocz <= vsub_rz;
                    dot_ax <= dx; dot_ay <= dy; dot_az <= dz;          // a = D.D
                    dot_bx <= dx; dot_by <= dy; dot_bz <= dz;
                    dot_en <= 1'b1;
                    state  <= S_A_W;
                end

                S_A_W: if (dot_valid) begin
                    a_val  <= dot_result;
                    dot_ax <= dx;  dot_ay <= dy;  dot_az <= dz;        // h = D.oc
                    dot_bx <= ocx; dot_by <= ocy; dot_bz <= ocz;
                    dot_en <= 1'b1;
                    state  <= S_H_W;
                end

                S_H_W: if (dot_valid) begin
                    h_val  <= dot_result;
                    dot_ax <= ocx; dot_ay <= ocy; dot_az <= ocz;       // oc.oc
                    dot_bx <= ocx; dot_by <= ocy; dot_bz <= ocz;
                    dot_en <= 1'b1;
                    state  <= S_C0_W;
                end

                S_C0_W: if (dot_valid) begin
                    c_val  <= dot_result;                              // temporarily oc.oc
                    mul_a  <= radius; mul_b <= radius; mul_en <= 1'b1; // r^2
                    state  <= S_RR_W;
                end

                S_RR_W: if (mul_valid) begin
                    add_a <= c_val; add_b <= mul_result; add_sub <= 1'b1; add_en <= 1'b1;   // c = oc.oc - r^2
                    state <= S_C_W;
                end

                S_C_W: if (add_valid) begin
                    c_val <= add_result;
                    mul_a <= h_val; mul_b <= h_val; mul_en <= 1'b1;    // h^2
                    state <= S_HH_W;
                end

                S_HH_W: if (mul_valid) begin
                    hh_val <= mul_result;
                    mul_a  <= a_val; mul_b <= c_val; mul_en <= 1'b1;   // a*c
                    state  <= S_AC_W;
                end

                S_AC_W: if (mul_valid) begin
                    add_a <= hh_val; add_b <= mul_result; add_sub <= 1'b1; add_en <= 1'b1;  // disc = h^2 - a*c
                    state <= S_DISC_W;
                end

                S_DISC_W: if (add_valid) begin
                    if (add_result[FIXED_WIDTH-1]) begin               // disc < 0  -> miss
                        hit   <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        sqrt_in    <= add_result;
                        sqrt_start <= 1'b1;
                        state      <= S_SQRT_W;
                    end
                end

                S_SQRT_W: if (sqrt_done) begin
                    s_val <= sqrt_result;                              // keep s for the far root
                    add_a <= neg_h; add_b <= sqrt_result; add_sub <= 1'b1; add_en <= 1'b1;  // n1 = -h - s
                    state <= S_N1_W;
                end

                S_N1_W: if (add_valid) begin
                    if (add_result > 0) begin                          // near root is in front of the ray
                        div_a     <= add_result; div_b <= a_val; div_start <= 1'b1;
                        state     <= S_DIV_W;
                    end else begin                                     // try the far root: n2 = -h + s
                        add_a <= neg_h; add_b <= s_val; add_sub <= 1'b0; add_en <= 1'b1;
                        state <= S_N2_W;
                    end
                end

                S_N2_W: if (add_valid) begin
                    if (add_result > 0) begin
                        div_a     <= add_result; div_b <= a_val; div_start <= 1'b1;
                        state     <= S_DIV_W;
                    end else begin                                     // both roots behind the origin
                        hit   <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                S_DIV_W: if (div_done) begin
                    t_hit  <= div_result;
                    vscl_x <= dx; vscl_y <= dy; vscl_z <= dz; vscl_s <= div_result;  // t*D
                    vscl_en <= 1'b1;
                    state  <= S_TD_W;
                end

                S_TD_W: if (vscl_valid) begin
                    vadd_ax <= ox; vadd_ay <= oy; vadd_az <= oz;
                    vadd_bx <= vscl_rx; vadd_by <= vscl_ry; vadd_bz <= vscl_rz;
                    vadd_en <= 1'b1;
                    state   <= S_P_W;
                end

                S_P_W: if (vadd_valid) begin
                    hit_x <= vadd_rx; hit_y <= vadd_ry; hit_z <= vadd_rz;
                    vsub_ax <= vadd_rx; vsub_ay <= vadd_ry; vsub_az <= vadd_rz;      // P - C
                    vsub_bx <= cx;      vsub_by <= cy;      vsub_bz <= cz;
                    vsub_en <= 1'b1;
                    state   <= S_PC_W;
                end

                S_PC_W: if (vsub_valid) begin
                    vscl_x <= vsub_rx; vscl_y <= vsub_ry; vscl_z <= vsub_rz; vscl_s <= inv_radius;
                    vscl_en <= 1'b1;
                    state   <= S_N_W;
                end

                S_N_W: if (vscl_valid) begin
                    normal_x <= vscl_rx; normal_y <= vscl_ry; normal_z <= vscl_rz;
                    hit   <= 1'b1;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
