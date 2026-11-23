// =============================================================
// timing_generator.sv - 640x480 @ 60Hz video timing
// Same timing standard used for VGA is reused here: HDMI/DVI
// video timing uses the exact same horizontal/vertical blanking
// structure as VGA (HDMI is TMDS-encoded DVI underneath, and DVI
// timing is VESA VGA timing). The difference from a VGA design
// is entirely in how hsync/vsync/data get transmitted (encoded
// serial TMDS here instead of analog voltages) -- not in when
// they happen.
//
// Pixel clock required: 25.175 MHz (25 MHz is close enough).
// =============================================================
module timing_generator (
    input  logic        pixel_clk,
    input  logic        rst_n,

    output logic        hsync,
    output logic        vsync,
    output logic        video_on,      // a.k.a. "data enable" / DE in HDMI terms
    output logic [9:0]  pixel_x,
    output logic [9:0]  pixel_y,
    output logic        frame_start
);
    localparam int H_VISIBLE    = 640;
    localparam int H_FRONT      = 16;
    localparam int H_SYNC       = 96;
    localparam int H_BACK       = 48;
    localparam int H_TOTAL      = H_VISIBLE + H_FRONT + H_SYNC + H_BACK; // 800

    localparam int V_VISIBLE    = 480;
    localparam int V_FRONT      = 10;
    localparam int V_SYNC       = 2;
    localparam int V_BACK       = 33;
    localparam int V_TOTAL      = V_VISIBLE + V_FRONT + V_SYNC + V_BACK; // 525

    logic [9:0] h_count, v_count;

    always_ff @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_count <= '0;
            v_count <= '0;
        end else begin
            if (h_count == H_TOTAL - 1) begin
                h_count <= '0;
                v_count <= (v_count == V_TOTAL - 1) ? '0 : v_count + 1'b1;
            end else begin
                h_count <= h_count + 1'b1;
            end
        end
    end

    // NOTE: VGA sync polarity is active-low for this timing standard.
    // For HDMI/DVI, sync polarity is carried as explicit control bits
    // inside the TMDS encoding during blanking (see tmds_encoder.sv),
    // so the raw hsync/vsync values generated here are fed directly
    // into the encoder's ctrl input, not onto a physical sync pin.
    assign hsync = ~((h_count >= H_VISIBLE + H_FRONT) &&
                      (h_count <  H_VISIBLE + H_FRONT + H_SYNC));
    assign vsync = ~((v_count >= V_VISIBLE + V_FRONT) &&
                      (v_count <  V_VISIBLE + V_FRONT + V_SYNC));

    assign video_on = (h_count < H_VISIBLE) && (v_count < V_VISIBLE);
    assign pixel_x  = h_count;
    assign pixel_y  = v_count;
    assign frame_start = (h_count == 0) && (v_count == 0);
endmodule
