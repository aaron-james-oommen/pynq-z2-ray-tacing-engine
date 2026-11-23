// =============================================================
// video_out.sv - framebuffer -> 640x480 TMDS (DVI) output
//
// Timing alignment (this was a bug in the first version):
//   cycle N   : timing_generator shows pixel (x,y); we present fb_raddr
//   cycle N+1 : framebuffer's registered rdata is the colour of pixel (x,y)
//               -> de / hsync / vsync must be delayed one cycle to match (de_d, ...)
//   cycle N+2 : tmds_encoder's registered output is the code for pixel (x,y)
// Without the delay the sync/blanking edges land one pixel early relative to the data.
//
// The 160x120 image is shown 4x enlarged (each framebuffer pixel = 4x4 screen pixels).
// =============================================================
module video_out
    import fixed_pkg::*, scene_pkg::*;
#(
    // 1 = ignore the framebuffer and send 8 vertical colour bars (hardware bring-up step:
    //     proves clocking + TMDS + serializers + monitor before the ray tracer is involved)
    parameter bit TEST_PATTERN = 1'b0
) (
    input  logic pixel_clk,
    input  logic clk_serial,
    input  logic rst_n,

    // framebuffer read port (1-cycle registered read)
    output logic [$clog2(SCENE_W*SCENE_H)-1:0] fb_raddr,
    input  logic [23:0]                        fb_rdata,

    output logic       hdmi_out_clk_p, hdmi_out_clk_n,
    output logic [2:0] hdmi_out_data_p, hdmi_out_data_n
);
    logic rst;
    assign rst = ~rst_n;

    logic hsync, vsync, video_on, frame_start;
    logic [9:0] pixel_x, pixel_y;

    timing_generator u_timing (
        .pixel_clk, .rst_n,
        .hsync, .vsync, .video_on, .pixel_x, .pixel_y, .frame_start
    );

    // 4x upscale; clamp to 0 outside the visible area so the address never leaves the array
    assign fb_raddr = video_on ? ($bits(fb_raddr)'(pixel_y[9:2]) * SCENE_W + pixel_x[9:2]) : '0;

    // delay control signals to line up with the registered framebuffer read
    logic de_d, hs_d, vs_d;
    always_ff @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin de_d <= 1'b0; hs_d <= 1'b1; vs_d <= 1'b1; end
        else begin de_d <= video_on; hs_d <= hsync; vs_d <= vsync; end
    end

    // colour bars: white, yellow, cyan, green, magenta, red, blue, black (80 px each)
    logic [9:0] x_d;
    always_ff @(posedge pixel_clk or negedge rst_n)
        if (!rst_n) x_d <= '0; else x_d <= pixel_x;
    logic [2:0] bar;
    assign bar = x_d[9:7] > 3'd7 ? 3'd7 : (x_d / 80);     // 0..7 (x_d < 640 when visible)
    logic [23:0] bar_rgb;
    always_comb case (bar)
        3'd0: bar_rgb = 24'hFFFFFF;  3'd1: bar_rgb = 24'hFFFF00;
        3'd2: bar_rgb = 24'h00FFFF;  3'd3: bar_rgb = 24'h00FF00;
        3'd4: bar_rgb = 24'hFF00FF;  3'd5: bar_rgb = 24'hFF0000;
        3'd6: bar_rgb = 24'h0000FF;  default: bar_rgb = 24'h000000;
    endcase
    logic [23:0] pix;
    assign pix = TEST_PATTERN ? bar_rgb : fb_rdata;

    logic [9:0] tmds_r, tmds_g, tmds_b;
    tmds_encoder u_enc_r (.clk(pixel_clk), .rst_n, .data(pix[23:16]), .ctrl(2'b00),        .de(de_d), .tmds(tmds_r));
    tmds_encoder u_enc_g (.clk(pixel_clk), .rst_n, .data(pix[15:8]),  .ctrl(2'b00),        .de(de_d), .tmds(tmds_g));
    tmds_encoder u_enc_b (.clk(pixel_clk), .rst_n, .data(pix[7:0]),   .ctrl({vs_d, hs_d}), .de(de_d), .tmds(tmds_b));

    tmds_serializer u_ser_r (.clk_serial, .clk_pixel(pixel_clk), .rst, .tmds_in(tmds_r),
        .tmds_out_p(hdmi_out_data_p[2]), .tmds_out_n(hdmi_out_data_n[2]));
    tmds_serializer u_ser_g (.clk_serial, .clk_pixel(pixel_clk), .rst, .tmds_in(tmds_g),
        .tmds_out_p(hdmi_out_data_p[1]), .tmds_out_n(hdmi_out_data_n[1]));
    tmds_serializer u_ser_b (.clk_serial, .clk_pixel(pixel_clk), .rst, .tmds_in(tmds_b),
        .tmds_out_p(hdmi_out_data_p[0]), .tmds_out_n(hdmi_out_data_n[0]));

    // clock channel: 5 ones + 5 zeros per pixel period -> square wave at the pixel clock
    localparam logic [9:0] TMDS_CLOCK_PATTERN = 10'b0000011111;
    tmds_serializer u_ser_clk (.clk_serial, .clk_pixel(pixel_clk), .rst, .tmds_in(TMDS_CLOCK_PATTERN),
        .tmds_out_p(hdmi_out_clk_p), .tmds_out_n(hdmi_out_clk_n));
endmodule
