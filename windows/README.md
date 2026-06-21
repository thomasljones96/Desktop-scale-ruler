# Desktop Scale Ruler — Windows

A native Windows version (C# / WPF) of the macOS Desktop Scale Ruler. Same idea: a floating, always-on-top ruler that reads real-world dimensions off on-screen PDF plans, plus distance and area measuring.

## Build & run

You don't need Visual Studio — just the free **.NET 8 SDK** (https://dotnet.microsoft.com/download).

```powershell
cd windows
dotnet run -c Release
```

To produce a standalone folder you can copy elsewhere:

```powershell
dotnet publish -c Release -r win-x64 --self-contained false -o publish
```

The app appears as a **ruler in the system tray** (bottom-right, near the clock) plus the floating ruler itself. Right-click the tray icon for all settings and modes.

## Using it

- **Move**: drag the ruler's middle. **Resize**: drag a blue end-handle.
- **Minimise**: double-click the ruler to shrink it to a small pill; double-click again to expand.
- Everything else — calibrate, scale presets, rotate, units, distance/area modes, copy — is on the **tray icon's right-click menu**.

### Scale

- **Calibrate to a known dimension** (most reliable): stretch the ruler across a dimension you know on the plan and type its real length in mm. Readout turns green.
- **Scale 1:100 / 1:50 / custom**: accurate at the viewer's actual size. Run **Calibrate Display (once)** — hold a card/ruler to the screen, match the on-screen ruler, enter the physical length — to make the presets exact on your monitor.

### Modes

- **Distance**: click two points anywhere for straight-line length + angle.
- **Area**: click corners, then double-click or Enter to close, for m².
- In Distance/Area the overlay captures clicks across the screen. **Esc** clears the current points; **Esc again** (or a **right-click**) leaves measure mode and gives the screen back. You can also pick **Mode: Ruler** from the tray.

Settings persist in `%APPDATA%\DesktopScaleRuler\settings.json`.

## Notes / limitations

- The app is **Per-Monitor-V2 DPI aware** and converts the physical mouse position into WPF coordinates itself, so the cursor guide lines up at any display scale (100 %, 125 %, 150 %, …). Preset scales still depend on the OS-reported screen size — **Calibrate Display** (once) or calibrating against a known dimension makes them exact.
- There's no taskbar button by design. Reach all controls — including **Quit** — by **right-clicking the ruler** or the **tray icon** (bottom-right, by the clock).
- Like the Mac build it's unsigned, so SmartScreen may warn on first run ("More info → Run anyway").
