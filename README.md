# FPGA Ray Tracing Engine (PYNQ-Z2)

A hardware ray tracer written in SystemVerilog. The FPGA renders a 3D scene entirely in logic and
drives a monitor over HDMI. The PYNQ-Z2 has no HDMI transmitter chip, so the design generates the
TMDS video signal itself (encoder, 10:1 serializers, differential outputs).

The scene is a checkerboard ground plane under a sky gradient, two spheres, and a walking figure made
of boxes. A point light circles the figure and casts live shadows. Buttons and switches on the board
walk the figure around and move the camera.


## Features

- Q12.20 signed fixed-point arithmetic (32-bit, 64-bit intermediates), no floating point
- Ray generation from a pinhole camera, one ray per pixel
- Ray–sphere intersection (quadratic, with square root and divide units)
- Ray–box intersection (slab method, no divide or square root per box)
- Closest-hit selection, checkerboard ground plane, sky gradient, distance fog
- Lambertian shading with an ambient floor; directional light or point light
- Shadow rays toward the point light (spheres and figure boxes cast shadows)
- Walking figure of 16 boxes with a 16-frame walk cycle and a standing pose
- Bounding sphere around the figure, so rays that miss it skip all 16 boxes
- Smooth following camera
- HDMI output: 640×480 @ 60 Hz timing, 160×120 framebuffer shown 4× enlarged

## How it works

```
 pixel (x, y)
     |
 ray_generator --> sphere units --> bounding sphere --> box unit --> ground plane
                                                                          |
                          closest hit (distance, normal, colour) <---------
                                      |
                       point_light --> shadow ray (same units) --> lambert
                                                                      |
                              framebuffer (BRAM) --> video_out --> TMDS --> HDMI
```

`render_engine.sv` is the state machine that walks every pixel through this pipeline using shared
intersection units (one pixel at a time). Video runs from a separate read port, so the picture
stays stable while the next frame renders.

Clocks: a 125 MHz board clock goes into an MMCM that produces a 25 MHz pixel clock and a
125 MHz serial clock (5× pixel, DDR gives the 10× bit rate TMDS needs). Both must come from the same
MMCM so they stay phase-locked.

## Controls (PYNQ-Z2)

| Input | Action |
|---|---|
| BTN0 | reset |
| BTN1 / BTN2 | walk left / right (with SW0 up: toward / away from the camera) |
| BTN3 | toggle auto-walk (on after reset; a held button overrides it) |
| SW0 | 0 = left/right, 1 = toward/away |
| SW1 | camera follows the walker |


## Repository layout

```
rtl/
  pynq_top.sv            board top level: MMCM, buttons, switches, LEDs
  top_hdmi.sv            render engine + framebuffer + video output
  render_engine.sv       per-pixel state machine, walker/camera/light state, shadows
  video_out.sv           framebuffer read, 4x upscale, TMDS encode/serialise
  camera/                ray_generator
  geometry/              sphere_intersection, box_intersection, scene/box/pose ROMs
  lighting/              lambert, point_light, light ROMs
  math/                  fixed-point add/sub, multiply, divide, sqrt, vector ops
  memory/                framebuffer (block RAM)
  video/                 timing_generator, tmds_encoder, tmds_serializer
  utils/                 fixed_pkg, scene_pkg (generated)
constraints/pynq_z2_hdmi.xdc   pin assignments (HDMI TX, clock, buttons, switches, LEDs)
```

## Build for the PYNQ-Z2

1. Create a Vivado project for part `xc7z020clg400-1` and add everything under `rtl/`
   (SystemVerilog) plus `constraints/pynq_z2_hdmi.xdc`.
2. Set `pynq_top` as the top module.
3. Run synthesis, implementation and generate the bitstream.
4. Connect the board's HDMI **OUT** port to a monitor and program the board.

Design parameters in `pynq_top`: `ANIMATE`, `ORBIT_LIGHT`, `POINT_LIGHT`, `SHADOWS`, `TEST_PATTERN`.
Shadows need `POINT_LIGHT = 1`.

## Known limitations

- **Speed:** pixels are rendered one at a time. From simulation I estimate about 3 frames per second
  at 25 MHz with shadows on (about 4 without). This is an extrapolation, not a measured full frame.
- **Shadows:** only points within about 10 units of ray depth from the camera are shadow-tested.
  Longer shadow rays would overflow the number format in the sphere unit.
- **Figure:** boxes can't tilt, so limbs swing as stepped blocks. The walker keeps facing left or
  right when it moves toward or away from the camera.

## Roadmap

- Speed: faster render clock with a dual-clock framebuffer, parallel intersection units
- Measure LUT, flip-flop, DSP and BRAM use, maximum clock and real frame rate in Vivado
- Reflections, triangles and meshes, acceleration structures

## License

MIT Licence
