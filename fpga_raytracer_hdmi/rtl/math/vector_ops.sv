import fixed_pkg::*;

module dot_product (
    input  logic  clk,
    input  logic  rst_n,
    input  logic  en,
    input  fixed_t ax, ay, az,
    input  fixed_t bx, by, bz,
    output fixed_t result,
    output logic  valid
);
    fixed_t px, py, pz;
    logic   vx, vy, vz;

    fixed_mul u_mx (.clk, .rst_n, .en, .a(ax), .b(bx), .result(px), .valid(vx));
    fixed_mul u_my (.clk, .rst_n, .en, .a(ay), .b(by), .result(py), .valid(vy));
    fixed_mul u_mz (.clk, .rst_n, .en, .a(az), .b(bz), .result(pz), .valid(vz));

    fixed_t sum1;
    logic   v1;
    fixed_addsub u_add1 (.clk, .rst_n, .en(vx), .a(px), .b(py), .sub(1'b0), .result(sum1), .valid(v1));

    fixed_t pz_d;
    logic   vz_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pz_d <= '0; vz_d <= 1'b0; end
        else begin pz_d <= pz; vz_d <= vz; end
    end

    fixed_addsub u_add2 (.clk, .rst_n, .en(v1), .a(sum1), .b(pz_d), .sub(1'b0), .result(result), .valid(valid));
endmodule

module vector_sub (
    input  logic  clk, rst_n, en,
    input  fixed_t ax, ay, az,
    input  fixed_t bx, by, bz,
    output fixed_t rx, ry, rz,
    output logic  valid
);
    logic v0, v1;
    fixed_addsub u_x (.clk, .rst_n, .en, .a(ax), .b(bx), .sub(1'b1), .result(rx), .valid(v0));
    fixed_addsub u_y (.clk, .rst_n, .en, .a(ay), .b(by), .sub(1'b1), .result(ry), .valid(v1));
    fixed_addsub u_z (.clk, .rst_n, .en, .a(az), .b(bz), .sub(1'b1), .result(rz), .valid(valid));
endmodule

// ---- Vector add (3 independent lanes, 1 cycle) ----
module vector_add (
    input  logic  clk, rst_n, en,
    input  fixed_t ax, ay, az,
    input  fixed_t bx, by, bz,
    output fixed_t rx, ry, rz,
    output logic  valid
);
    logic v0, v1;
    fixed_addsub u_x (.clk, .rst_n, .en, .a(ax), .b(bx), .sub(1'b0), .result(rx), .valid(v0));
    fixed_addsub u_y (.clk, .rst_n, .en, .a(ay), .b(by), .sub(1'b0), .result(ry), .valid(v1));
    fixed_addsub u_z (.clk, .rst_n, .en, .a(az), .b(bz), .sub(1'b0), .result(rz), .valid(valid));
endmodule

// ---- Vector * scalar (3 parallel multipliers, 2 cycles) ----
module vector_scale (
    input  logic  clk, rst_n, en,
    input  fixed_t vx, vy, vz,
    input  fixed_t s,
    output fixed_t rx, ry, rz,
    output logic  valid
);
    logic v0, v1;
    fixed_mul u_x (.clk, .rst_n, .en, .a(vx), .b(s), .result(rx), .valid(v0));
    fixed_mul u_y (.clk, .rst_n, .en, .a(vy), .b(s), .result(ry), .valid(v1));
    fixed_mul u_z (.clk, .rst_n, .en, .a(vz), .b(s), .result(rz), .valid(valid));
endmodule
