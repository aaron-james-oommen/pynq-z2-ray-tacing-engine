// =============================================================
// top_hdmi.sv - PYNQ-Z2 HDMI-out top level
//
//   render_engine --(write port)--> framebuffer --(read port)--> video_out --> TMDS pins
//
// The PYNQ-Z2 has no HDMI transmitter chip: the FPGA drives TMDS directly.
// pixel_clk (25 MHz) and clk_serial (125 MHz = 5x) MUST come from one MMCM
// (Vivado Clocking Wizard) so they are phase-locked.
// hdmi_out_hpd is an input from the monitor, currently unused.
// =============================================================
module top_hdmi
    import fixed_pkg::*, scene_pkg::*;
#(
    parameter bit TEST_PATTERN = 1'b0,     // 1 = colour bars instead of the ray-traced image (bring-up)
    parameter bit ANIMATE      = 1'b0,     // 1 = the figure walks (buttons / auto-walk), camera and light can move
    parameter bit ORBIT_LIGHT  = 1'b0,     // 1 = light circles (directional light, or the point light round the walker when POINT_LIGHT=1)
    parameter bit POINT_LIGHT  = 1'b0,     // 1 = point light: highlights follow the objects
    parameter bit SHADOWS      = 1'b0,     // 1 = shadows (needs POINT_LIGHT)
    parameter int PIXEL_STRIDE = 1         // simulation only: render every Nth pixel
) (
    input  logic pixel_clk,      // 25 MHz
    input  logic clk_serial,     // 125 MHz
    input  logic rst_n,

    // walker control (see render_engine.sv)
    input  logic ctrl_left, ctrl_right, ctrl_near, ctrl_far,
    input  logic auto_walk, cam_follow,

    output logic       hdmi_out_clk_p, hdmi_out_clk_n,
    output logic [2:0] hdmi_out_data_p, hdmi_out_data_n,
    input  logic       hdmi_out_hpd
);
    localparam int AW = $clog2(SCENE_W*SCENE_H);

    logic          fb_we;
    logic [AW-1:0] fb_waddr, fb_raddr;
    logic [23:0]   fb_wdata, fb_rdata;
    logic          frame_done;

    framebuffer #(.WIDTH_PX(SCENE_W), .HEIGHT_PX(SCENE_H)) u_fb (
        .clk(pixel_clk),
        .we(fb_we), .waddr(fb_waddr), .wdata(fb_wdata),
        .raddr(fb_raddr), .rdata(fb_rdata)
    );

    render_engine #(.ANIMATE(ANIMATE), .ORBIT_LIGHT(ORBIT_LIGHT), .POINT_LIGHT(POINT_LIGHT), .SHADOWS(SHADOWS), .PIXEL_STRIDE(PIXEL_STRIDE)) u_render (
        .clk(pixel_clk), .rst_n,
        .ctrl_left, .ctrl_right, .ctrl_near, .ctrl_far, .auto_walk, .cam_follow,
        .fb_we, .fb_waddr, .fb_wdata, .frame_done
    );

    video_out #(.TEST_PATTERN(TEST_PATTERN)) u_video (
        .pixel_clk, .clk_serial, .rst_n,
        .fb_raddr, .fb_rdata,
        .hdmi_out_clk_p, .hdmi_out_clk_n, .hdmi_out_data_p, .hdmi_out_data_n
    );
endmodule
