# FPGA Ray Tracing Engine (PYNQ-Z2)

A hardware ray tracer written in SystemVerilog. The FPGA renders a 3D scene entirely in logic and
drives a monitor over HDMI. The PYNQ-Z2 has no HDMI transmitter chip, so the design generates the
TMDS video signal itself (encoder, 10:1 serializers, differential outputs).

The scene is a checkerboard ground plane under a sky gradient, two spheres, and a walking figure made
of boxes. A point light circles the figure and casts live shadows. Buttons and switches on the board
walk the figure around and move the camera.

> **Status:** verified in simulation against a floating-point Python reference model. An earlier
> version (one shaded sphere) ran on a real PYNQ-Z2 and monitor. The animated version (walking figure,
> shadows, controls) still needs a board run. Vivado resource use and timing have **not** been
> measured yet, and the frame rate below is an estimate from simulation.

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

LEDs: LD0 clock locked, LD1 monitor connected, LD2 auto-walk on, LD3 camera follow on.
The engine reads the buttons once per frame and remembers presses shorter than a frame.
See `docs/CONTROLS.md`.

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
sw_prototype/            Python golden model and generators
tb/                      self-checking testbenches
docs/                    HDMI implementation guide, controls
run_tests.py / .sh       regression runner
```

`scene_pkg.sv`, `scene_rom.sv`, `box_rom.sv`, `pose_rom.sv`, `light_rom.sv` and `light_orbit_rom.sv`
are generated from `sw_prototype/scene.py` by `sw_prototype/gen_scene_pkg.py`. Edit the scene in
Python and regenerate; don't edit the generated files. The same `scene.py` drives the golden model,
so the hardware and the reference always render the same scene.

## Verification

Every module has a self-checking testbench, and the whole renderer is compared against the Python
golden model (`sw_prototype/raytracer.py`).

| Test | What it checks |
|---|---|
| `tb_math` | fixed-point add, multiply, divide, square root, vector ops |
| `tb_tmds_encoder` | TMDS encoding (DC balance, decode round trip) |
| `tb_ray_generator` | ray directions for the centre, corners and edges |
| `tb_sphere_intersection` | 451 vectors: hit, miss, tangent, inside, behind the camera |
| `tb_box_intersection` | ~28,000 vectors from the golden model, all six faces |
| `tb_lambert`, `tb_point_light` | shading and point-light vector |
| `tb_bars` | video timing, colour bars, sync alignment |
| `tb_motion` | frames with button input, moving camera and light vs the golden model |
| `tb_system` | full frame through framebuffer and TMDS, checked against the golden model |

Simulated frames match the golden model within 1 colour level, comparing every 4th pixel
(`PIXEL_STRIDE=4`) to keep simulation time short; a few pixels on shape edges may differ by more.
The shipped design renders every pixel.

### Run the tests

Needs Python 3 and [Icarus Verilog](https://bleyer.org/icarus/) (`iverilog`, `vvp` on PATH).

```
python run_tests.py          # all tests
python run_tests.py --fast   # skip the full-frame render
```

On Linux or macOS, `./run_tests.sh` does the same. Run it from the project folder (the one containing
`rtl/` and `tb/`).

## Build for the PYNQ-Z2

1. Create a Vivado project for part `xc7z020clg400-1` and add everything under `rtl/`
   (SystemVerilog) plus `constraints/pynq_z2_hdmi.xdc`.
2. Set `pynq_top` as the top module.
3. Run synthesis, implementation and generate the bitstream.
4. Connect the board's HDMI **OUT** port to a monitor and program the board.

For a first bring-up, set `TEST_PATTERN = 1` in `pynq_top` to show colour bars. That checks the clocking,
TMDS and serializers before the ray tracer is involved. `docs/HDMI_IMPLEMENTATION_GUIDE.md` has the
step-by-step guide (written before the animation, controls and shadows were added, so it doesn't
cover those).

Design parameters in `pynq_top`: `ANIMATE`, `ORBIT_LIGHT`, `POINT_LIGHT`, `SHADOWS`, `TEST_PATTERN`.
Shadows need `POINT_LIGHT = 1`.

## Known limitations

- **Speed:** pixels are rendered one at a time. From simulation I estimate about 3 frames per second
  at 25 MHz with shadows on (about 4 without). This is an extrapolation, not a measured full frame.
- **Shadows:** only points within about 10 units of ray depth from the camera are shadow-tested.
  Longer shadow rays would overflow the number format in the sphere unit.
- **Figure:** boxes can't tilt, so limbs swing as stepped blocks. The walker keeps facing left or
  right when it moves toward or away from the camera.
- **Unused module:** `rtl/geometry/closest_hit.sv` is not used; the closest-hit logic lives in the
  render engine.
- **Serializer:** `tmds_serializer.sv` uses Xilinx OSERDESE2 primitives, which Icarus can't simulate
  (the tests use stubs). It has run on hardware in the earlier version.

## Roadmap

- Speed: faster render clock with a dual-clock framebuffer, parallel intersection units
- Measure LUT, flip-flop, DSP and BRAM use, maximum clock and real frame rate in Vivado
- Reflections, triangles and meshes, acceleration structures

## License

Add a license of your choice (for example MIT) before publishing.
