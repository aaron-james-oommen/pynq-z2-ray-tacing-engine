// =============================================================
// render_engine.sv - renders the scene pixel by pixel into a framebuffer write port
//
// For each pixel:
//   1. ray_generator makes the camera ray.
//   2. Every sphere in scene_rom is tested with the (single, shared) sphere_intersection unit;
//      a running "closest so far" record keeps the nearest hit (t, point, normal, colour).
//   3. The ground plane y = GROUND_Y is tested with one divide.  The plane wins only if no sphere
//      is closer; beyond FOG_T it is drawn as the horizon colour (hides checker aliasing).
//   4. Nothing hit -> sky gradient.  Otherwise the light direction (fixed, orbiting or per-point
//      "point light") and lambert give the colour.
//   5. Write the pixel; next pixel; frame_done pulses after the last one, then the next frame starts.
//
// Every constant comes from scene_pkg / scene_rom (generated from the same scene.py as the Python
// golden model), so RTL and golden cannot disagree about the world.
//
// PIXEL_STRIDE > 1 renders only every STRIDE-th pixel in x and y, starting at STRIDE/2.  Used only to
// keep simulations short; the shipped design uses 1.
// =============================================================
module render_engine
    import fixed_pkg::*, scene_pkg::*;
#(
    // 1 = the figure walks: after every frame advance the walk phase and x position (turns at +-WALK_X_MAX)
    parameter bit ANIMATE     = 1'b0,
    // 1 = after every frame swing the directional light one step round its circle (light_rom.sv)
    parameter bit ORBIT_LIGHT = 1'b0,
    // 1 = point light at LPOS: the light direction is computed per hit point
    parameter bit POINT_LIGHT = 1'b0,
    // 1 = shadows (needs POINT_LIGHT): a shadow ray from every lit surface point to the light
    parameter bit SHADOWS     = 1'b0,
    parameter int PIXEL_STRIDE = 1
) (
    input  logic clk,
    input  logic rst_n,

    // walker control (sampled once per frame; a press shorter than a frame is remembered)
    input  logic ctrl_left, ctrl_right,      // walk toward -x / +x
    input  logic ctrl_near, ctrl_far,        // walk toward the camera / away from it (-z / +z)
    input  logic auto_walk,                  // 1 = with no button pressed, walk back and forth by itself
    input  logic cam_follow,                 // 1 = camera follows the walker, 0 = camera returns to its fixed spot

    output logic                               fb_we,
    output logic [$clog2(SCENE_W*SCENE_H)-1:0] fb_waddr,
    output logic [23:0]                        fb_wdata,
    output logic                               frame_done
);
    localparam int START = PIXEL_STRIDE / 2;
    localparam logic [$clog2(SCENE_W)-1:0] START_X  = START, STRIDE_X = PIXEL_STRIDE;
    localparam logic [$clog2(SCENE_H)-1:0] START_Y  = START, STRIDE_Y = PIXEL_STRIDE;
    localparam int IDXW  = (NUM_SPHERES > 1) ? $clog2(NUM_SPHERES) : 1;

    logic [$clog2(SCENE_W)-1:0] render_x;
    logic [$clog2(SCENE_H)-1:0] render_y;
    logic render_start;

    typedef enum logic [4:0] {
        R_IDLE, R_GEN_RAY, R_SPH, R_SPH_W, R_BOUND, R_BOUND_W, R_INVX, R_INVX_W, R_INVY, R_INVY_W, R_INVZ_W, R_SH_A, R_SH_B, R_SH_DONE, R_BOX, R_BOX_W, R_PLANE, R_PLANE_W, R_PLANE_P, R_PLANE_A,
        R_DECIDE, R_LIGHT, R_SHADE, R_NEXT
    } rstate_t;
    rstate_t rstate;

    // ---------------- camera ray ----------------
    fixed_t ray_ox, ray_oy, ray_oz, ray_dx, ray_dy, ray_dz;
    logic   ray_valid;

    ray_generator #(.SCREEN_W(SCENE_W), .SCREEN_H(SCENE_H)) u_raygen (
        .clk, .rst_n, .en(render_start),
        .px(render_x), .py(render_y),
        .cam_x(cam_x), .cam_y(scene_pkg::CAM_Y), .cam_z(cam_z),
        .tan_half_fov(scene_pkg::TAN_HALF_FOV), .aspect_ratio(scene_pkg::ASPECT),
        .origin_x(ray_ox), .origin_y(ray_oy), .origin_z(ray_oz),
        .dir_x(ray_dx), .dir_y(ray_dy), .dir_z(ray_dz),
        .valid(ray_valid)
    );

    // ---------------- walker + camera state (once per frame) ----------------
    // Updated one cycle AFTER frame_done, when the engine is between pixels, so nothing changes mid-ray.
    // frame_done therefore still shows the state that was used for the frame that just finished (the
    // testbench relies on this).
    //   button pressed : step one WALK_STEP that way (clamped), face that way, advance the walk phase
    //   none, auto_walk: keep walking, turning round at +-WALK_X_MAX
    //   none           : stand still (IDLE_PHASE)
    fixed_t fig_x, fig_z, cam_x, cam_z;
    logic [4:0] phase;
    logic face_neg;                                   // 1 = facing / walking toward -x
    logic pend_l, pend_r, pend_n, pend_f;             // sticky: button seen since the last frame_done

    fixed_t step_x, step_z, tgt_cx, tgt_cz;
    logic   any_btn, go_l, go_r, go_n, go_f;
    assign go_l = pend_l && !pend_r;   assign go_r = pend_r && !pend_l;
    assign go_n = pend_n && !pend_f;   assign go_f = pend_f && !pend_n;
    assign any_btn = go_l | go_r | go_n | go_f;
    assign step_x = go_l ? -scene_pkg::WALK_STEP : go_r ? scene_pkg::WALK_STEP : '0;
    assign step_z = go_n ? -scene_pkg::WALK_STEP : go_f ? scene_pkg::WALK_STEP : '0;
    assign tgt_cx = cam_follow ? fig_x : '0;
    assign tgt_cz = (cam_follow ? fig_z : '0) + scene_pkg::CAM_Z;

    fixed_t auto_nx;
    assign auto_nx = face_neg ? fig_x - scene_pkg::WALK_STEP : fig_x + scene_pkg::WALK_STEP;
    logic [4:0] phase_next;
    assign phase_next = (phase == 5'(scene_pkg::NUM_PHASES - 1) || phase == 5'(scene_pkg::IDLE_PHASE)) ? 5'd0 : phase + 5'd1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fig_x <= scene_pkg::START_X;  fig_z <= scene_pkg::START_Z;
            phase <= 5'(scene_pkg::IDLE_PHASE);  face_neg <= 1'b0;
            cam_x <= '0;  cam_z <= scene_pkg::CAM_Z;
            pend_l <= 1'b0; pend_r <= 1'b0; pend_n <= 1'b0; pend_f <= 1'b0;
        end else begin
            if (ctrl_left)  pend_l <= 1'b1;
            if (ctrl_right) pend_r <= 1'b1;
            if (ctrl_near)  pend_n <= 1'b1;
            if (ctrl_far)   pend_f <= 1'b1;
            if (ANIMATE && frame_done) begin
                pend_l <= ctrl_left; pend_r <= ctrl_right; pend_n <= ctrl_near; pend_f <= ctrl_far;
                // camera: smooth follow (arithmetic shift, so it settles within a few LSBs of the target)
                cam_x <= cam_x + ((tgt_cx - cam_x) >>> scene_pkg::CAM_SHIFT);
                cam_z <= cam_z + ((tgt_cz - cam_z) >>> scene_pkg::CAM_SHIFT);
                if (any_btn) begin
                    phase <= phase_next;
                    if (go_l) face_neg <= 1'b1;
                    if (go_r) face_neg <= 1'b0;
                    if (go_l || go_r) begin
                        if (fig_x + step_x <= scene_pkg::WALK_X_LIM && fig_x + step_x >= -scene_pkg::WALK_X_LIM) fig_x <= fig_x + step_x;
                    end
                    if (go_n || go_f) begin
                        if (fig_z + step_z <= scene_pkg::Z_MAX && fig_z + step_z >= scene_pkg::Z_MIN) fig_z <= fig_z + step_z;
                    end
                end else if (auto_walk) begin
                    phase <= phase_next;
                    if (!face_neg && auto_nx > scene_pkg::WALK_X_MAX)       face_neg <= 1'b1;   // turn round (no step this frame)
                    else if (face_neg && auto_nx < -scene_pkg::WALK_X_MAX)  face_neg <= 1'b0;
                    else fig_x <= auto_nx;
                end else
                    phase <= 5'(scene_pkg::IDLE_PHASE);
            end
        end
    end

    // ---------------- directional light: fixed (entry 0) or orbiting ----------------
    localparam int LIGHT_STEPS = scene_pkg::LIGHT_ORBIT_STEPS;
    logic [6:0] light_idx;
    fixed_t light_x, light_y, light_z;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) light_idx <= '0;
        else if (ORBIT_LIGHT && frame_done)
            light_idx <= (light_idx == 7'(LIGHT_STEPS - 1)) ? 7'd0 : light_idx + 7'd1;
    end
    light_rom u_light (.idx(light_idx), .lx(light_x), .ly(light_y), .lz(light_z));

    // ---------------- shadow ray ----------------
    // After a surface point is found and its light vector computed, a second ray runs from the point (pushed
    // SHADOW_EPS out along the normal) to the light: D = (Lpos - origin) / 2^SHADOW_SHIFT, so the light sits at
    // t = 2^SHADOW_SHIFT and any hit with 0 < t < that blocks it.  The same sphere / bounding-sphere / box units are reused with the ray inputs
    // switched over (shadow_mode).  A shadowed point gets AMBIENT light only.
    logic   shadow_mode, occluded;
    fixed_t sh_ox, sh_oy, sh_oz, sh_dx, sh_dy, sh_dz;
    fixed_t sx_ox, sx_oy, sx_oz, sx_dx, sx_dy, sx_dz;
    assign sx_ox = shadow_mode ? sh_ox : ray_ox;  assign sx_dx = shadow_mode ? sh_dx : ray_dx;
    assign sx_oy = shadow_mode ? sh_oy : ray_oy;  assign sx_dy = shadow_mode ? sh_dy : ray_dy;
    assign sx_oz = shadow_mode ? sh_oz : ray_oz;  assign sx_dz = shadow_mode ? sh_dz : ray_dz;

    function automatic fixed_t scl(input fixed_t a, input fixed_t b);      // Q12.20 multiply (small operands)
        logic signed [63:0] pr;
        begin pr = 64'(a) * 64'(b); scl = fixed_t'(pr >>> FRAC_BITS); end
    endfunction

    // 1/d from the divider.  |d| < 1/1024 (ray parallel to the slab): the quotient would not fit Q12.20, so
    // saturate instead -- the box unit's saturating multiply then gives the right "parallel" answer.
    function automatic fixed_t inv_fix(input fixed_t q, input fixed_t d);
        begin
            if (d > -32'sd1024 && d < 32'sd1024) inv_fix = (d < 0) ? 32'sh80000001 : 32'sh7FFFFFFF;
            else inv_fix = q;
        end
    endfunction

    // ---------------- sphere loop ----------------
    logic [IDXW-1:0] sph_idx;
    fixed_t rom_cx, rom_cy, rom_cz, rom_r, rom_inv_r;
    logic [7:0] rom_cr, rom_cg, rom_cb;
    scene_rom u_scene (.idx(sph_idx), .cx(rom_cx), .cy(rom_cy), .cz(rom_cz), .r(rom_r), .inv_r(rom_inv_r),
                       .cr(rom_cr), .cg(rom_cg), .cb(rom_cb));

    // in_bound = the bounding sphere round the whole figure is being tested instead of a world sphere
    logic in_bound;
    fixed_t eff_cx, eff_cy, eff_cz, eff_r, eff_inv_r;
    assign eff_cx    = in_bound ? fig_x                  : rom_cx;
    assign eff_cy    = in_bound ? scene_pkg::BOUND_Y     : rom_cy;
    assign eff_cz    = in_bound ? fig_z                  : rom_cz;
    assign eff_r     = in_bound ? scene_pkg::BOUND_R     : rom_r;
    assign eff_inv_r = in_bound ? scene_pkg::BOUND_INV_R : rom_inv_r;

    logic   isect_start, isect_hit, isect_done;
    fixed_t isect_t, hitx, hity, hitz, nx, ny, nz;
    sphere_intersection u_isect (
        .clk, .rst_n, .start(isect_start),
        .ox(sx_ox), .oy(sx_oy), .oz(sx_oz),
        .dx(sx_dx), .dy(sx_dy), .dz(sx_dz),
        .cx(eff_cx), .cy(eff_cy), .cz(eff_cz),
        .radius(eff_r), .inv_radius(eff_inv_r),
        .hit(isect_hit), .t_hit(isect_t),
        .hit_x(hitx), .hit_y(hity), .hit_z(hitz),
        .normal_x(nx), .normal_y(ny), .normal_z(nz),
        .done(isect_done)
    );

    // ---------------- figure boxes ----------------
    // pose_rom gives each box's offset for the current walk phase; the walker x is added (mirrored when
    // facing -x).  inv_dx/inv_dy (1/ray direction) are computed once per pixel, only when the ray
    // touches the bounding sphere; the ray's z component is always 1, so 1/dz = 1.
    logic [4:0] box_idx;
    fixed_t pose_dx, pose_dy, pose_dz, box_hx, box_hy, box_hz, box_cx, box_cz;
    logic [7:0] box_cr, box_cg, box_cb;
    pose_rom u_pose (.phase(phase), .part(box_idx), .dx(pose_dx), .dy(pose_dy), .dz(pose_dz));
    box_rom  u_boxrom (.part(box_idx), .hx(box_hx), .hy(box_hy), .hz(box_hz), .cr(box_cr), .cg(box_cg), .cb(box_cb));
    assign box_cx = face_neg ? fig_x - pose_dx : fig_x + pose_dx;
    assign box_cz = fig_z + pose_dz;

    fixed_t inv_dx, inv_dy, inv_dz;
    logic   box_start, box_hit, box_done;
    fixed_t box_t, box_hx_p, box_hy_p, box_hz_p, box_nx, box_ny, box_nz;
    box_intersection u_box (
        .clk, .rst_n, .start(box_start),
        .ox(sx_ox), .oy(sx_oy), .oz(sx_oz), .dx(sx_dx), .dy(sx_dy), .dz(sx_dz),
        .inv_dx(inv_dx), .inv_dy(inv_dy), .inv_dz(inv_dz),
        .cx(box_cx), .cy(pose_dy), .cz(box_cz), .hx(box_hx), .hy(box_hy), .hz(box_hz),
        .hit(box_hit), .t_hit(box_t), .hit_x(box_hx_p), .hit_y(box_hy_p), .hit_z(box_hz_p),
        .normal_x(box_nx), .normal_y(box_ny), .normal_z(box_nz), .done(box_done)
    );

    // ---------------- closest-hit record ----------------
    logic   best_valid, fog;
    fixed_t best_t, best_px, best_py, best_pz, best_nx, best_ny, best_nz;
    logic [7:0] best_cr, best_cg, best_cb;

    // ---------------- ground plane ----------------
    // t = (GROUND_Y - Oy) / Dy = (Oy - GROUND_Y) / (-Dy); only for rays heading downwards (Dy < 0).
    fixed_t plane_num, plane_den, plane_t;
    assign plane_num = ray_oy - scene_pkg::GROUND_Y;
    assign plane_den = -ray_dy;

    logic   div_start, div_done, div_dz;
    fixed_t div_result;
    logic [1:0] div_mode;                                      // 0 = ground plane, 1 = 1/Dx, 2 = 1/Dy, 3 = 1/Dz (shadow ray only)
    fixed_t div_a, div_b;
    assign div_a = (div_mode == 2'd0) ? plane_num : fixed_pkg::FIXED_ONE;
    assign div_b = (div_mode == 2'd0) ? plane_den : (div_mode == 2'd1) ? sx_dx : (div_mode == 2'd2) ? sx_dy : sx_dz;
    fixed_div u_div (.clk, .rst_n, .start(div_start), .a(div_a), .b(div_b),
                     .result(div_result), .done(div_done), .div_by_zero(div_dz));

    logic   pscl_en, pscl_valid;  fixed_t pscl_s, pscl_rx, pscl_ry, pscl_rz;
    vector_scale u_pscl (.clk, .rst_n, .en(pscl_en), .vx(ray_dx), .vy(ray_dy), .vz(ray_dz), .s(pscl_s),
                         .rx(pscl_rx), .ry(pscl_ry), .rz(pscl_rz), .valid(pscl_valid));

    logic   padd_en, padd_valid;  fixed_t padd_bx, padd_by, padd_bz, padd_rx, padd_ry, padd_rz;
    vector_add u_padd (.clk, .rst_n, .en(padd_en),
                       .ax(ray_ox), .ay(ray_oy), .az(ray_oz), .bx(padd_bx), .by(padd_by), .bz(padd_bz),
                       .rx(padd_rx), .ry(padd_ry), .rz(padd_rz), .valid(padd_valid));

    // checker tile = parity of floor(x) + floor(z): bit FRAC_BITS is the integer LSB (two's complement)
    // (shifted by CHECK_OFFSET so tile edges do not coincide with exact pixel-centre rays)
    fixed_t chk_x, chk_z;
    logic tile;
    assign chk_x = padd_rx + scene_pkg::CHECK_OFFSET;
    assign chk_z = padd_rz + scene_pkg::CHECK_OFFSET;
    assign tile  = chk_x[FRAC_BITS] ^ chk_z[FRAC_BITS];

    // ---------------- sky gradient (same integer arithmetic as the golden model) ----------------
    function automatic logic [7:0] sky_ch(input logic [7:0] top, input logic [7:0] hor, input int row);
        int diff, prod;
        begin
            if (row >= scene_pkg::HORIZON_ROW) sky_ch = hor;
            else begin
                diff = int'(hor) - int'(top);
                prod = diff * row * scene_pkg::SKY_K;
                sky_ch = 8'(int'(top) + (prod >>> 16));
            end
        end
    endfunction

    logic [23:0] sky_rgb;
    assign sky_rgb = {sky_ch(scene_pkg::SKY_TOP_R, scene_pkg::SKY_HOR_R, int'(render_y)),
                      sky_ch(scene_pkg::SKY_TOP_G, scene_pkg::SKY_HOR_G, int'(render_y)),
                      sky_ch(scene_pkg::SKY_TOP_B, scene_pkg::SKY_HOR_B, int'(render_y))};
    localparam logic [23:0] HORIZON_RGB = {scene_pkg::SKY_HOR_R, scene_pkg::SKY_HOR_G, scene_pkg::SKY_HOR_B};

    // ---------------- point light + lambert ----------------
    // point light position: fixed at LPOS, or (ORBIT_LIGHT) circling the walker
    fixed_t orb_x, orb_y, orb_z, lp_x, lp_y, lp_z;
    light_orbit_rom u_lorb (.idx(light_idx[$clog2(LIGHT_STEPS)-1:0]), .ox(orb_x), .oy(orb_y), .oz(orb_z));
    assign lp_x = ORBIT_LIGHT ? fig_x + orb_x : scene_pkg::LPOS_X;
    assign lp_y = ORBIT_LIGHT ? orb_y         : scene_pkg::LPOS_Y;
    assign lp_z = ORBIT_LIGHT ? fig_z + orb_z : scene_pkg::LPOS_Z;
    logic   pl_start, pl_valid;
    fixed_t pl_x, pl_y, pl_z;
    point_light u_plight (
        .clk, .rst_n, .start(pl_start),
        .px(best_px), .py(best_py), .pz(best_pz),
        .lpx(lp_x), .lpy(lp_y), .lpz(lp_z),
        .ux(pl_x), .uy(pl_y), .uz(pl_z), .valid(pl_valid)
    );
    fixed_t lam_lx, lam_ly, lam_lz;
    // shadowed: zero light vector -> N.L = 0 -> brightness = AMBIENT
    assign lam_lx = POINT_LIGHT ? (occluded ? '0 : pl_x) : light_x;
    assign lam_ly = POINT_LIGHT ? (occluded ? '0 : pl_y) : light_y;
    assign lam_lz = POINT_LIGHT ? (occluded ? '0 : pl_z) : light_z;

    logic [7:0] shade_r, shade_g, shade_b;
    logic       shade_en, shade_valid;
    lambert #(.AMBIENT(scene_pkg::AMBIENT)) u_lambert (
        .clk, .rst_n, .en(shade_en),
        .nx(best_nx), .ny(best_ny), .nz(best_nz),
        .lx(lam_lx), .ly(lam_ly), .lz(lam_lz),
        .obj_r(best_cr), .obj_g(best_cg), .obj_b(best_cb),
        .out_r(shade_r), .out_g(shade_g), .out_b(shade_b),
        .valid(shade_valid)
    );

    wire [$clog2(SCENE_W*SCENE_H)-1:0] cur_addr = (render_y * SCENE_W) + render_x;

    // ---------------- sequencer ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate       <= R_IDLE;
            render_x     <= START_X;
            render_y     <= START_Y;
            render_start <= 1'b0;
            isect_start  <= 1'b0;
            div_start    <= 1'b0;
            pscl_en      <= 1'b0;
            padd_en      <= 1'b0;
            shade_en     <= 1'b0;
            pl_start     <= 1'b0;
            fb_we        <= 1'b0;
            fb_waddr     <= '0;
            fb_wdata     <= '0;
            frame_done   <= 1'b0;
            sph_idx      <= '0;
            in_bound     <= 1'b0;
            box_idx      <= '0;
            box_start    <= 1'b0;
            div_mode     <= '0;
            inv_dx <= '0; inv_dy <= '0; inv_dz <= fixed_pkg::FIXED_ONE;
            shadow_mode <= 1'b0; occluded <= 1'b0;
            sh_ox <= '0; sh_oy <= '0; sh_oz <= '0; sh_dx <= '0; sh_dy <= '0; sh_dz <= '0;
            best_valid   <= 1'b0;
            fog          <= 1'b0;
            best_t <= '0; best_px <= '0; best_py <= '0; best_pz <= '0;
            best_nx <= '0; best_ny <= '0; best_nz <= '0;
            best_cr <= '0; best_cg <= '0; best_cb <= '0;
            plane_t <= '0; pscl_s <= '0; padd_bx <= '0; padd_by <= '0; padd_bz <= '0;
        end else begin
            render_start <= 1'b0;
            isect_start  <= 1'b0;
            div_start    <= 1'b0;
            pscl_en      <= 1'b0;
            padd_en      <= 1'b0;
            shade_en     <= 1'b0;
            pl_start     <= 1'b0;
            box_start    <= 1'b0;
            fb_we        <= 1'b0;
            frame_done   <= 1'b0;

            case (rstate)
                R_IDLE: begin
                    render_start <= 1'b1;
                    rstate       <= R_GEN_RAY;
                end

                R_GEN_RAY: if (ray_valid) begin
                    sph_idx    <= '0;
                    best_valid <= 1'b0;
                    fog        <= 1'b0;
                    occluded   <= 1'b0;
                    rstate     <= R_SPH;
                end

                // ---- spheres: one at a time through the shared intersection unit ----
                R_SPH: begin
                    isect_start <= 1'b1;
                    rstate      <= R_SPH_W;
                end

                R_SPH_W: if (isect_done) begin
                    if (shadow_mode && isect_hit && isect_t < scene_pkg::SHADOW_T_LIGHT) begin
                        occluded <= 1'b1;                              // a world sphere blocks the light
                        rstate   <= R_SH_DONE;
                    end else begin
                    if (!shadow_mode && isect_hit && (!best_valid || isect_t < best_t)) begin
                        best_valid <= 1'b1;
                        best_t  <= isect_t;
                        best_px <= hitx; best_py <= hity; best_pz <= hitz;
                        best_nx <= nx;   best_ny <= ny;   best_nz <= nz;
                        best_cr <= rom_cr; best_cg <= rom_cg; best_cb <= rom_cb;
                    end
                    if (int'(sph_idx) == NUM_SPHERES - 1) begin
                        in_bound <= 1'b1;                              // world spheres done: is the figure on this ray at all?
                        rstate   <= R_BOUND;
                    end
                    else begin
                        sph_idx <= sph_idx + 1'b1;
                        rstate  <= R_SPH;
                    end
                    end
                end

                // ---- bounding sphere: a miss skips every figure sphere ----
                R_BOUND: begin
                    isect_start <= 1'b1;
                    rstate      <= R_BOUND_W;
                end

                R_BOUND_W: if (isect_done) begin
                    in_bound <= 1'b0;
                    if (isect_hit) begin
                        div_mode  <= 2'd1;                             // figure is on this ray: need 1/Dx and 1/Dy
                        div_start <= 1'b1;
                        rstate    <= R_INVX_W;
                    end else rstate <= shadow_mode ? R_SH_DONE : R_PLANE;     // figure not on this ray
                end

                R_INVX_W: if (div_done) begin
                    inv_dx    <= inv_fix(div_result, sx_dx);
                    div_mode  <= 2'd2;
                    div_start <= 1'b1;
                    rstate    <= R_INVY_W;
                end

                R_INVY_W: if (div_done) begin
                    inv_dy    <= inv_fix(div_result, sx_dy);
                    if (shadow_mode) begin                             // shadow rays have a general direction: also 1/Dz
                        div_mode  <= 2'd3;
                        div_start <= 1'b1;
                        rstate    <= R_INVZ_W;
                    end else begin
                        div_mode  <= 2'd0;
                        inv_dz    <= fixed_pkg::FIXED_ONE;             // camera rays have Dz = 1
                        box_idx   <= '0;
                        rstate    <= R_BOX;
                    end
                end

                R_INVZ_W: if (div_done) begin
                    inv_dz    <= inv_fix(div_result, sx_dz);
                    div_mode  <= 2'd0;
                    box_idx   <= '0;
                    rstate    <= R_BOX;
                end

                // ---- the figure's boxes, one at a time ----
                R_BOX: begin
                    box_start <= 1'b1;
                    rstate    <= R_BOX_W;
                end

                R_BOX_W: if (box_done) begin
                    if (shadow_mode && box_hit && box_t < scene_pkg::SHADOW_T_LIGHT) begin
                        occluded <= 1'b1;                              // a figure box blocks the light
                        rstate   <= R_SH_DONE;
                    end else begin
                    if (!shadow_mode && box_hit && (!best_valid || box_t < best_t)) begin
                        best_valid <= 1'b1;
                        best_t  <= box_t;
                        best_px <= box_hx_p; best_py <= box_hy_p; best_pz <= box_hz_p;
                        best_nx <= box_nx;   best_ny <= box_ny;   best_nz <= box_nz;
                        best_cr <= box_cr; best_cg <= box_cg; best_cb <= box_cb;
                    end
                    if (int'(box_idx) == scene_pkg::NUM_PARTS - 1) rstate <= shadow_mode ? R_SH_DONE : R_PLANE;
                    else begin
                        box_idx <= box_idx + 5'd1;
                        rstate  <= R_BOX;
                    end
                    end
                end

                // ---- ground plane ----
                R_PLANE: begin
                    if (ray_dy < 0) begin
                        div_start <= 1'b1;
                        rstate    <= R_PLANE_W;
                    end else
                        rstate <= R_DECIDE;
                end

                R_PLANE_W: if (div_done) begin
                    plane_t <= div_result;
                    if (best_valid && best_t <= div_result)
                        rstate <= R_DECIDE;                           // a sphere is in front of the ground
                    else if (div_result >= scene_pkg::FOG_T) begin
                        best_valid <= 1'b0;
                        fog        <= 1'b1;                           // far ground: horizon colour
                        rstate     <= R_DECIDE;
                    end else begin
                        pscl_s  <= div_result;                        // P = O + t*D
                        pscl_en <= 1'b1;
                        rstate  <= R_PLANE_P;
                    end
                end

                R_PLANE_P: if (pscl_valid) begin
                    padd_bx <= pscl_rx; padd_by <= pscl_ry; padd_bz <= pscl_rz;
                    padd_en <= 1'b1;
                    rstate  <= R_PLANE_A;
                end

                R_PLANE_A: if (padd_valid) begin
                    best_valid <= 1'b1;
                    best_t  <= plane_t;
                    best_px <= padd_rx; best_py <= padd_ry; best_pz <= padd_rz;
                    best_nx <= '0; best_ny <= FIXED_ONE; best_nz <= '0;
                    if (!tile) begin best_cr <= scene_pkg::GROUND_A_R; best_cg <= scene_pkg::GROUND_A_G; best_cb <= scene_pkg::GROUND_A_B; end
                    else       begin best_cr <= scene_pkg::GROUND_B_R; best_cg <= scene_pkg::GROUND_B_G; best_cb <= scene_pkg::GROUND_B_B; end
                    rstate  <= R_DECIDE;
                end

                // ---- shade the closest hit, or draw the sky ----
                R_DECIDE: begin
                    if (best_valid) begin
                        if (POINT_LIGHT) begin
                            pl_start <= 1'b1;
                            rstate   <= R_LIGHT;
                        end else begin
                            shade_en <= 1'b1;
                            rstate   <= R_SHADE;
                        end
                    end else begin
                        fb_waddr <= cur_addr;
                        fb_wdata <= fog ? HORIZON_RGB : sky_rgb;
                        fb_we    <= 1'b1;
                        rstate   <= R_NEXT;
                    end
                end

                R_LIGHT: if (pl_valid) begin
                    if (SHADOWS && best_t < scene_pkg::SHADOW_MAX_T) begin
                        shadow_mode <= 1'b1;                           // cast the shadow ray
                        occluded    <= 1'b0;
                        rstate      <= R_SH_A;
                    end else begin
                        shade_en <= 1'b1;
                        rstate   <= R_SHADE;
                    end
                end

                R_SH_A: begin                                          // ray origin: surface point pushed out along the normal
                    sh_ox  <= best_px + scl(best_nx, scene_pkg::SHADOW_EPS);
                    sh_oy  <= best_py + scl(best_ny, scene_pkg::SHADOW_EPS);
                    sh_oz  <= best_pz + scl(best_nz, scene_pkg::SHADOW_EPS);
                    rstate <= R_SH_B;
                end

                R_SH_B: begin                                          // direction to the light (light at t = 1)
                    sh_dx   <= (lp_x - sh_ox) >>> scene_pkg::SHADOW_SHIFT;
                    sh_dy   <= (lp_y - sh_oy) >>> scene_pkg::SHADOW_SHIFT;
                    sh_dz   <= (lp_z - sh_oz) >>> scene_pkg::SHADOW_SHIFT;
                    sph_idx <= '0;
                    rstate  <= R_SPH;
                end

                R_SH_DONE: begin
                    shadow_mode <= 1'b0;
                    shade_en    <= 1'b1;
                    rstate      <= R_SHADE;
                end

                R_SHADE: if (shade_valid) begin
                    fb_waddr <= cur_addr;
                    fb_wdata <= {shade_r, shade_g, shade_b};
                    fb_we    <= 1'b1;
                    rstate   <= R_NEXT;
                end

                R_NEXT: begin
                    if (int'(render_x) + PIXEL_STRIDE >= SCENE_W) begin
                        render_x <= START_X;
                        if (int'(render_y) + PIXEL_STRIDE >= SCENE_H) begin
                            render_y   <= START_Y;
                            frame_done <= 1'b1;
                        end else
                            render_y <= render_y + STRIDE_Y;
                    end else begin
                        render_x <= render_x + STRIDE_X;
                    end
                    rstate <= R_IDLE;
                end

                default: rstate <= R_IDLE;
            endcase
        end
    end
endmodule
