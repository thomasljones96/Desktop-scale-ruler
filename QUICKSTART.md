# Desktop Scale Ruler — Quick Start

A floating, always-on-top ruler that measures on-screen PDF plans in real-world units, with a running takeoff list. ~2 minutes to get going.

---

## 1. Install

**macOS** — download `DesktopScaleRuler.zip` from the [Releases](../../releases) page, unzip, drag `DesktopScaleRuler.app` to Applications. First launch: right-click the app → **Open** → **Open** (it's unsigned).

**Windows** — download `DesktopScaleRuler-Windows.zip`, unzip, run `DesktopScaleRuler.exe`. If SmartScreen warns: **More info → Run anyway** (unsigned). Nothing else to install.

You'll see a thin ruler floating on top, plus a ruler icon in the **menu bar** (Mac, top-right) or **system tray** (Windows, bottom-right). That icon — and **right-clicking the ruler** — is where all the controls live, including **Quit**.

## 2. Open your plan

Open the PDF in Preview / Acrobat / your browser. Set a zoom and leave it there (the ruler can't follow zoom changes — if you re-zoom, re-calibrate).

## 3. Set the scale (do this once per plan)

The reliable way, works at any zoom:

1. Drag the ruler so it spans a dimension you already know (e.g. a wall marked `3000`).
2. Right-click the ruler (or use the menu) → **Calibrate to known dimension**.
3. Type the real length in mm (`3000`) → the readout turns **green**. You're calibrated.

Tip: the **1:100 / 1:50** presets work instantly if your PDF is at "Actual Size" — and become exact after you run **Calibrate Display (once)** with a credit card (85.6 mm) held to the screen.

## 4. Measure

Switch modes from the menu / right-click menu:

| Mode | What to do | You get |
|---|---|---|
| **Ruler** | drag/stretch the floating ruler over things | live length + a cursor guide |
| **Distance** | click two points | straight-line length + angle |
| **Area** | click corners, then double-click / Enter | area in m² |
| **Count** | click each item | a running tally (doors, windows, posts…) |

In Distance/Area/Count the app captures clicks across the whole screen — press **Esc** (or right-click on Windows) to step back to the ruler.

## 5. Build a takeoff

Every distance, area and count drops into the **active set**.

1. Open **Takeoff list** (menu/right-click, ⌘T on Mac).
2. **New set…** and name it ("Footings", "Ground floor walls", "Slab"). Everything you measure now lands in that set.
3. The window shows each set with **subtotals** (lineal m, m², count) and a **grand total**.
4. **Export CSV** (for Excel / Jack) or **Copy**. **Undo** removes the last item.

The whole list is saved automatically and is still there next time you open the app.

---

### Handy shortcuts (Mac)

⌘B Ruler · ⌘D Distance · ⌘E Area · ⌘K Calibrate · ⌘T Takeoff list · ⌘N New set · ⌘C Copy · ⌘M Minimise · ⌘Q Quit

Double-click the ruler to shrink it to a pill; double-click again to expand.
