// =============================================================
// box_intersection.sv - ray / axis-aligned box intersection (slab method)
//
// Ray: P(t) = O + t*D.   The caller supplies inv_dx/inv_dy/inv_dz = 1/D (they depend only on the
// pixel, so the render engine computes them once per pixel and shares them between all boxes).
//
//   for each axis:  t1 = (c - h - O) * invD,  t2 = (c + h - O) * invD;  lo = min(t1,t2), hi = max(t1,t2)
//   t_near = max(lo_x, lo_y, lo_z)   (x wins ties, then y, then z -- the golden model does the same)
//   t_far  = min(hi_x, hi_y, hi_z)
//   hit    = t_near <= t_far && t_near > 0        (the camera is never inside a box)
//   normal = -sign(D) on the axis that gave t_near (the face the ray entered through)
//   P      = O + t_near * D
//
// One result every ~7 cycles, no divide and no square root.  Products saturate instead of wrapping.
// All inputs must be held stable from `start` until `done`.  Outputs are only meaningful when `hit` = 1.
// =============================================================
import fixed_pkg::*;

module box_intersection (
    input  logic  clk,
    input  logic  rst_n,
    input  logic  start,

    input  fixed_t ox, oy, oz,
    input  fixed_t dx, dy, dz,
    input  fixed_t inv_dx, inv_dy, inv_dz,

    input  fixed_t cx, cy, cz,          // box centre
    input  fixed_t hx, hy, hz,          // half-extents

    output logic  hit,
    output fixed_t t_hit,
    output fixed_t hit_x, hit_y, hit_z,
    output fixed_t normal_x, normal_y, normal_z,
    output logic  done
);
    // saturating Q12.20 multiply (rounds to nearest)
    function automatic fixed_t smul(input fixed_t a, input fixed_t b);
        logic signed [63:0] p;
        begin
            p = (64'(a) * 64'(b) + 64'sd524288) >>> FRAC_BITS;
            if (p > 64'sh7FFFFFFF)       smul = 32'sh7FFFFFFF;
            else if (p < -64'sh80000000) smul = 32'sh80000000;
            else                         smul = fixed_t'(p);
        end
    endfunction

    typedef enum logic [2:0] { B_IDLE, B_DIFF, B_T, B_MINMAX, B_NEAR, B_HIT, B_DONE } bstate_t;
    bstate_t st;

    fixed_t d1x, d1y, d1z, d2x, d2y, d2z;       // (c-h-O), (c+h-O)
    fixed_t t1x, t1y, t1z, t2x, t2y, t2z;
    fixed_t lox, loy, loz, hix, hiy, hiz;
    fixed_t tn, tf;
    logic [1:0] axis;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= B_IDLE; done <= 1'b0; hit <= 1'b0; t_hit <= '0;
            hit_x <= '0; hit_y <= '0; hit_z <= '0; normal_x <= '0; normal_y <= '0; normal_z <= '0;
            tn <= '0; tf <= '0; axis <= '0;
        end else begin
            done <= 1'b0;
            case (st)
                B_IDLE: if (start) st <= B_DIFF;

                B_DIFF: begin
                    d1x <= cx - hx - ox;  d2x <= cx + hx - ox;
                    d1y <= cy - hy - oy;  d2y <= cy + hy - oy;
                    d1z <= cz - hz - oz;  d2z <= cz + hz - oz;
                    st  <= B_T;
                end

                B_T: begin
                    t1x <= smul(d1x, inv_dx);  t2x <= smul(d2x, inv_dx);
                    t1y <= smul(d1y, inv_dy);  t2y <= smul(d2y, inv_dy);
                    t1z <= smul(d1z, inv_dz);  t2z <= smul(d2z, inv_dz);
                    st  <= B_MINMAX;
                end

                B_MINMAX: begin
                    lox <= (t1x < t2x) ? t1x : t2x;  hix <= (t1x < t2x) ? t2x : t1x;
                    loy <= (t1y < t2y) ? t1y : t2y;  hiy <= (t1y < t2y) ? t2y : t1y;
                    loz <= (t1z < t2z) ? t1z : t2z;  hiz <= (t1z < t2z) ? t2z : t1z;
                    st  <= B_NEAR;
                end

                B_NEAR: begin
                    // t_near = max of the lo's (strictly greater wins, so ties keep the earlier axis)
                    if (loy > lox && loy >= loz)      begin tn <= loy; axis <= 2'd1; end
                    else if (loz > lox && loz > loy)  begin tn <= loz; axis <= 2'd2; end
                    else                              begin tn <= lox; axis <= 2'd0; end
                    tf <= (hix < hiy ? (hix < hiz ? hix : hiz) : (hiy < hiz ? hiy : hiz));
                    st <= B_HIT;
                end

                B_HIT: begin
                    hit   <= (tn <= tf) && (tn > 0);
                    t_hit <= tn;
                    hit_x <= ox + smul(tn, dx);
                    hit_y <= oy + smul(tn, dy);
                    hit_z <= oz + smul(tn, dz);
                    normal_x <= (axis == 2'd0) ? ((dx > 0) ? -FIXED_ONE : FIXED_ONE) : '0;
                    normal_y <= (axis == 2'd1) ? ((dy > 0) ? -FIXED_ONE : FIXED_ONE) : '0;
                    normal_z <= (axis == 2'd2) ? ((dz > 0) ? -FIXED_ONE : FIXED_ONE) : '0;
                    st    <= B_DONE;
                end

                B_DONE: begin done <= 1'b1; st <= B_IDLE; end
                default: st <= B_IDLE;
            endcase
        end
    end
endmodule
