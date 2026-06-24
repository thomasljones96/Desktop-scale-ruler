// DesktopScaleRuler (Windows) — floating screen ruler for on-screen PDF plans.
// Code-only WPF app (no XAML). Per-Monitor-V2 DPI aware; the physical cursor is
// mapped into WPF coordinates so the guide lines up at any display scale.
//
// Features mirror the macOS version: scaled ruler with stacked readout,
// calibrate / display-calibrate / presets, lead lines, live cursor guide,
// distance, area (m²) and count modes feeding a named-set takeoff list with
// subtotals, grand totals, CSV export and copy, minimise-to-pill, tray +
// right-click menus, and settings + takeoff that persist between launches.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using WForms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace DesktopScaleRuler
{
    // ---- Win32 interop + display helpers ----------------------------------
    static class Native
    {
        public const double FallbackMmPerUnit = 25.4 / 96.0;

        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
        [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int index);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        public const int GWL_EXSTYLE = -20;
        public const int WS_EX_LAYERED = 0x80000;
        public const int WS_EX_TRANSPARENT = 0x20;
        public const int WS_EX_TOOLWINDOW = 0x80;   // keep off Alt-Tab
        const int HORZSIZE = 4, HORZRES = 8;

        public static Point CursorScreen()
        {
            GetCursorPos(out var p);
            return new Point(p.X, p.Y);
        }

        // Physical millimetres per PHYSICAL pixel (0 if the display won't report it).
        public static double GdiMmPerPixel()
        {
            var hdc = GetDC(IntPtr.Zero);
            if (hdc == IntPtr.Zero) return 0;
            int mm = GetDeviceCaps(hdc, HORZSIZE);
            int px = GetDeviceCaps(hdc, HORZRES);
            ReleaseDC(IntPtr.Zero, hdc);
            return (mm > 0 && px > 0) ? (double)mm / px : 0;
        }

        public static void SetClickThrough(Window w, bool through)
        {
            var h = new WindowInteropHelper(w).Handle;
            if (h == IntPtr.Zero) return;
            int ex = GetWindowLong(h, GWL_EXSTYLE) | WS_EX_LAYERED | WS_EX_TOOLWINDOW;
            if (through) ex |= WS_EX_TRANSPARENT; else ex &= ~WS_EX_TRANSPARENT;
            SetWindowLong(h, GWL_EXSTYLE, ex);
        }
    }

    // ---- Persisted settings -----------------------------------------------
    class Settings
    {
        public double MmPerUnit { get; set; }
        public double ScaleRatio { get; set; } = 100;
        public bool UseMetres { get; set; }
        public bool ShowGuide { get; set; } = true;
        public bool ShowLeadLines { get; set; } = true;
        public bool Calibrated { get; set; }
        public bool Vertical { get; set; }
        public double? DisplayOverride { get; set; }
        public double Left { get; set; } = 240;
        public double Top { get; set; } = 200;
        public double Width { get; set; } = 620;
        public double Height { get; set; } = 56;
        public bool HasScale { get; set; }

        static string Path => System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "DesktopScaleRuler", "settings.json");

        public static Settings Load()
        {
            try { if (File.Exists(Path)) return JsonSerializer.Deserialize<Settings>(File.ReadAllText(Path)) ?? new Settings(); }
            catch { }
            return new Settings();
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path));
                File.WriteAllText(Path, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { }
        }
    }

    // ---- Shared model ------------------------------------------------------
    static class Model
    {
        public static double MmPerUnit = 100.0 * Native.FallbackMmPerUnit;
        public static double ScaleRatio = 100;
        public static bool UseMetres = false;
        public static bool ShowGuide = true;
        public static bool ShowLeadLines = true;
        public static bool Calibrated = false;
        public static int Mode = 0;            // 0 ruler, 1 distance, 2 area, 3 count
        public static double? DisplayOverride = null;

        public static event Action Changed;
        public static void Notify() => Changed?.Invoke();

        public static double RealMM(double units) => units * MmPerUnit;

        public static string Formatted(double units)
        {
            double mm = RealMM(Math.Abs(units));
            return UseMetres
                ? (mm / 1000.0).ToString("0.000", CultureInfo.InvariantCulture) + " m"
                : mm.ToString("0", CultureInfo.InvariantCulture) + " mm";
        }

        public static string ScaleLabel => "1:" + ScaleRatio.ToString("0.####", CultureInfo.InvariantCulture);
    }

    // ---- Takeoff store -----------------------------------------------------
    class TakeoffItem
    {
        public string Kind { get; set; }    // "distance" | "area" | "count"
        public double Value { get; set; }   // distance: mm, area: m², count: 1
        public string Set { get; set; }
    }

    static class Takeoff
    {
        public static List<TakeoffItem> Items = new List<TakeoffItem>();
        public static string ActiveSet = "Set 1";
        public static event Action Changed;

        static string FilePath => System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "DesktopScaleRuler", "takeoff.json");

        public static void Load()
        {
            try
            {
                if (System.IO.File.Exists(FilePath))
                {
                    Items = System.Text.Json.JsonSerializer.Deserialize<List<TakeoffItem>>(System.IO.File.ReadAllText(FilePath)) ?? new List<TakeoffItem>();
                    if (Items.Count > 0) ActiveSet = Items[Items.Count - 1].Set;
                }
            }
            catch { }
        }

        static void Save()
        {
            try
            {
                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(FilePath));
                System.IO.File.WriteAllText(FilePath, System.Text.Json.JsonSerializer.Serialize(Items, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
            }
            catch { }
        }

        public static void Add(string kind, double value)
        {
            Items.Add(new TakeoffItem { Kind = kind, Value = value, Set = ActiveSet }); Save(); Changed?.Invoke();
        }
        public static void UndoLast() { if (Items.Count > 0) { Items.RemoveAt(Items.Count - 1); Save(); Changed?.Invoke(); } }
        public static void ClearAll() { Items.Clear(); Save(); Changed?.Invoke(); }
        public static void NewSet(string name) { ActiveSet = name; Changed?.Invoke(); }

        static List<string> OrderedSets()
        {
            var seen = new List<string>();
            foreach (var it in Items) if (!seen.Contains(it.Set)) seen.Add(it.Set);
            if (!seen.Contains(ActiveSet)) seen.Add(ActiveSet);
            return seen;
        }

        public static string SummaryText()
        {
            var sb = new System.Text.StringBuilder();
            double gLen = 0, gArea = 0; int gCount = 0;
            foreach (var set in OrderedSets())
            {
                sb.AppendLine("▸ " + set + (set == ActiveSet ? "   (active)" : ""));
                double sLen = 0, sArea = 0; int sCount = 0, idx = 1;
                foreach (var it in Items)
                {
                    if (it.Set != set) continue;
                    if (it.Kind == "distance") { sb.AppendLine(string.Format(CultureInfo.InvariantCulture, "    {0,2}.  length   {1:0.000} m", idx, it.Value / 1000)); sLen += it.Value / 1000; idx++; }
                    else if (it.Kind == "area") { sb.AppendLine(string.Format(CultureInfo.InvariantCulture, "    {0,2}.  area     {1:0.00} m²", idx, it.Value)); sArea += it.Value; idx++; }
                    else sCount++;
                }
                if (sCount > 0) sb.AppendLine(string.Format(CultureInfo.InvariantCulture, "    count: {0} ea", sCount));
                sb.AppendLine(string.Format(CultureInfo.InvariantCulture, "    - subtotal:  {0:0.000} m   {1:0.00} m²   {2} ea", sLen, sArea, sCount));
                sb.AppendLine();
                gLen += sLen; gArea += sArea; gCount += sCount;
            }
            if (Items.Count == 0) sb.AppendLine("No measurements yet. Pick Distance, Area or Count mode and measure.\n");
            sb.Append(string.Format(CultureInfo.InvariantCulture, "TOTAL:  {0:0.000} m   -   {1:0.00} m²   -   {2} ea", gLen, gArea, gCount));
            return sb.ToString();
        }

        public static string Csv()
        {
            string Esc(string s) => (s.Contains(",") || s.Contains("\"")) ? "\"" + s.Replace("\"", "\"\"") + "\"" : s;
            var sb = new System.Text.StringBuilder();
            sb.AppendLine("Set,Type,Value,Unit");
            foreach (var it in Items)
            {
                if (it.Kind == "distance") sb.AppendLine(Esc(it.Set) + ",Length," + (it.Value / 1000).ToString("0.000", CultureInfo.InvariantCulture) + ",m");
                else if (it.Kind == "area") sb.AppendLine(Esc(it.Set) + ",Area," + it.Value.ToString("0.000", CultureInfo.InvariantCulture) + ",m2");
                else sb.AppendLine(Esc(it.Set) + ",Count,1,ea");
            }
            return sb.ToString();
        }
    }

    // ---- Ruler element -----------------------------------------------------
    class RulerElement : FrameworkElement
    {
        public Window Win;
        public bool Vertical = false;
        public bool Collapsed = false;
        public Action OnDoubleClick;
        public Action OnGeometryChanged;     // live (repaint only)
        public Action OnGeometryCommitted;   // on mouse-up (persist)

        const double HandleSize = 18, MinLen = 90;
        enum Drag { None, Move, ResizeStart, ResizeEnd }
        Drag _drag = Drag.None;
        Point _startCursor;
        Rect _startRect;

        static readonly Typeface Face = new Typeface("Segoe UI");
        static FormattedText FT(string s, double size, Brush brush) =>
            new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, size, brush, 1.0);

        public double SpanUnits => Vertical ? ActualHeight : ActualWidth;

        protected override void OnRender(DrawingContext dc)
        {
            var b = new Rect(0, 0, ActualWidth, ActualHeight);
            if (Collapsed) { DrawCollapsed(dc, b); return; }

            var bg = new SolidColorBrush(Color.FromArgb(235, 250, 250, 250));
            var border = new Pen(new SolidColorBrush(Color.FromArgb(230, 102, 102, 102)), 1);
            dc.DrawRoundedRectangle(bg, border, new Rect(0.5, 0.5, Math.Max(0, b.Width - 1), Math.Max(0, b.Height - 1)), 6, 6);

            DrawTicks(dc);
            DrawHandles(dc);
            DrawReadout(dc);
        }

        void DrawCollapsed(DrawingContext dc, Rect b)
        {
            var blue = new SolidColorBrush(Color.FromArgb(242, 0, 122, 242));
            dc.DrawRoundedRectangle(blue, null, b, 7, 7);
            var t = FT(Model.ScaleLabel + "  ⇲", 11, Brushes.White);
            dc.DrawText(t, new Point((b.Width - t.Width) / 2, (b.Height - t.Height) / 2));
        }

        double NiceTickMM(double targetUnits)
        {
            double targetMM = targetUnits * Model.MmPerUnit;
            double[] c = { 1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000, 20000, 50000, 100000 };
            foreach (var v in c) if (v >= targetMM) return v;
            return c[c.Length - 1];
        }

        string TickLabel(double mm)
        {
            if (mm == 0) return "0";
            if (mm >= 1000)
            {
                double m = mm / 1000.0;
                return (m == Math.Round(m) ? m.ToString("0", CultureInfo.InvariantCulture) : m.ToString("0.##", CultureInfo.InvariantCulture)) + "m";
            }
            return mm.ToString("0", CultureInfo.InvariantCulture);
        }

        void DrawTicks(DrawingContext dc)
        {
            bool horiz = !Vertical;
            double len = horiz ? ActualWidth : ActualHeight;
            double majorMM = NiceTickMM(70);
            double step = majorMM / Model.MmPerUnit;
            if (step <= 3) return;

            var minorPen = new Pen(new SolidColorBrush(Color.FromArgb(200, 128, 128, 128)), 0.5);
            double minor = step / 5.0;
            if (minor > 1.5)
                for (double m = 0; m <= len + 0.5; m += minor)
                {
                    if (horiz) { dc.DrawLine(minorPen, new Point(m, 0), new Point(m, 7)); dc.DrawLine(minorPen, new Point(m, ActualHeight), new Point(m, ActualHeight - 7)); }
                    else { dc.DrawLine(minorPen, new Point(0, m), new Point(7, m)); dc.DrawLine(minorPen, new Point(ActualWidth, m), new Point(ActualWidth - 7, m)); }
                }

            var majorPen = new Pen(new SolidColorBrush(Color.FromArgb(242, 38, 38, 38)), 1);
            int i = 0;
            for (double d = 0; d <= len + 0.5; d += step, i++)
            {
                if (horiz) { dc.DrawLine(majorPen, new Point(d, 0), new Point(d, 14)); dc.DrawLine(majorPen, new Point(d, ActualHeight), new Point(d, ActualHeight - 14)); }
                else { dc.DrawLine(majorPen, new Point(0, d), new Point(14, d)); dc.DrawLine(majorPen, new Point(ActualWidth, d), new Point(ActualWidth - 14, d)); }

                var t = FT(TickLabel(i * majorMM), 9, Brushes.Black);
                if (horiz) dc.DrawText(t, new Point(Math.Min(d + 2, ActualWidth - t.Width - 2), 14 + 1));
                else dc.DrawText(t, new Point(14 + 2, Math.Min(d + 2, ActualHeight - t.Height - 2)));
            }
        }

        void DrawHandles(DrawingContext dc)
        {
            var blue = new SolidColorBrush(Color.FromArgb(230, 0, 122, 242));
            if (!Vertical)
            {
                dc.DrawRoundedRectangle(blue, null, new Rect(0, 0, HandleSize, ActualHeight), 6, 6);
                dc.DrawRoundedRectangle(blue, null, new Rect(ActualWidth - HandleSize, 0, HandleSize, ActualHeight), 6, 6);
            }
            else
            {
                dc.DrawRoundedRectangle(blue, null, new Rect(0, 0, ActualWidth, HandleSize), 6, 6);
                dc.DrawRoundedRectangle(blue, null, new Rect(0, ActualHeight - HandleSize, ActualWidth, HandleSize), 6, 6);
            }
        }

        void DrawReadout(DrawingContext dc)
        {
            double len = Vertical ? ActualHeight : ActualWidth;
            Brush main = Model.Calibrated ? new SolidColorBrush(Color.FromRgb(0, 115, 26)) : Brushes.Black;
            var l1 = FT(Model.Formatted(len), 13, main);
            var l2 = FT(Model.ScaleLabel, 10, Brushes.DimGray);
            double gap = 1, totalH = l1.Height + gap + l2.Height;

            if (!Vertical)
            {
                double cx = ActualWidth / 2, cy = ActualHeight / 2;
                DrawTextBg(dc, l1, new Point(cx - l1.Width / 2, cy - totalH / 2));
                DrawTextBg(dc, l2, new Point(cx - l2.Width / 2, cy - totalH / 2 + l1.Height + gap));
            }
            else
            {
                dc.PushTransform(new RotateTransform(90, ActualWidth / 2, ActualHeight / 2));
                double cx = ActualWidth / 2, cy = ActualHeight / 2;
                DrawTextBg(dc, l1, new Point(cx - l1.Width / 2, cy - totalH / 2));
                DrawTextBg(dc, l2, new Point(cx - l2.Width / 2, cy - totalH / 2 + l1.Height + gap));
                dc.Pop();
            }
        }

        static void DrawTextBg(DrawingContext dc, FormattedText t, Point at)
        {
            dc.DrawRectangle(new SolidColorBrush(Color.FromArgb(180, 255, 255, 255)), null,
                new Rect(at.X - 2, at.Y, t.Width + 4, t.Height));
            dc.DrawText(t, at);
        }

        // ---- interaction ----
        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            if (e.ClickCount >= 2) { _drag = Drag.None; OnDoubleClick?.Invoke(); return; }
            _startCursor = Native.CursorScreen();
            _startRect = new Rect(Win.Left, Win.Top, Win.Width, Win.Height);
            if (Collapsed) { _drag = Drag.Move; CaptureMouse(); return; }
            var p = e.GetPosition(this);
            double pos = Vertical ? p.Y : p.X;
            double len = Vertical ? ActualHeight : ActualWidth;
            if (pos <= HandleSize) _drag = Drag.ResizeStart;
            else if (pos >= len - HandleSize) _drag = Drag.ResizeEnd;
            else _drag = Drag.Move;
            CaptureMouse();
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (_drag == Drag.None) return;
            var cur = Native.CursorScreen();
            double dx = cur.X - _startCursor.X, dy = cur.Y - _startCursor.Y;
            if (_drag == Drag.Move) { Win.Left = _startRect.X + dx; Win.Top = _startRect.Y + dy; }
            else if (!Vertical)
            {
                if (_drag == Drag.ResizeEnd) Win.Width = Math.Max(MinLen, _startRect.Width + dx);
                else { double w = Math.Max(MinLen, _startRect.Width - dx); Win.Left = _startRect.X + (_startRect.Width - w); Win.Width = w; }
            }
            else
            {
                if (_drag == Drag.ResizeEnd) Win.Height = Math.Max(MinLen, _startRect.Height + dy);
                else { double h = Math.Max(MinLen, _startRect.Height - dy); Win.Top = _startRect.Y + (_startRect.Height - h); Win.Height = h; }
            }
            InvalidateVisual();
            OnGeometryChanged?.Invoke();
        }

        protected override void OnMouseUp(MouseButtonEventArgs e) { _drag = Drag.None; ReleaseMouseCapture(); OnGeometryCommitted?.Invoke(); }
    }

    // ---- Overlay element ---------------------------------------------------
    class OverlayElement : FrameworkElement
    {
        public Window OverlayWin, RulerWin;
        public RulerElement Ruler;
        public Point CursorScreen;
        public List<Point> Pts = new List<Point>();
        public bool AreaClosed = false;
        public List<Point> CountMarkers = new List<Point>();
        public Action OnExitRequested;   // right-click / Esc leaves measure mode

        static readonly Typeface Face = new Typeface("Segoe UI");
        static FormattedText FT(string s, double size, Brush brush) =>
            new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, size, brush, 1.0);

        Point ToLocal(Point screen) => new Point(screen.X - OverlayWin.Left, screen.Y - OverlayWin.Top);

        // ---- input (only when not click-through, i.e. measure modes) ----
        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            if (Model.Mode == 0) return;
            var p = new Point(e.GetPosition(this).X + OverlayWin.Left, e.GetPosition(this).Y + OverlayWin.Top);
            if (Model.Mode == 3)                                  // count
            {
                CountMarkers.Add(p); Takeoff.Add("count", 1); InvalidateVisual(); return;
            }
            if (Model.Mode == 2)                                  // area
            {
                if (e.ClickCount >= 2) { if (Pts.Count >= 3) CommitArea(); else Pts.Clear(); InvalidateVisual(); return; }
                Pts.Add(p); InvalidateVisual(); return;
            }
            // distance (mode 1): two clicks = one length
            if (Pts.Count == 1) { CommitDistance(Pts[0], p); Pts.Clear(); }
            else { Pts = new List<Point> { p }; }
            InvalidateVisual();
        }

        void CommitDistance(Point a, Point b)
        {
            double units = Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));
            double mm = Model.RealMM(units);
            if (mm > 0) Takeoff.Add("distance", mm);
        }

        void CommitArea()
        {
            double m2 = PolygonArea(Pts) * Model.MmPerUnit * Model.MmPerUnit / 1_000_000.0;
            if (m2 > 0) Takeoff.Add("area", m2);
            Pts.Clear(); AreaClosed = false;
        }

        public void HandleKey(Key k)
        {
            if (k == Key.Escape)
            {
                if (Pts.Count > 0) { Pts.Clear(); AreaClosed = false; InvalidateVisual(); }
                else OnExitRequested?.Invoke();
            }
            else if ((k == Key.Enter || k == Key.Return) && Model.Mode == 2 && Pts.Count >= 3) { CommitArea(); InvalidateVisual(); }
        }

        protected override void OnMouseRightButtonDown(MouseButtonEventArgs e)
        {
            if (Model.Mode == 0) return;
            OnExitRequested?.Invoke();
        }

        public string DistanceText()
        {
            if (Pts.Count < 1) return null;
            var a = Pts[Pts.Count - 1]; var b = CursorScreen;
            double dist = Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));
            double ang = Math.Atan2(-(b.Y - a.Y), b.X - a.X) * 180 / Math.PI; // y-down → negate for true angle
            return Model.Formatted(dist) + "  " + Math.Abs(ang).ToString("0.0", CultureInfo.InvariantCulture) + "°";
        }

        public string AreaText()
        {
            if (Pts.Count < 3) return null;
            double a = PolygonArea(Pts);
            double mpp = Model.MmPerUnit;
            double m2 = a * mpp * mpp / 1_000_000.0;
            return m2.ToString("0.00", CultureInfo.InvariantCulture) + " m²";
        }

        static double PolygonArea(List<Point> p)
        {
            if (p.Count < 3) return 0;
            double s = 0;
            for (int i = 0; i < p.Count; i++) { var j = (i + 1) % p.Count; s += p[i].X * p[j].Y - p[j].X * p[i].Y; }
            return Math.Abs(s) / 2;
        }

        protected override void OnRender(DrawingContext dc)
        {
            if (RulerWin == null || Ruler == null) return;
            if (Model.Mode == 0) DrawRulerGuides(dc);
            else if (Model.Mode == 1) DrawDistance(dc);
            else if (Model.Mode == 2) DrawArea(dc);
            else DrawCount(dc);
        }

        void Label(DrawingContext dc, string text, Point at, Color color)
        {
            var t = FT(" " + text + " ", 11, Brushes.White);
            double lx = Math.Min(Math.Max(2, at.X + 8), ActualWidth - t.Width - 2);
            double ly = Math.Min(Math.Max(2, at.Y + 8), ActualHeight - t.Height - 2);
            dc.DrawRectangle(new SolidColorBrush(color), null, new Rect(lx, ly, t.Width, t.Height));
            dc.DrawText(t, new Point(lx, ly));
        }

        void Dot(DrawingContext dc, Point p, Color c) =>
            dc.DrawEllipse(new SolidColorBrush(c), null, p, 3, 3);

        void DrawRulerGuides(DrawingContext dc)
        {
            if (Ruler.Collapsed) return;
            var rf = new Rect(RulerWin.Left, RulerWin.Top, RulerWin.Width, RulerWin.Height);
            bool horiz = !Ruler.Vertical;

            if (Model.ShowLeadLines)
            {
                var pen = new Pen(new SolidColorBrush(Color.FromArgb(128, 0, 122, 242)), 1);
                double ext = 240;
                if (horiz)
                    foreach (var x in new[] { rf.Left, rf.Right })
                        dc.DrawLine(pen, ToLocal(new Point(x, rf.Top - ext)), ToLocal(new Point(x, rf.Bottom + ext)));
                else
                    foreach (var y in new[] { rf.Top, rf.Bottom })
                        dc.DrawLine(pen, ToLocal(new Point(rf.Left - ext, y)), ToLocal(new Point(rf.Right + ext, y)));
            }

            if (!Model.ShowGuide) return;
            var red = Color.FromArgb(230, 217, 26, 26);
            var rpen = new Pen(new SolidColorBrush(red), 1);
            var c = ToLocal(CursorScreen);
            double distUnits;
            if (horiz)
            {
                distUnits = CursorScreen.X - rf.Left;
                double midY = ToLocal(new Point(0, rf.Top + rf.Height / 2)).Y;
                dc.DrawLine(rpen, new Point(c.X, midY), new Point(c.X, c.Y));
            }
            else
            {
                distUnits = CursorScreen.Y - rf.Top;
                double midX = ToLocal(new Point(rf.Left + rf.Width / 2, 0)).X;
                dc.DrawLine(rpen, new Point(midX, c.Y), new Point(c.X, c.Y));
            }
            Dot(dc, c, red);
            Label(dc, Model.Formatted(distUnits), c, red);
        }

        void DrawDistance(DrawingContext dc)
        {
            var red = Color.FromArgb(242, 217, 26, 26);
            if (Pts.Count == 0) { Label(dc, "Click two points to measure each length", ToLocal(CursorScreen), red); return; }
            var a = Pts[Pts.Count - 1];
            var av = ToLocal(a); var bv = ToLocal(CursorScreen);
            dc.DrawLine(new Pen(new SolidColorBrush(red), 1.5), av, bv);
            Dot(dc, av, red); Dot(dc, bv, red);
            var mid = new Point((av.X + bv.X) / 2, (av.Y + bv.Y) / 2);
            var t = DistanceText(); if (t != null) Label(dc, t, mid, red);
        }

        void DrawCount(DrawingContext dc)
        {
            var purple = Color.FromArgb(242, 140, 38, 184);
            if (CountMarkers.Count == 0) Label(dc, "Click to count items into “" + Takeoff.ActiveSet + "”", ToLocal(CursorScreen), purple);
            var fill = new SolidColorBrush(purple);
            for (int i = 0; i < CountMarkers.Count; i++)
            {
                var v = ToLocal(CountMarkers[i]);
                dc.DrawEllipse(fill, null, v, 9, 9);
                var t = FT((i + 1).ToString(CultureInfo.InvariantCulture), 10, Brushes.White);
                dc.DrawText(t, new Point(v.X - t.Width / 2, v.Y - t.Height / 2));
            }
        }

        void DrawArea(DrawingContext dc)
        {
            var blue = Color.FromArgb(242, 26, 115, 230);
            if (Pts.Count == 0) { Label(dc, "Click corners; double-click or Enter to close", ToLocal(CursorScreen), blue); return; }
            var verts = new List<Point>(Pts);
            if (!AreaClosed) verts.Add(CursorScreen);
            var vv = verts.Select(ToLocal).ToList();

            var geo = new StreamGeometry();
            using (var ctx = geo.Open())
            {
                ctx.BeginFigure(vv[0], AreaClosed, AreaClosed);
                ctx.PolyLineTo(vv.Skip(1).ToList(), true, false);
            }
            geo.Freeze();
            if (AreaClosed) dc.DrawGeometry(new SolidColorBrush(Color.FromArgb(38, 26, 115, 230)), null, geo);
            dc.DrawGeometry(null, new Pen(new SolidColorBrush(blue), 1.5), geo);
            foreach (var p in Pts) Dot(dc, ToLocal(p), blue);

            if (verts.Count >= 3)
            {
                double cx = vv.Average(p => p.X), cy = vv.Average(p => p.Y);
                var t = AreaText(); if (t != null) Label(dc, t, new Point(cx, cy), blue);
            }
        }
    }

    // ---- Controller / app --------------------------------------------------
    class AppController
    {
        Window _ruler, _overlay;
        RulerElement _rv;
        OverlayElement _ov;
        Settings _s;
        WForms.NotifyIcon _tray;
        readonly Dictionary<string, WForms.ToolStripMenuItem> _menu = new Dictionary<string, WForms.ToolStripMenuItem>();
        System.Windows.Threading.DispatcherTimer _timer;
        Point _lastCursor = new Point(double.NaN, double.NaN);
        bool _collapsed = false;
        Rect _savedRect;
        bool _savedVertical;
        Window _takeoff;
        System.Windows.Controls.TextBox _takeoffText;
        System.Windows.Controls.TextBlock _takeoffHeader;

        // Real-world millimetres per device-independent unit (WPF unit).
        double PhysMmPerUnit()
        {
            if (Model.DisplayOverride is double o && o > 0) return o;
            double mmPerPhysPx = Native.GdiMmPerPixel();
            double scale = 1.0;
            try { if (_ruler != null) scale = VisualTreeHelper.GetDpi(_ruler).DpiScaleX; } catch { }
            if (mmPerPhysPx <= 0) return Native.FallbackMmPerUnit;   // 1 unit ≈ 1/96"
            return mmPerPhysPx * scale;                              // physPx→unit
        }

        // Convert a physical-pixel screen point to screen device-independent units.
        Point ScreenDiu(Point phys)
        {
            try { var p = _ov.PointFromScreen(phys); return new Point(p.X + _overlay.Left, p.Y + _overlay.Top); }
            catch { return phys; }
        }

        // ---- keep windows reachable across display changes ----
        static bool IsReachable(double left, double top, double w, double h)
        {
            double cx = left + w / 2, cy = top + h / 2;
            double vx = SystemParameters.VirtualScreenLeft, vy = SystemParameters.VirtualScreenTop;
            double vw = SystemParameters.VirtualScreenWidth, vh = SystemParameters.VirtualScreenHeight;
            return cx >= vx && cx <= vx + vw && cy >= vy && cy <= vy + vh;
        }

        static Rect PlaceOnPrimary(double w, double h)
        {
            var wa = SystemParameters.WorkArea;             // primary monitor, DIU
            double nw = Math.Min(w, wa.Width - 80), nh = Math.Min(h, wa.Height - 80);
            return new Rect(wa.Left + 80, wa.Top + 80, nw, nh);
        }

        void OnDisplaysChanged()
        {
            if (_overlay == null || _ruler == null) return;
            // overlay follows the new virtual-screen bounds
            _overlay.Left = SystemParameters.VirtualScreenLeft;
            _overlay.Top = SystemParameters.VirtualScreenTop;
            _overlay.Width = SystemParameters.VirtualScreenWidth;
            _overlay.Height = SystemParameters.VirtualScreenHeight;
            // re-home the ruler if it's stranded on a disconnected display
            if (!IsReachable(_ruler.Left, _ruler.Top, _ruler.Width, _ruler.Height))
            {
                var r = PlaceOnPrimary(_ruler.Width, _ruler.Height);
                _ruler.Left = r.Left; _ruler.Top = r.Top; _ruler.Width = r.Width; _ruler.Height = r.Height;
                Save();
            }
            if (_collapsed && !IsReachable(_savedRect.Left, _savedRect.Top, _savedRect.Width, _savedRect.Height))
                _savedRect = PlaceOnPrimary(_savedRect.Width, _savedRect.Height);
            _ov.InvalidateVisual();
        }

        public void Start()
        {
            _s = Settings.Load();
            Model.DisplayOverride = _s.DisplayOverride;
            Model.UseMetres = _s.UseMetres; Model.ShowGuide = _s.ShowGuide; Model.ShowLeadLines = _s.ShowLeadLines;
            Model.ScaleRatio = _s.ScaleRatio; Model.Calibrated = _s.Calibrated;

            BuildRuler();
            BuildOverlay();
            BuildTray();

            // default scale needs the windows up (for DPI), so compute it here
            if (_s.HasScale) Model.MmPerUnit = _s.MmPerUnit;
            else { Model.MmPerUnit = 100 * PhysMmPerUnit(); Model.ScaleRatio = 100; }
            _ov.CursorScreen = ScreenDiu(Native.CursorScreen());

            Model.Changed += () => { _rv.InvalidateVisual(); _ov.InvalidateVisual(); SyncMenu(); Save(); };

            Takeoff.Load();
            Takeoff.Changed += () => RefreshTakeoff();

            _timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
            _timer.Tick += (s, e) =>
            {
                var phys = Native.CursorScreen();
                if (Math.Abs(phys.X - _lastCursor.X) < 0.5 && Math.Abs(phys.Y - _lastCursor.Y) < 0.5) return; // idle → no repaint
                _lastCursor = phys;
                _ov.CursorScreen = ScreenDiu(phys);   // align with WPF coords at any display scale
                _ov.InvalidateVisual();
            };
            _timer.Start();

            Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (s, e) =>
                System.Windows.Application.Current.Dispatcher.Invoke(OnDisplaysChanged);

            SyncMenu();
        }

        void BuildRuler()
        {
            _ruler = new Window
            {
                WindowStyle = WindowStyle.None,
                AllowsTransparency = true,
                Background = System.Windows.Media.Brushes.Transparent,
                Topmost = true,
                ShowInTaskbar = false,
                ResizeMode = ResizeMode.NoResize,
                Left = _s.Left, Top = _s.Top, Width = _s.Width, Height = _s.Height,
                Title = "Desktop Scale Ruler"
            };
            if (!IsReachable(_ruler.Left, _ruler.Top, _ruler.Width, _ruler.Height))
            {
                var r = PlaceOnPrimary(_ruler.Width, _ruler.Height);
                _ruler.Left = r.Left; _ruler.Top = r.Top; _ruler.Width = r.Width; _ruler.Height = r.Height;
            }
            _rv = new RulerElement { Win = _ruler, Vertical = _s.Vertical };
            _rv.OnDoubleClick = ToggleCollapse;
            _rv.OnGeometryChanged = () => _ov.InvalidateVisual();          // live drag: repaint only
            _rv.OnGeometryCommitted = () => { _ov.InvalidateVisual(); Save(); }; // on release: persist
            _rv.ContextMenu = BuildRulerMenu();                            // right-click the ruler for controls + Quit
            _ruler.Content = _rv;
            _ruler.SourceInitialized += (s, e) => Native.SetClickThrough(_ruler, false); // keep off Alt-Tab; still interactive
            _ruler.Show();
        }

        void BuildOverlay()
        {
            _overlay = new Window
            {
                WindowStyle = WindowStyle.None,
                AllowsTransparency = true,
                Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)), // ~invisible but hit-testable in measure mode
                Topmost = true,
                ShowInTaskbar = false,
                ResizeMode = ResizeMode.NoResize,
                Left = SystemParameters.VirtualScreenLeft,
                Top = SystemParameters.VirtualScreenTop,
                Width = SystemParameters.VirtualScreenWidth,
                Height = SystemParameters.VirtualScreenHeight,
                Title = "Desktop Scale Ruler Overlay"
            };
            _ov = new OverlayElement { OverlayWin = _overlay, RulerWin = _ruler, Ruler = _rv, CursorScreen = Native.CursorScreen() };
            _ov.OnExitRequested = () => SetMode(0);
            _overlay.Content = _ov;
            _overlay.SourceInitialized += (s, e) => Native.SetClickThrough(_overlay, true); // click-through in ruler mode
            _overlay.KeyDown += (s, e) => _ov.HandleKey(e.Key);
            _overlay.Show();
        }

        // ---- right-click menu on the ruler (full controls incl. Quit) ----
        System.Windows.Controls.ContextMenu BuildRulerMenu()
        {
            var cm = new System.Windows.Controls.ContextMenu();
            void MI(string h, RoutedEventHandler act) { var i = new System.Windows.Controls.MenuItem { Header = h }; i.Click += act; cm.Items.Add(i); }
            void Sep() => cm.Items.Add(new System.Windows.Controls.Separator());
            MI("Calibrate to known dimension…", (s, e) => Calibrate());
            MI("Calibrate display (once)…", (s, e) => CalibrateDisplay());
            MI("Scale 1:100", (s, e) => SetNominal(100));
            MI("Scale 1:50", (s, e) => SetNominal(50));
            MI("Custom scale…", (s, e) => CustomScale());
            Sep();
            MI("Distance mode", (s, e) => SetMode(1));
            MI("Area mode", (s, e) => SetMode(2));
            MI("Count mode", (s, e) => SetMode(3));
            MI("Ruler mode", (s, e) => SetMode(0));
            Sep();
            MI("Takeoff list…", (s, e) => ShowTakeoff());
            MI("New takeoff set…", (s, e) => NewTakeoffSet());
            MI("Export takeoff CSV…", (s, e) => ExportCsv());
            Sep();
            MI("Rotate horizontal / vertical", (s, e) => ToggleOrientation());
            MI("Toggle mm / m", (s, e) => { Model.UseMetres = !Model.UseMetres; Model.Notify(); });
            MI("Copy measurement", (s, e) => CopyMeasurement());
            MI("Minimise", (s, e) => ToggleCollapse());
            Sep();
            MI("Quit Desktop Scale Ruler", (s, e) => Quit());
            return cm;
        }

        static Drawing.Icon LoadAppIcon()
        {
            try
            {
                var s = System.Reflection.Assembly.GetExecutingAssembly().GetManifestResourceStream("icon.ico");
                if (s != null) return new Drawing.Icon(s);
            }
            catch { }
            return Drawing.SystemIcons.Application;
        }

        // ---- tray menu ----
        void BuildTray()
        {
            _tray = new WForms.NotifyIcon { Icon = LoadAppIcon(), Visible = true, Text = "Desktop Scale Ruler — right-click for menu" };
            var m = new WForms.ContextMenuStrip();

            WForms.ToolStripMenuItem Item(string key, string text, EventHandler h)
            { var it = new WForms.ToolStripMenuItem(text, null, h); _menu[key] = it; m.Items.Add(it); return it; }

            Item("ruler", "Mode: Ruler", (s, e) => SetMode(0));
            Item("dist", "Mode: Distance (2 points)", (s, e) => SetMode(1));
            Item("area", "Mode: Area", (s, e) => SetMode(2));
            Item("count", "Mode: Count (tally)", (s, e) => SetMode(3));
            m.Items.Add(new WForms.ToolStripSeparator());
            Item("takeoff", "Show Takeoff List", (s, e) => ShowTakeoff());
            Item("newset", "New Takeoff Set…", (s, e) => NewTakeoffSet());
            Item("expcsv", "Export Takeoff CSV…", (s, e) => ExportCsv());
            m.Items.Add(new WForms.ToolStripSeparator());
            Item("calib", "Calibrate to Known Dimension…", (s, e) => Calibrate());
            Item("calibDisp", "Calibrate Display (once)…", (s, e) => CalibrateDisplay());
            Item("s100", "Scale 1:100", (s, e) => SetNominal(100));
            Item("s50", "Scale 1:50", (s, e) => SetNominal(50));
            Item("custom", "Custom Scale…", (s, e) => CustomScale());
            m.Items.Add(new WForms.ToolStripSeparator());
            Item("rotate", "Rotate Horizontal / Vertical", (s, e) => ToggleOrientation());
            Item("units", "Toggle mm / m", (s, e) => { Model.UseMetres = !Model.UseMetres; Model.Notify(); });
            Item("copy", "Copy Measurement", (s, e) => CopyMeasurement());
            Item("guide", "Cursor Guide", (s, e) => { Model.ShowGuide = !Model.ShowGuide; Model.Notify(); });
            Item("lead", "Lead Lines", (s, e) => { Model.ShowLeadLines = !Model.ShowLeadLines; Model.Notify(); });
            Item("min", "Minimise Ruler", (s, e) => ToggleCollapse());
            m.Items.Add(new WForms.ToolStripSeparator());
            Item("quit", "Quit", (s, e) => Quit());

            _tray.ContextMenuStrip = m;
        }

        void SyncMenu()
        {
            if (_menu.Count == 0) return;
            _menu["ruler"].Checked = Model.Mode == 0;
            _menu["dist"].Checked = Model.Mode == 1;
            _menu["area"].Checked = Model.Mode == 2;
            _menu["count"].Checked = Model.Mode == 3;
            _menu["guide"].Checked = Model.ShowGuide;
            _menu["lead"].Checked = Model.ShowLeadLines;
            _menu["units"].Checked = Model.UseMetres;
            _menu["min"].Text = _collapsed ? "Expand Ruler" : "Minimise Ruler";
        }

        // ---- prompt ----
        double? PromptForNumber(string title, string message, string placeholder)
        {
            var w = new Window { Title = title, Width = 400, Height = 180, WindowStartupLocation = WindowStartupLocation.CenterScreen, ResizeMode = ResizeMode.NoResize, Topmost = true };
            var panel = new System.Windows.Controls.StackPanel { Margin = new Thickness(14) };
            panel.Children.Add(new System.Windows.Controls.TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
            var tb = new System.Windows.Controls.TextBox();
            panel.Children.Add(tb);
            var row = new System.Windows.Controls.StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
            var ok = new System.Windows.Controls.Button { Content = "Set", Width = 70, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
            var cancel = new System.Windows.Controls.Button { Content = "Cancel", Width = 70, IsCancel = true };
            row.Children.Add(ok); row.Children.Add(cancel);
            panel.Children.Add(row);
            w.Content = panel;
            double? result = null;
            ok.Click += (s, e) =>
            {
                if (double.TryParse(tb.Text.Trim().Replace(',', '.'), NumberStyles.Any, CultureInfo.InvariantCulture, out var v) && v > 0)
                { result = v; w.DialogResult = true; }
            };
            w.ShowDialog();
            return result;
        }

        // ---- actions ----
        void Calibrate()
        {
            if (_collapsed) ToggleCollapse();
            double span = _rv.SpanUnits;
            if (span <= 0) return;
            var mm = PromptForNumber("Calibrate to a known dimension",
                "The ruler currently spans " + ((int)span) + " screen units. Enter the real-world length it covers, in millimetres.", "e.g. 3000");
            if (mm == null) return;
            Model.MmPerUnit = mm.Value / span;
            Model.ScaleRatio = Model.MmPerUnit / PhysMmPerUnit();
            Model.Calibrated = true;
            Model.Notify();
        }

        void CalibrateDisplay()
        {
            if (_collapsed) ToggleCollapse();
            double span = _rv.SpanUnits;
            if (span <= 0) return;
            var mm = PromptForNumber("Calibrate this display (once)",
                "Hold a ruler or card against the screen. Stretch the on-screen ruler to a known PHYSICAL length, then enter that length in mm (a credit card is 85.6 mm wide).", "e.g. 85.6");
            if (mm == null) return;
            Model.DisplayOverride = mm.Value / span;
            if (Model.Calibrated) Model.ScaleRatio = Model.MmPerUnit / PhysMmPerUnit();
            else SetNominal(Model.ScaleRatio);
            Model.Notify();
        }

        void SetNominal(double s)
        {
            Model.ScaleRatio = s;
            Model.MmPerUnit = s * PhysMmPerUnit();
            Model.Calibrated = false;
            Model.Notify();
        }

        void CustomScale()
        {
            var s = PromptForNumber("Custom scale", "Enter the plan scale ratio (the n in 1:n). Set for the viewer's actual size.", "e.g. 200");
            if (s != null) SetNominal(s.Value);
        }

        void ToggleOrientation()
        {
            if (_collapsed) return;
            double thickness = 56;
            if (!_rv.Vertical)
            {
                double newH = Math.Max(160, _ruler.Width);
                _ruler.Width = thickness; _ruler.Height = newH; _rv.Vertical = true;
            }
            else
            {
                double newW = Math.Max(160, _ruler.Height);
                _ruler.Height = thickness; _ruler.Width = newW; _rv.Vertical = false;
            }
            _rv.InvalidateVisual(); _ov.InvalidateVisual(); Save();
        }

        void ToggleCollapse()
        {
            double cw = 70, ch = 30;
            if (_collapsed)
            {
                _rv.Collapsed = false; _rv.Vertical = _savedVertical;
                _ruler.Left = _savedRect.X; _ruler.Top = _savedRect.Y; _ruler.Width = _savedRect.Width; _ruler.Height = _savedRect.Height;
                _collapsed = false;
            }
            else
            {
                _savedRect = new Rect(_ruler.Left, _ruler.Top, _ruler.Width, _ruler.Height);
                _savedVertical = _rv.Vertical;
                _rv.Collapsed = true;
                _ruler.Left = _savedRect.X; _ruler.Top = _savedRect.Y; _ruler.Width = cw; _ruler.Height = ch;
                _collapsed = true;
            }
            _rv.InvalidateVisual(); _ov.InvalidateVisual(); SyncMenu();
        }

        void SetMode(int mode)
        {
            Model.Mode = mode;
            bool interactive = mode != 0;
            Native.SetClickThrough(_overlay, !interactive);
            _ov.Pts.Clear(); _ov.AreaClosed = false; _ov.CountMarkers.Clear();
            if (interactive) { _overlay.Activate(); _overlay.Focus(); }
            SyncMenu(); _ov.InvalidateVisual();
        }

        void CopyMeasurement()
        {
            string text = "";
            if (Model.Mode == 0) text = Model.Formatted(_rv.SpanUnits) + " (" + Model.ScaleLabel + ")";
            else if (Model.Mode == 1) text = _ov.DistanceText() ?? "";
            else if (Model.Mode == 2) text = _ov.AreaText() ?? "";
            if (!string.IsNullOrEmpty(text)) { try { System.Windows.Clipboard.SetText(text); } catch { } }
        }

        // ---- takeoff ----
        void ShowTakeoff() { if (_takeoff == null) BuildTakeoffWindow(); RefreshTakeoff(); _takeoff.Show(); _takeoff.Activate(); }

        void NewTakeoffSet()
        {
            var name = PromptForString("New takeoff set", "Name this set (e.g. Ground floor walls, Footings, Slab). New measurements go into it.", "Set name");
            if (!string.IsNullOrWhiteSpace(name)) Takeoff.NewSet(name.Trim());
        }

        void UndoTakeoff() { Takeoff.UndoLast(); }

        void ClearTakeoff()
        {
            if (System.Windows.MessageBox.Show("Clear all takeoff items from every set? This can't be undone.",
                    "Clear takeoff", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
                Takeoff.ClearAll();
        }

        void ExportCsv()
        {
            var dlg = new Microsoft.Win32.SaveFileDialog { FileName = "takeoff.csv", Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*" };
            if (dlg.ShowDialog() == true) { try { System.IO.File.WriteAllText(dlg.FileName, Takeoff.Csv()); } catch { } }
        }

        void CopyTakeoff() { try { System.Windows.Clipboard.SetText(Takeoff.Csv()); } catch { } }

        void RefreshTakeoff()
        {
            if (_takeoffText == null) return;
            _takeoffHeader.Text = "Active set:  " + Takeoff.ActiveSet;
            _takeoffText.Text = Takeoff.SummaryText();
        }

        string PromptForString(string title, string message, string placeholder)
        {
            var w = new Window { Title = title, Width = 420, Height = 180, WindowStartupLocation = WindowStartupLocation.CenterScreen, ResizeMode = ResizeMode.NoResize, Topmost = true };
            var panel = new System.Windows.Controls.StackPanel { Margin = new Thickness(14) };
            panel.Children.Add(new System.Windows.Controls.TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
            var tb = new System.Windows.Controls.TextBox();
            panel.Children.Add(tb);
            var row = new System.Windows.Controls.StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
            var ok = new System.Windows.Controls.Button { Content = "OK", Width = 70, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
            var cancel = new System.Windows.Controls.Button { Content = "Cancel", Width = 70, IsCancel = true };
            row.Children.Add(ok); row.Children.Add(cancel);
            panel.Children.Add(row);
            w.Content = panel;
            string result = null;
            ok.Click += (s, e) => { result = tb.Text; w.DialogResult = true; };
            w.ShowDialog();
            return result;
        }

        void BuildTakeoffWindow()
        {
            _takeoff = new Window
            {
                Title = "Takeoff List", Width = 400, Height = 480,
                Topmost = true, ShowInTaskbar = false,
                WindowStartupLocation = WindowStartupLocation.CenterScreen
            };
            var dock = new System.Windows.Controls.DockPanel { Margin = new Thickness(12) };

            _takeoffHeader = new System.Windows.Controls.TextBlock { FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 8) };
            System.Windows.Controls.DockPanel.SetDock(_takeoffHeader, System.Windows.Controls.Dock.Top);
            dock.Children.Add(_takeoffHeader);

            var btnRow = new System.Windows.Controls.StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            System.Windows.Controls.DockPanel.SetDock(btnRow, System.Windows.Controls.Dock.Bottom);
            System.Windows.Controls.Button B(string t, RoutedEventHandler h) { var b = new System.Windows.Controls.Button { Content = t, Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(8, 3, 8, 3) }; b.Click += h; return b; }
            btnRow.Children.Add(B("New set…", (s, e) => NewTakeoffSet()));
            btnRow.Children.Add(B("Undo", (s, e) => UndoTakeoff()));
            btnRow.Children.Add(B("Clear", (s, e) => ClearTakeoff()));
            btnRow.Children.Add(B("Export CSV…", (s, e) => ExportCsv()));
            btnRow.Children.Add(B("Copy", (s, e) => CopyTakeoff()));
            dock.Children.Add(btnRow);

            _takeoffText = new System.Windows.Controls.TextBox
            {
                IsReadOnly = true,
                FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                FontSize = 12,
                VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto,
                TextWrapping = TextWrapping.NoWrap,
                AcceptsReturn = true,
                BorderThickness = new Thickness(1)
            };
            dock.Children.Add(_takeoffText);   // last child fills remaining space

            _takeoff.Content = dock;
        }

        void Save()
        {
            _s.MmPerUnit = Model.MmPerUnit; _s.HasScale = true;
            _s.ScaleRatio = Model.ScaleRatio; _s.UseMetres = Model.UseMetres;
            _s.ShowGuide = Model.ShowGuide; _s.ShowLeadLines = Model.ShowLeadLines;
            _s.Calibrated = Model.Calibrated; _s.DisplayOverride = Model.DisplayOverride;
            _s.Vertical = _rv.Vertical;
            var r = _collapsed ? _savedRect : new Rect(_ruler.Left, _ruler.Top, _ruler.Width, _ruler.Height);
            _s.Left = r.X; _s.Top = r.Y; _s.Width = r.Width; _s.Height = r.Height;
            _s.Save();
        }

        void Quit()
        {
            Save();
            _tray.Visible = false; _tray.Dispose();
            System.Windows.Application.Current.Shutdown();
        }
    }

    public static class Program
    {
        [STAThread]
        public static void Main()
        {
            var app = new System.Windows.Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            var controller = new AppController();
            app.Startup += (s, e) => controller.Start();
            app.Run();
        }
    }
}
