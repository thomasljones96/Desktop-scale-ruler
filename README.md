# Scale Plan Ruler

A floating, always-on-top screen ruler for macOS — in the spirit of [Free Ruler](https://github.com/pascalpp/FreeRuler) — but it reads out **real-world dimensions** so you can measure on-screen PDF plans at scale.

## Build it (one time)

You need Apple's Swift compiler, which comes with the Xcode Command Line Tools. If you've never installed them:

```bash
xcode-select --install
```

Then build the app:

```bash
cd "path/to/ScalePlanRuler"
chmod +x build.sh
./build.sh
open ScalePlanRuler.app
```

That produces `ScalePlanRuler.app`, which you can drag into `/Applications`. Because it isn't code-signed, the first launch may need: right-click the app → **Open** → **Open**.

## Using it

A thin ruler floats above all your windows, plus a small control panel.

- **Move** the ruler: drag its middle.
- **Resize / stretch** it: drag either blue end-handle.
- **Rotate** between horizontal and vertical: the control panel's `Rotate ↔ / ↕` button.
- **Units**: `mm / m` toggles the big centre readout.

The centre of the ruler always shows the real-world length it currently spans, plus the scale in effect, e.g. `3.000 m   (1:100)`.

## Setting the scale — two ways

**1. Calibrate (most reliable — works at any zoom).**
Stretch the ruler across a dimension you already know on the plan (say a wall dimensioned `3000`), click **Calibrate to known dimension…**, and type `3000`. The ruler now reads true millimetres for that plan at that zoom. This is the recommended workflow because it doesn't care what zoom your PDF viewer is at.

**2. Scale presets `1:100` / `1:50` / `Custom 1:n…`.**
These assume your PDF is displayed at **100% zoom**. At 1:100, one paper point (1/72") equals 100 × 25.4/72 mm in the real world. If your viewer isn't at exactly 100%, the presets will be off — calibrate instead.

> Tip: since your plans are usually 1:100 or 1:50, tap the preset first as a sanity check, then calibrate against a known dimension on each plan for accuracy. After calibrating, the panel shows the implied scale (e.g. `≈ 1:100`) so you can confirm the plan is what it claims to be.

## Notes & limits

- It measures a straight span (horizontal or vertical). For a diagonal, rotate to vertical/horizontal and measure the two legs, or calibrate and read each.
- A free-floating screen ruler can't know your PDF's zoom by itself — that's exactly why calibration exists. Re-calibrate if you change zoom.
- Quit with ⌘Q.
