// =============================================================
// pynq_top.sv - board-level top for the PYNQ-Z2 (this is the Vivado "Top module")
//
//   125 MHz sysclk (H16) --> MMCME2_BASE --> 125 MHz (clk_serial) + 25 MHz (pixel_clk)
//   BTN0 = reset (hold to restart the render)          LD0 = MMCM locked
//   BTN1 = walk left   BTN2 = walk right               LD1 = monitor connected (HDMI hot-plug detect)
//   SW0 = 1: BTN1/BTN2 walk toward / away from the camera instead          LD2 = auto-walk on
//   BTN3 = toggle auto-walk (on after reset)           LD3 = camera follow on
//   SW1 = camera follows the walker
//
// MMCM maths: VCO = 125 MHz x 8 = 1000 MHz (legal range 600-1200 MHz, -1 speed grade);
//             CLKOUT0 = 1000/8  = 125 MHz  (5x pixel clock, DDR -> 10 bits per pixel)
//             CLKOUT1 = 1000/40 = 25 MHz   (pixel clock; true VESA is 25.175 MHz, monitors accept 25)
// Both outputs come from the same MMCM, so they are phase-locked, which TMDS needs.
//
// TEST_PATTERN = 1 sends colour bars instead of the ray-traced image (bring-up step B).
// =============================================================
module pynq_top #(
    parameter bit TEST_PATTERN = 1'b0,
    parameter bit ANIMATE      = 1'b1,    // 1 = the figure walks (buttons / auto-walk), 0 = static scene
    parameter bit ORBIT_LIGHT  = 1'b1,    // 1 = the light circles (the point light round the walker when POINT_LIGHT = 1)
    parameter bit POINT_LIGHT  = 1'b1,    // 1 = point light, highlights follow the objects; 0 = directional light
    parameter bit SHADOWS      = 1'b1     // 1 = shadows (needs POINT_LIGHT = 1)
) (
    input  logic       sysclk,              // 125 MHz, pin H16
    input  logic       btn0,                // active high, pin D19 (reset)
    input  logic       btn1, btn2, btn3,    // active high: left, right, auto-walk toggle
    input  logic [1:0] sw,                  // sw[0] = move in depth, sw[1] = camera follow
    output logic [3:0] led,

    output logic       hdmi_out_clk_p, hdmi_out_clk_n,
    output logic [2:0] hdmi_out_data_p, hdmi_out_data_n,
    input  logic       hdmi_out_hpd
);
    logic clkfb, clk125_raw, clk25_raw, locked;
    logic clk_serial, pixel_clk;

    MMCME2_BASE #(
        .CLKIN1_PERIOD    (8.000),
        .DIVCLK_DIVIDE    (1),
        .CLKFBOUT_MULT_F  (8.000),
        .CLKOUT0_DIVIDE_F (8.000),
        .CLKOUT1_DIVIDE   (40)
    ) u_mmcm (
        .CLKIN1   (sysclk),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk125_raw),
        .CLKOUT1  (clk25_raw),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0)
    );

    BUFG u_bufg_ser (.I(clk125_raw), .O(clk_serial));
    BUFG u_bufg_pix (.I(clk25_raw),  .O(pixel_clk));

    // Reset: held while the MMCM is unlocked or BTN0 is pressed; released synchronously to pixel_clk.
    logic [2:0] rst_sync = 3'b000;
    always_ff @(posedge pixel_clk or negedge locked)
        if (!locked) rst_sync <= 3'b000;
        else         rst_sync <= {rst_sync[1:0], ~btn0};
    wire rst_n = rst_sync[2];

    // Inputs: two-flop synchroniser into the pixel clock domain (buttons are slow and the engine samples
    // them once per frame, so no further debouncing is needed); BTN3 toggles auto-walk on its rising edge.
    logic [1:0] b1_s, b2_s, b3_s, sw0_s, sw1_s;
    logic       b3_d, auto_walk;
    always_ff @(posedge pixel_clk) begin
        b1_s <= {b1_s[0], btn1};  b2_s <= {b2_s[0], btn2};  b3_s <= {b3_s[0], btn3};
        sw0_s <= {sw0_s[0], sw[0]};  sw1_s <= {sw1_s[0], sw[1]};
        b3_d <= b3_s[1];
    end
    always_ff @(posedge pixel_clk or negedge rst_n)
        if (!rst_n) auto_walk <= 1'b1;
        else if (b3_s[1] && !b3_d) auto_walk <= ~auto_walk;
    wire depth_mode = sw0_s[1];

    top_hdmi #(.TEST_PATTERN(TEST_PATTERN), .ANIMATE(ANIMATE), .ORBIT_LIGHT(ORBIT_LIGHT), .POINT_LIGHT(POINT_LIGHT), .SHADOWS(SHADOWS)) u_top (
        .pixel_clk, .clk_serial, .rst_n,
        .ctrl_left(b1_s[1] & ~depth_mode), .ctrl_right(b2_s[1] & ~depth_mode),
        .ctrl_near(b1_s[1] & depth_mode),  .ctrl_far(b2_s[1] & depth_mode),
        .auto_walk, .cam_follow(sw1_s[1]),
        .hdmi_out_clk_p, .hdmi_out_clk_n,
        .hdmi_out_data_p, .hdmi_out_data_n,
        .hdmi_out_hpd
    );

    assign led = {sw1_s[1], auto_walk, hdmi_out_hpd, locked};
endmodule
