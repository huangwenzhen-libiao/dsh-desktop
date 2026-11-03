using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace DSHarness.Desktop
{
    /// <summary>集中维护桌面外框的深色配色，与 DSH 网页保持一致。</summary>
    internal static class DarkTheme
    {
        internal static readonly Color Background = Color.FromArgb(20, 20, 20);
        internal static readonly Color Chrome = Color.FromArgb(27, 27, 27);
        internal static readonly Color Text = Color.FromArgb(232, 234, 237);
        internal static readonly Color SecondaryText = Color.FromArgb(166, 171, 181);
        internal static readonly Color DisabledText = Color.FromArgb(108, 113, 123);
        internal static readonly Color Accent = Color.FromArgb(174, 200, 250);
        internal static readonly Color Border = Color.FromArgb(49, 49, 49);
        internal static readonly Color Hover = Color.FromArgb(47, 49, 54);
        internal static readonly Color Pressed = Color.FromArgb(59, 64, 73);

        // DWM 只设置当前应用窗口的外观，不修改 Windows 的全局主题。
        private const int UseImmersiveDarkMode = 20;
        private const int BorderColor = 34;
        private const int CaptionColor = 35;
        private const int CaptionTextColor = 36;

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

        /// <summary>为原生标题栏启用深色，保留系统的拖动、缩放和窗口按钮。</summary>
        internal static void ApplyTitleBar(IntPtr window)
        {
            var enabled = 1;
            DwmSetWindowAttribute(window, UseImmersiveDarkMode, ref enabled, sizeof(int));
            var caption = ColorTranslator.ToWin32(Chrome);
            var text = ColorTranslator.ToWin32(Text);
            var border = ColorTranslator.ToWin32(Border);
            // 自定义颜色由 Windows 11 支持，较旧系统继续使用已启用的深色标题栏。
            DwmSetWindowAttribute(window, CaptionColor, ref caption, sizeof(int));
            DwmSetWindowAttribute(window, CaptionTextColor, ref text, sizeof(int));
            DwmSetWindowAttribute(window, BorderColor, ref border, sizeof(int));
        }

        internal static void StyleButton(Button button)
        {
            button.FlatStyle = FlatStyle.Flat;
            button.BackColor = Color.FromArgb(39, 39, 42);
            button.ForeColor = Text;
            button.FlatAppearance.BorderColor = Color.FromArgb(70, 73, 80);
            button.FlatAppearance.MouseOverBackColor = Hover;
            button.FlatAppearance.MouseDownBackColor = Pressed;
            button.UseVisualStyleBackColor = false;
            button.Paint += (sender, args) =>
            {
                if (!button.Enabled)
                {
                    // 系统禁用按钮会画黑色文字，深色背景下改用明确的灰色文本。
                    var textBounds = Rectangle.Inflate(button.ClientRectangle, -2, -2);
                    TextRenderer.DrawText(args.Graphics, button.Text, button.Font, textBounds,
                        DisabledText, button.BackColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
                }
            };
        }

        /// <summary>用矢量线条绘制小尺寸操作图标，统一颜色并保持高 DPI 下的辨识度。</summary>
        internal static Bitmap CreateToolbarIcon(DesktopGlyph glyph)
        {
            var bitmap = new Bitmap(32, 32);
            using (var graphics = Graphics.FromImage(bitmap))
            using (var pen = new Pen(Accent, 1.6F) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
            using (var brush = new SolidBrush(Accent))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.ScaleTransform(1.6F, 1.6F);
                switch (glyph)
                {
                    case DesktopGlyph.Refresh:
                        graphics.DrawArc(pen, 4, 4, 12, 12, 40, 290);
                        graphics.DrawLines(pen, new[] { new PointF(13, 3), new PointF(16, 5), new PointF(13, 7) });
                        break;
                    case DesktopGlyph.Logs:
                        graphics.DrawLines(pen, new[] { new PointF(3, 7), new PointF(3, 4), new PointF(8, 4), new PointF(10, 7), new PointF(17, 7), new PointF(17, 16), new PointF(3, 16), new PointF(3, 7), new PointF(17, 7) });
                        break;
                    case DesktopGlyph.Tray:
                        graphics.DrawLine(pen, 10, 3, 10, 12);
                        graphics.DrawLines(pen, new[] { new PointF(6, 8), new PointF(10, 12), new PointF(14, 8) });
                        graphics.DrawLines(pen, new[] { new PointF(3, 12), new PointF(3, 16), new PointF(17, 16), new PointF(17, 12) });
                        break;
                    case DesktopGlyph.Menu:
                        graphics.FillEllipse(brush, 3, 9, 2.5F, 2.5F);
                        graphics.FillEllipse(brush, 8.75F, 9, 2.5F, 2.5F);
                        graphics.FillEllipse(brush, 14.5F, 9, 2.5F, 2.5F);
                        break;
                }
            }
            return bitmap;
        }
    }

    internal enum DesktopGlyph
    {
        Refresh,
        Logs,
        Tray,
        Menu
    }

    /// <summary>绘制工具栏、状态栏和弹出菜单的正常、悬停、按下及禁用状态，避免系统浅色渐变。</summary>
    internal sealed class DarkToolStripRenderer : ToolStripProfessionalRenderer
    {
        internal DarkToolStripRenderer()
        {
            RoundedEdges = false;
        }

        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs args)
        {
            args.Graphics.Clear(DarkTheme.Chrome);
        }

        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs args)
        {
            using (var pen = new Pen(DarkTheme.Border))
            {
                if (args.ToolStrip is ToolStripDropDown)
                {
                    args.Graphics.DrawRectangle(pen, 0, 0, args.ToolStrip.Width - 1, args.ToolStrip.Height - 1);
                }
                else
                {
                    var y = args.ToolStrip is StatusStrip ? 0 : args.ToolStrip.Height - 1;
                    args.Graphics.DrawLine(pen, 0, y, args.ToolStrip.Width, y);
                }
            }
        }

        protected override void OnRenderImageMargin(ToolStripRenderEventArgs args)
        {
            using (var brush = new SolidBrush(DarkTheme.Chrome))
            {
                args.Graphics.FillRectangle(brush, args.AffectedBounds);
            }
        }

        protected override void OnRenderButtonBackground(ToolStripItemRenderEventArgs args)
        {
            PaintItemBackground(args);
        }

        protected override void OnRenderDropDownButtonBackground(ToolStripItemRenderEventArgs args)
        {
            PaintItemBackground(args);
        }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs args)
        {
            PaintItemBackground(args);
        }

        private static void PaintItemBackground(ToolStripItemRenderEventArgs args)
        {
            var color = args.Item.Pressed ? DarkTheme.Pressed : args.Item.Selected ? DarkTheme.Hover : DarkTheme.Chrome;
            using (var brush = new SolidBrush(color))
            {
                args.Graphics.FillRectangle(brush, new Rectangle(Point.Empty, args.Item.Size));
            }
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs args)
        {
            args.TextColor = args.Item.Enabled ? args.Item.ForeColor : DarkTheme.DisabledText;
            base.OnRenderItemText(args);
        }

        protected override void OnRenderArrow(ToolStripArrowRenderEventArgs args)
        {
            args.ArrowColor = args.Item.Enabled ? DarkTheme.SecondaryText : DarkTheme.DisabledText;
            base.OnRenderArrow(args);
        }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs args)
        {
            using (var pen = new Pen(DarkTheme.Border))
            {
                var y = args.Item.Height / 2;
                args.Graphics.DrawLine(pen, 8, y, args.Item.Width - 8, y);
            }
        }

        protected override void OnRenderStatusStripSizingGrip(ToolStripRenderEventArgs args)
        {
            using (var brush = new SolidBrush(DarkTheme.SecondaryText))
            {
                for (var row = 0; row < 3; row++)
                {
                    for (var column = 0; column <= row; column++)
                    {
                        args.Graphics.FillRectangle(brush, args.ToolStrip.Width - 4 - column * 4, args.ToolStrip.Height - 12 + row * 4, 2, 2);
                    }
                }
            }
        }
    }
}
