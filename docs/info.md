<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The chip contains three ring oscillators built from different standard cells:

| Ring | Cells | Stages |
|------|-------|--------|
| 0 | inverter (first stage is a NAND2 used as enable) | 51 |
| 1 | NAND2 | 41 |
| 2 | NOR2 | 41 |

Only the selected ring runs. Only its first stage is gated by the enable signal, so a disabled ring is broken at
exactly one point and starts with a single travelling edge when enabled.

A measurement opens a gate for exactly N cycles of `clk` (N = 1024, 4096, 16384 or 65536). During the gate a
24-bit ripple counter, clocked by the ring itself, counts its rising edges. When the gate closes the counter
stops and the value can be read one byte at a time.

- Ring frequency: `f = count * f_clk / N`
- Delay of one stage: `t_pd = 1 / (2 * stages * f)`

The selected ring divided by 64 is also driven on `uio[0]`, so its frequency can be checked directly without the
counter (the output pads are rated to about 33 MHz, so the raw ring is not driven out).

## How to test

1. Set `clk` to 10 MHz (any known frequency works) and reset the design.
2. Select a ring with `ui[1:0]` (0 inverter, 1 NAND2, 2 NOR2), set `ui[2]` = 1 to enable it.
3. Choose the gate length with `ui[7:6]` (0: 2^10, 1: 2^12, 2: 2^14, 3: 2^16 clock cycles).
4. Pulse `ui[3]` from 0 to 1 to start. `uio[2]` is high while measuring, `uio[1]` goes high when done.
5. Read the count with `ui[5:4]` = 0, 1, 2 (low, middle, high byte on `uo[7:0]`).
   `ui[5:4]` = 3 shows a status byte: `{done, busy, enabled, ring[1:0], 3'b000}`.
6. Compute `f` and `t_pd` from the formulas above. Repeat at different supply voltages and temperatures to see
   how the cell delays change.

## External hardware

None. The demo board's RP2040 can drive the inputs, read the outputs and measure the frequency on `uio[0]`.
