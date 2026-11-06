# -*- coding: utf-8 -*-
# 桌面悬浮股价 · 支持自选添加
# 无边框 · 置顶 · 半透明 · 可拖动 · 可缩放（拖角 / 顶栏按钮）· 右键菜单

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# ---------- 声明 DPI 感知（避免字体被系统放大后挤出控件） ----------
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DpiFix {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@ -ErrorAction Stop
    [void][DpiFix]::SetProcessDPIAware()
} catch { }

# ---------- 单例 ----------
$script:Mutex = New-Object System.Threading.Mutex($false, "Global\FloatQuoteWidget_v1")
if (-not $script:Mutex.WaitOne(0)) { exit }

$Root      = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).ProviderPath }
$PosFile   = Join-Path $Root ".float_pos.json"
$WatchFile = Join-Path $Root ".float_watch.json"
$LogFile   = Join-Path $Root ".float_err.log"

function Write-Log([string]$msg) {
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format "MM-dd HH:mm:ss"), $msg
        Add-Content -Path $LogFile -Value $line -Encoding utf8
    } catch { }
}

# 捕获未处理异常，避免窗口静默消失
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        Write-Log ("UI异常: " + $e.Exception.ToString())
    })
    [System.AppDomain]::CurrentDomain.add_UnhandledException({
        param($s, $e)
        Write-Log ("域异常: " + $e.ExceptionObject.ToString())
    })
} catch { }

$script:Stocks     = @()
$script:State      = @{}
$script:Dragging   = $false
$script:DragCursor = $null
$script:DragForm   = $null
$script:ErrCount   = 0
$script:Scale      = 1.0
$script:Dpi        = 1.0
$script:Alpha      = 0.93
$script:RateMode   = "auto"
$script:RateMs     = 0
$script:AutoMs     = 1500
$script:Timer      = $null
$script:Theme      = "dark"
$script:UI         = @()
$script:Seps       = @()
$script:Empty      = @()
$script:Menus      = @()
$script:Resizing   = $false
$script:RsFrom     = 1.0
$script:RsY        = 0
$script:RsH        = 184
$script:DlgOut     = $null

$script:ScaleMin = 0.70
$script:ScaleMax = 1.80

# ---------- 主题 ----------
$Themes = @{
    dark = @{
        Bg    = [System.Drawing.Color]::FromArgb(22, 24, 29)
        Head  = [System.Drawing.Color]::FromArgb(38, 41, 49)
        Line  = [System.Drawing.Color]::FromArgb(58, 62, 72)
        Text  = [System.Drawing.Color]::FromArgb(233, 237, 243)
        Sub   = [System.Drawing.Color]::FromArgb(148, 156, 168)
        Up    = [System.Drawing.Color]::FromArgb(255, 88, 88)
        Down  = [System.Drawing.Color]::FromArgb(45, 208, 128)
        Flat  = [System.Drawing.Color]::FromArgb(200, 206, 216)
        Ok    = [System.Drawing.Color]::FromArgb(72, 222, 148)
        Pick  = [System.Drawing.Color]::FromArgb(14, 16, 20)
    }
    light = @{
        Bg    = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Head  = [System.Drawing.Color]::FromArgb(247, 248, 250)
        Line  = [System.Drawing.Color]::FromArgb(228, 231, 235)
        Text  = [System.Drawing.Color]::FromArgb(31, 35, 40)
        Sub   = [System.Drawing.Color]::FromArgb(122, 128, 136)
        Up    = [System.Drawing.Color]::FromArgb(214, 48, 36)
        Down  = [System.Drawing.Color]::FromArgb(12, 150, 84)
        Flat  = [System.Drawing.Color]::FromArgb(31, 35, 40)
        Ok    = [System.Drawing.Color]::FromArgb(8, 122, 64)
        Pick  = [System.Drawing.Color]::FromArgb(211, 220, 234)
    }
}

$script:C = $Themes[$script:Theme]

# ---------- 字体（按缩放缓存） ----------
$script:FontCache = @{}

function Get-Font([double]$size, [string]$style) {
    $sz = [math]::Round($size * 2) / 2
    if ($sz -lt 5) { $sz = 5 }
    $key = "$sz|$style"
    if (-not $script:FontCache.ContainsKey($key)) {
        if ($style -eq 'bold') {
            $script:FontCache[$key] = New-Object System.Drawing.Font("Microsoft YaHei UI", $sz, [System.Drawing.FontStyle]::Bold)
        } else {
            $script:FontCache[$key] = New-Object System.Drawing.Font("Microsoft YaHei UI", $sz)
        }
    }
    return $script:FontCache[$key]
}

# 顶栏专用字体：不跟着缩放到过小，缩到 70% 时仍保证 ≥7pt 可读
function Get-HeadFont([double]$factor) {
    $sz = $factor * $script:Scale
    if ($sz -lt 7.0) { $sz = 7.0 }
    return (Get-Font $sz 'normal')
}

# ---------- 缩放下标（用户缩放 × 系统 DPI） ----------
function Px([double]$v) {
    $r = [int][math]::Round($v * $script:Scale * $script:Dpi)
    if ($r -lt 1) { $r = 1 }
    return $r
}

# ---------- 窗体内缩放下标（只跟 DPI 走） ----------
function Pd([double]$v) {
    $r = [int][math]::Round($v * $script:Dpi)
    if ($r -lt 1) { $r = 1 }
    return $r
}

# ---------- 双缓冲（自定义绘制的控件开双缓冲，强制重绘时不闪） ----------
function Set-DoubleBuffered($ctrl) {
    try {
        $pi = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
        if ($null -ne $pi) { $pi.SetValue($ctrl, $true) }
    } catch { }
}

# ---------- 窗体 ----------
$form = New-Object System.Windows.Forms.Form
$form.AutoScaleMode   = [System.Windows.Forms.AutoScaleMode]::None
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
$form.TopMost         = $true
# 必须为 true：ShowInTaskbar=false 时窗口最小化后会彻底消失、任务栏也点不回来
$form.ShowInTaskbar   = $true
$form.BackColor       = $script:C.Bg
$form.ClientSize      = [System.Drawing.Size]::new(320, 184)
$form.Opacity         = $script:Alpha
$form.Text            = "悬浮股价"
$form.KeyPreview      = $true
Set-DoubleBuffered $form
$script:Form = $form

# 取真实 DPI
try {
    $gfx = $form.CreateGraphics()
    $dx  = [double]$gfx.DpiX
    $gfx.Dispose()
    if ($dx -ge 96) { $script:Dpi = [math]::Round($dx / 96.0, 2) }
} catch { $script:Dpi = 1.0 }

# ---------- 顶栏 ----------
$header = New-Object System.Windows.Forms.Panel
$header.BackColor = $script:C.Head
Set-DoubleBuffered $header
$form.Controls.Add($header)

# 普通扁平按钮（供输入对话框使用，尺寸较大，不存在裁字问题）
function New-HeadBtn([string]$text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $text
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 1
    $b.UseVisualStyleBackColor = $false
    $b.TabStop   = $false
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    return $b
}

# 顶栏文字按钮：全部自绘。Button 自带的文字排版会带上字体的行间距，
# 小尺寸（缩放 85% 以下）时行高超过按钮高度，字被从上往下裁掉半截。
function New-ModeBtn([string]$text) {
    $b = New-Object System.Windows.Forms.Panel
    $b.BackColor = $script:C.Head
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $b.Tag       = @{ Text = $text; On = $false; Hover = $false }
    Set-DoubleBuffered $b
    $b.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $t  = $script:C
        $st = $s.Tag
        $w  = [int]$s.Width
        $h  = [int]$s.Height
        if ($w -le 0 -or $h -le 0) { return }
        $bg = if ($st.On -or $st.Hover) { $t.Pick } else { $t.Head }
        $fg = if ($st.On) { $t.Text } else { $t.Sub }
        $bc = if ($st.On) { $t.Text } else { $t.Line }
        $g.Clear($bg)
        $pen = New-Object System.Drawing.Pen($bc, 1)
        $g.DrawRectangle($pen, 0, 0, ($w - 1), ($h - 1))
        $pen.Dispose()
        $font = Get-HeadFont 8
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment     = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $sf.FormatFlags   = [System.Drawing.StringFormatFlags]::NoWrap
        $br = New-Object System.Drawing.SolidBrush($fg)
        $rect = [System.Drawing.RectangleF]::new([single]0, [single]0, [single]$w, [single]$h)
        $g.DrawString([string]$st.Text, $font, $br, $rect, $sf)
        $br.Dispose()
        $sf.Dispose()
    })
    $b.Add_MouseEnter({ $this.Tag.Hover = $true;  $this.Invalidate() })
    $b.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Invalidate() })
    return $b
}

$btnDarkMode  = New-ModeBtn "深色"
$btnLightMode = New-ModeBtn "浅色"
$header.Controls.Add($btnDarkMode)
$header.Controls.Add($btnLightMode)

# 更新时间
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text      = "连接中…"
$lblStatus.BackColor = $script:C.Head
$lblStatus.ForeColor = $script:C.Sub
$lblStatus.AutoSize  = $false
$lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$header.Controls.Add($lblStatus)

# 最小化按钮：和浏览器右上角那个一样，一条横线，点了收进任务栏
function New-MinBtn {
    $b = New-Object System.Windows.Forms.Panel
    $b.BackColor = $script:C.Head
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    Set-DoubleBuffered $b
    $b.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $w  = [single]$s.Width
        $h  = [single]$s.Height
        $half = [single][math]::Round($w * 0.19, 1)
        $cy = [single][math]::Round($h / 2.0, 1)
        $lw = [single][math]::Max(1.0, [math]::Round($h * 0.045, 1))
        $pen = New-Object System.Drawing.Pen($script:C.Sub, $lw)
        $g.DrawLine($pen, [single]($w / 2.0 - $half), $cy, [single]($w / 2.0 + $half), $cy)
        $pen.Dispose()
    })
    $b.Add_MouseEnter({ $this.BackColor = $script:C.Pick; $this.Invalidate() })
    $b.Add_MouseLeave({ $this.BackColor = $script:C.Head; $this.Invalidate() })
    return $b
}

$btnMin = New-MinBtn
$header.Controls.Add($btnMin)

# 关闭
$btnClose = New-Object System.Windows.Forms.Label
$btnClose.Text      = "×"
$btnClose.BackColor = $script:C.Head
$btnClose.ForeColor = $script:C.Sub
$btnClose.AutoSize  = $false
$btnClose.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$btnClose.Cursor    = [System.Windows.Forms.Cursors]::Hand
$header.Controls.Add($btnClose)

# ---------- 主体 ----------
$body = New-Object System.Windows.Forms.Panel
$body.BackColor = $script:C.Bg
Set-DoubleBuffered $body
$form.Controls.Add($body)

# ---------- 缩放手柄 ----------
$grip = New-Object System.Windows.Forms.Panel
$grip.BackColor = $script:C.Bg
$grip.Cursor    = [System.Windows.Forms.Cursors]::SizeNWSE
Set-DoubleBuffered $grip
$grip.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $pen = New-Object System.Drawing.Pen($script:C.Sub, 1)
    $w = $s.Width; $h = $s.Height
    for ($k = 0; $k -lt 3; $k++) {
        $off = $k * 4 + 3
        $g.DrawLine($pen, ($w - $off), ($h - 1), ($w - 1), ($h - $off))
    }
    $pen.Dispose()
})
$form.Controls.Add($grip)

# ================= 功能函数 =================

# ---------- 代码规范化 ----------
function Normalize-Code([string]$raw) {
    if (-not $raw) { return $null }
    $s = $raw.Trim().ToLower()
    if ($s -match '^(sh|sz|bj)(\d{6})$') { return ($matches[1] + $matches[2]) }
    if ($s -match '^(\d{6})$') {
        $c = $matches[1]
        if ($c -match '^[659]') { return "sh$c" }
        if ($c -match '^[013]') { return "sz$c" }
        if ($c -match '^[48]')  { return "bj$c" }
        return "sh$c"
    }
    return $null
}

# ---------- 请求行情 ----------
function Request-Quotes([string]$codes) {
    $out = @{}
    if (-not $codes) { return $out }
    $url = "http://qt.gtimg.cn/q=$codes"
    $txt = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        $req.Timeout = 2500
        $req.ReadWriteTimeout = 2500
        $req.KeepAlive = $false
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::GetEncoding(936))
        $txt = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
    } catch {
        return $out
    }

    foreach ($line in ($txt -split "`n")) {
        if ($line -match 'v_([A-Za-z0-9_]+)="([^"]*)"') {
            $code  = $matches[1]
            $parts = $matches[2] -split "~"
            if ($parts.Count -lt 6) { continue }
            $price = 0.0; $prev = 0.0; $open = 0.0
            $hi = 0.0; $lo = 0.0
            [double]::TryParse($parts[3], [ref]$price) | Out-Null
            [double]::TryParse($parts[4], [ref]$prev)  | Out-Null
            [double]::TryParse($parts[5], [ref]$open)  | Out-Null
            if ($parts.Count -gt 34) {
                [double]::TryParse($parts[33], [ref]$hi) | Out-Null
                [double]::TryParse($parts[34], [ref]$lo) | Out-Null
            }
            $ts = ""
            if ($parts.Count -gt 30) { $ts = [string]$parts[30] }
            if ($ts -notmatch '^\d{14}$') { $ts = "" }
            $out[$code] = [pscustomobject]@{
                Name  = $parts[1]
                Price = $price
                Prev  = $prev
                Open  = $open
                High  = $hi
                Low   = $lo
                Time  = $ts
            }
        }
    }
    return $out
}

# ---------- 自选持久化 ----------
function Save-Watch {
    try {
        $arr = @()
        foreach ($s in $script:Stocks) {
            $arr += @{ Code = [string]$s.Code }
        }
        ConvertTo-Json -InputObject $arr -Compress -Depth 4 | Out-File -FilePath $WatchFile -Encoding utf8 -Force
    } catch { }
}

function Load-Watch {
    $list = @()
    if (Test-Path $WatchFile) {
        try {
            $raw = Get-Content $WatchFile -Raw | ConvertFrom-Json
            foreach ($it in @($raw)) {
                if (-not $it) { continue }
                $cd = [string]$it.Code
                if ($cd -match '^(sh|sz|bj)\d{6}$') {
                    $list += @{ Code = $cd }
                }
            }
        } catch { }
    }
    # 不内置任何默认自选：第一次打开就是空白卡片，让使用者添加自己的股票
    return $list
}

# ---------- 输入对话框 ----------
function Show-InputDialog {
    param(
        [string]$Title,
        [string]$Hint,
        [string]$Default = "",
        [string]$OkText  = "确定",
        [scriptblock]$Validator = $null
    )
    $t  = $script:C
    $script:DlgOut = $null

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $dlg.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dlg.TopMost         = $true
    $dlg.ShowInTaskbar   = $false
    $dlg.BackColor       = $t.Bg
    $dlg.ClientSize      = [System.Drawing.Size]::new((Pd 360), (Pd 176))
    $dlg.KeyPreview      = $true
    $dlg.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen($script:C.Line, 1)
        $e.Graphics.DrawRectangle($pen, 0, 0, ($s.Width - 1), ($s.Height - 1))
        $pen.Dispose()
    })

    $lblT = New-Object System.Windows.Forms.Label
    $lblT.Text      = $Title
    $lblT.AutoSize  = $false
    $lblT.BackColor = $t.Bg
    $lblT.ForeColor = $t.Text
    $lblT.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblT.Font      = Get-Font (10.5 * $script:Dpi) 'bold'
    $lblT.Location  = [System.Drawing.Point]::new((Pd 18), (Pd 12))
    $lblT.Size      = [System.Drawing.Size]::new((Pd 300), (Pd 22))
    $dlg.Controls.Add($lblT)

    $lblH = New-Object System.Windows.Forms.Label
    $lblH.Text      = $Hint
    $lblH.AutoSize  = $false
    $lblH.BackColor = $t.Bg
    $lblH.ForeColor = $t.Sub
    $lblH.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $lblH.Font      = Get-Font (8.5 * $script:Dpi) 'normal'
    $lblH.Location  = [System.Drawing.Point]::new((Pd 18), (Pd 38))
    $lblH.Size      = [System.Drawing.Size]::new((Pd 324), (Pd 34))
    $dlg.Controls.Add($lblH)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text        = $Default
    $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $tb.BackColor   = $t.Pick
    $tb.ForeColor   = $t.Text
    $tb.Font        = Get-Font (10.5 * $script:Dpi) 'normal'
    $tb.Location    = [System.Drawing.Point]::new((Pd 18), (Pd 74))
    $tb.Size        = [System.Drawing.Size]::new((Pd 324), (Pd 26))
    $dlg.Controls.Add($tb)

    $lblE = New-Object System.Windows.Forms.Label
    $lblE.Text      = ""
    $lblE.AutoSize  = $false
    $lblE.BackColor = $t.Bg
    $lblE.ForeColor = $t.Up
    $lblE.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lblE.Font      = Get-Font (8.5 * $script:Dpi) 'normal'
    $lblE.Location  = [System.Drawing.Point]::new((Pd 18), (Pd 103))
    $lblE.Size      = [System.Drawing.Size]::new((Pd 324), (Pd 18))
    $dlg.Controls.Add($lblE)

    $btnOk = New-HeadBtn $OkText
    $btnOk.BackColor = $t.Pick
    $btnOk.ForeColor = $t.Text
    $btnOk.FlatAppearance.BorderColor = $t.Line
    $btnOk.FlatAppearance.MouseOverBackColor = $t.Pick
    $btnOk.Font      = Get-Font (9.5 * $script:Dpi) 'normal'
    $btnOk.Location  = [System.Drawing.Point]::new(((Pd 360) - (Pd 18) - (Pd 74)), (Pd 128))
    $btnOk.Size      = [System.Drawing.Size]::new((Pd 74), (Pd 28))
    $dlg.Controls.Add($btnOk)

    $btnNo = New-HeadBtn "取消"
    $btnNo.BackColor = $t.Bg
    $btnNo.ForeColor = $t.Sub
    $btnNo.FlatAppearance.BorderColor = $t.Line
    $btnNo.FlatAppearance.MouseOverBackColor = $t.Pick
    $btnNo.Font      = Get-Font (9.5 * $script:Dpi) 'normal'
    $btnNo.Location  = [System.Drawing.Point]::new(((Pd 360) - (Pd 18) - (Pd 74) - (Pd 8) - (Pd 66)), (Pd 128))
    $btnNo.Size      = [System.Drawing.Size]::new((Pd 66), (Pd 28))
    $btnNo.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnNo)
    $dlg.CancelButton = $btnNo
    $dlg.AcceptButton = $btnOk

    $btnOk.Add_Click({
        $txt = $tb.Text.Trim()
        if ($txt -eq "") { $lblE.Text = "请输入内容"; return }
        if ($null -ne $Validator) {
            $res = & $Validator $txt
            if (-not $res.Ok) { $lblE.Text = $res.Msg; return }
            $script:DlgOut = $res
        } else {
            $script:DlgOut = @{ Ok = $true; Text = $txt }
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
    })

    $tb.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel }
    })

    $dlg.Add_Shown({
        $tb.Focus()
        $tb.SelectAll()
    })

    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
    return $script:DlgOut
}

# ---------- 加自选 ----------
function Add-Stock {
    $hint = "6 位代码，如 600519；也可写 sh600519 / sz000001 / bj430047"
    $val = {
        param($txt)
        $p  = @($txt -split '\s+')
        $cd = Normalize-Code $p[0]
        if (-not $cd) { return @{ Ok = $false; Msg = "代码格式不对，应为 6 位数字" } }
        foreach ($s in $script:Stocks) {
            if ($s.Code -eq $cd) { return @{ Ok = $false; Msg = "这只已经在盯盘列表里了" } }
        }
        $q = Request-Quotes $cd
        if (-not $q.ContainsKey($cd)) { return @{ Ok = $false; Msg = "查不到，检查代码或网络" } }
        if ([string]::IsNullOrWhiteSpace($q[$cd].Name)) { return @{ Ok = $false; Msg = "查不到这个代码" } }
        return @{ Ok = $true; Code = $cd }
    }

    $res = Show-InputDialog -Title "添加自选" -Hint $hint -Default "" -OkText "添加" -Validator $val
    if ($null -eq $res) { return }

    $script:Stocks = @($script:Stocks) + @(@{ Code = $res.Code })
    Save-Watch
    Build-Rows
    Layout-UI
    Clamp-Bounds
    Fetch-Quotes -Force
}

# ---------- 移除 ----------
function Remove-Stock([string]$code) {
    $script:Stocks = @($script:Stocks | Where-Object { $_.Code -ne $code })
    Save-Watch
    Build-Rows
    Layout-UI
    Clamp-Bounds
    Fetch-Quotes -Force
}

# ---------- 右键菜单 ----------
function New-Menu([string]$code) {
    $m = New-Object System.Windows.Forms.ContextMenuStrip

    if ($code) {
        $miDel = [System.Windows.Forms.ToolStripMenuItem]::new("移除该股")
        $miDel.Tag = $code
        $miDel.Add_Click({ Remove-Stock $this.Tag })
        [void]$m.Items.Add($miDel)

        [void]$m.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    }

    $miAdd = [System.Windows.Forms.ToolStripMenuItem]::new("添加自选…")
    $miAdd.Add_Click({ Add-Stock })
    [void]$m.Items.Add($miAdd)

    $miTop = [System.Windows.Forms.ToolStripMenuItem]::new("取消置顶")
    $miTop.Add_Click({
        $script:Form.TopMost = -not $script:Form.TopMost
        if ($script:Form.TopMost) { $this.Text = "取消置顶" } else { $this.Text = "窗口置顶" }
    })
    [void]$m.Items.Add($miTop)

    $miSize = [System.Windows.Forms.ToolStripMenuItem]::new("大小")
    $miSize.ShowCheckMargin = $true
    foreach ($v in @(70, 85, 100, 115, 130, 150, 180)) {
        $it = [System.Windows.Forms.ToolStripMenuItem]::new("$v%")
        $it.Tag = $v
        $it.CheckOnClick = $false
        $it.ShowCheckMargin = $true
        $it.Add_Click({
            $script:Scale = [double]$this.Tag / 100.0
            Layout-UI
            Clamp-Bounds
            Save-Pos
        })
        [void]$miSize.DropDown.Items.Add($it)
    }
    [void]$m.Items.Add($miSize)

    $miAlpha = [System.Windows.Forms.ToolStripMenuItem]::new("透明度")
    $miAlpha.ShowCheckMargin = $true
    foreach ($v in @(100, 93, 86, 75, 62, 48)) {
        $it = [System.Windows.Forms.ToolStripMenuItem]::new("$v%")
        $it.Tag = $v
        $it.CheckOnClick = $false
        $it.ShowCheckMargin = $true
        $it.Add_Click({
            $script:Alpha = [double]$this.Tag / 100.0
            $script:Form.Opacity = $script:Alpha
            Save-Pos
        })
        [void]$miAlpha.DropDown.Items.Add($it)
    }
    [void]$m.Items.Add($miAlpha)

    $miRate = [System.Windows.Forms.ToolStripMenuItem]::new("刷新频率")
    $miRate.ShowCheckMargin = $true
    $rates = @(
        @{ T = "自动（盘中 1 秒）"; V = "auto" },
        @{ T = "1 秒（极速）";      V = 1000 },
        @{ T = "2 秒";              V = 2000 },
        @{ T = "5 秒";              V = 5000 },
        @{ T = "暂停刷新";          V = 0 }
    )
    foreach ($rr in $rates) {
        $it = [System.Windows.Forms.ToolStripMenuItem]::new($rr.T)
        $it.Tag = $rr.V
        $it.CheckOnClick = $false
        $it.ShowCheckMargin = $true
        $it.Add_Click({
            if ([string]$this.Tag -eq "auto") { $script:RateMode = "auto"; $script:RateMs = 0 }
            else { $script:RateMode = "manual"; $script:RateMs = [int]$this.Tag }
            Apply-Rate
            Save-Pos
        })
        [void]$miRate.DropDown.Items.Add($it)
    }
    [void]$m.Items.Add($miRate)

    $m.Add_Opening({
        $curScale = [int][Math]::Round($script:Scale * 100)
        $curAlpha = [int][Math]::Round($script:Alpha * 100)
        foreach ($x in $this.Items) {
            if ($x.Text -eq "大小") {
                foreach ($cc in $x.DropDown.Items) { $cc.Checked = ([int]$cc.Tag -eq $curScale) }
            }
            elseif ($x.Text -eq "透明度") {
                foreach ($cc in $x.DropDown.Items) { $cc.Checked = ([int]$cc.Tag -eq $curAlpha) }
            }
            elseif ($x.Text -eq "刷新频率") {
                foreach ($cc in $x.DropDown.Items) {
                    if ([string]$cc.Tag -eq "auto") { $cc.Checked = ($script:RateMode -eq "auto") }
                    else { $cc.Checked = ($script:RateMode -eq "manual" -and [int]$cc.Tag -eq $script:RateMs) }
                }
            }
        }
    })

    $miRefresh = [System.Windows.Forms.ToolStripMenuItem]::new("立即刷新")
    $miRefresh.Add_Click({ Fetch-Quotes -Force })
    [void]$m.Items.Add($miRefresh)

    [void]$m.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())

    $miExit = [System.Windows.Forms.ToolStripMenuItem]::new("退出")
    $miExit.Add_Click({ $timer.Stop(); $script:Form.Close() })
    [void]$m.Items.Add($miExit)

    $script:Menus += $m
    return $m
}

# ---------- 拖动 ----------
function Bind-Drag($ctrl) {
    $ctrl.Add_MouseDown({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $script:Dragging   = $true
            $script:DragCursor = [System.Windows.Forms.Cursor]::Position
            $script:DragForm   = $script:Form.Location
        }
    })
    $ctrl.Add_MouseMove({
        param($s, $e)
        if ($script:Dragging) {
            $cur = [System.Windows.Forms.Cursor]::Position
            $nx = $script:DragForm.X + ($cur.X - $script:DragCursor.X)
            $ny = $script:DragForm.Y + ($cur.Y - $script:DragCursor.Y)
            $script:Form.Location = [System.Drawing.Point]::new($nx, $ny)
        }
    })
    $ctrl.Add_MouseUp({
        param($s, $e)
        if ($script:Dragging) {
            $script:Dragging = $false
            Save-Pos
        }
    })
}

# ---------- 重建行 ----------
function Build-Rows {
    foreach ($u in $script:UI) {
        foreach ($k in @("Name", "Pct", "Price", "Delta", "Info")) { $u.$k.Dispose() }
    }
    foreach ($sp in $script:Seps) { $sp.Dispose() }
    foreach ($em in $script:Empty) { $em.Dispose() }
    $script:UI    = @()
    $script:Seps  = @()
    $script:Empty = @()

    $c = $script:C
    for ($i = 0; $i -lt $script:Stocks.Count; $i++) {
        $code = $script:Stocks[$i].Code

        $ln = New-Object System.Windows.Forms.Label
        $ln.BackColor = $c.Bg; $ln.ForeColor = $c.Text
        $ln.AutoSize  = $false
        $ln.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $ln.Text      = ""
        $body.Controls.Add($ln)

        $lp = New-Object System.Windows.Forms.Label
        $lp.BackColor = $c.Bg; $lp.ForeColor = $c.Sub
        $lp.AutoSize  = $false
        $lp.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
        $lp.Text      = ""
        $body.Controls.Add($lp)

        $lpr = New-Object System.Windows.Forms.Label
        $lpr.BackColor = $c.Bg; $lpr.ForeColor = $c.Sub
        $lpr.AutoSize  = $false
        $lpr.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $lpr.Text      = "--"
        $body.Controls.Add($lpr)

        $ld = New-Object System.Windows.Forms.Label
        $ld.BackColor = $c.Bg; $ld.ForeColor = $c.Sub
        $ld.AutoSize  = $false
        $ld.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
        $ld.Text      = ""
        $body.Controls.Add($ld)

        $li = New-Object System.Windows.Forms.Label
        $li.BackColor = $c.Bg; $li.ForeColor = $c.Sub
        $li.AutoSize  = $false
        $li.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $li.Text      = ""
        $body.Controls.Add($li)

        if ($i -lt ($script:Stocks.Count - 1)) {
            $sep = New-Object System.Windows.Forms.Panel
            $sep.BackColor = $c.Line
            $body.Controls.Add($sep)
            $script:Seps += $sep
        }

        $menu = New-Menu $code
        $row  = [pscustomobject]@{ Name = $ln; Pct = $lp; Price = $lpr; Delta = $ld; Info = $li }
        foreach ($k in @("Name", "Pct", "Price", "Delta", "Info")) {
            $ctl = $row.$k
            $ctl.ContextMenuStrip = $menu
            Bind-Drag $ctl
        }
        $script:UI += $row
    }

    # 空态：列表被清空后不要塌成一条细条，给一句明确的提示，且点一下就能加
    if ($script:Stocks.Count -eq 0) {
        $e1 = New-Object System.Windows.Forms.Label
        $e1.BackColor = $c.Bg; $e1.ForeColor = $c.Text
        $e1.AutoSize  = $false
        $e1.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $e1.Text      = "还没有自选股"
        $e1.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $body.Controls.Add($e1)

        $e2 = New-Object System.Windows.Forms.Label
        $e2.BackColor = $c.Bg; $e2.ForeColor = $c.Sub
        $e2.AutoSize  = $false
        $e2.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $e2.Text      = "点这里添加 · 或右键菜单"
        $e2.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $body.Controls.Add($e2)

        foreach ($em in @($e1, $e2)) {
            $em.ContextMenuStrip = $script:Form.ContextMenuStrip
            $em.Add_Click({ Add-Stock })
            Bind-Drag $em
        }
        $script:Empty = @($e1, $e2)
    }
}

# ---------- 布局 ----------
function Layout-UI {
    $s = $script:Scale

    # 顶栏高度设下限：缩放到 70% 时仍留得出 7pt 字的位置，不会把字挤掉
    $W     = Px 320
    $HH    = [math]::Max((Px 29), 24)
    $blkH  = Px 74
    $BodyH = (Px 10) + ($script:Stocks.Count * $blkH)
    # 空态给一个固定高度，否则窗口会塌成只剩顶栏的一条细缝
    if ($script:Stocks.Count -eq 0) { $BodyH = Px 64 }
    $H     = $HH + $BodyH

    $form.ClientSize = [System.Drawing.Size]::new($W, $H)

    $header.Location = [System.Drawing.Point]::new(0, 0)
    $header.Size     = [System.Drawing.Size]::new($W, $HH)

    $btnH = [math]::Max((Px 22), 18)
    $by   = [int](($HH - $btnH) / 2)
    $x    = Px 7

    $btnDarkMode.Location = [System.Drawing.Point]::new($x, $by)
    $btnDarkMode.Size     = [System.Drawing.Size]::new((Px 52), $btnH)
    $x += $btnDarkMode.Width + (Px 5)

    $btnLightMode.Location = [System.Drawing.Point]::new($x, $by)
    $btnLightMode.Size     = [System.Drawing.Size]::new((Px 52), $btnH)
    $x += $btnLightMode.Width + (Px 5)

    $cw = Px 26
    $btnClose.Location = [System.Drawing.Point]::new(($W - $cw), 0)
    $btnClose.Size     = [System.Drawing.Size]::new($cw, $HH)
    $btnClose.Font     = Get-Font (11 * $s) 'normal'

    # 右侧依次：状态 → 最小化 → 关闭
    $sw = Px 70
    $xMin = $W - $cw - $cw
    $xStatus = $xMin - (Px 6) - $sw

    $btnMin.Location = [System.Drawing.Point]::new($xMin, 0)
    $btnMin.Size     = [System.Drawing.Size]::new($cw, $HH)

    $lblStatus.Location = [System.Drawing.Point]::new($xStatus, 0)
    $lblStatus.Size     = [System.Drawing.Size]::new($sw, $HH)
    $lblStatus.Font     = Get-HeadFont 8

    $body.Location = [System.Drawing.Point]::new(0, $HH)
    $body.Size     = [System.Drawing.Size]::new($W, $BodyH)

    $fName  = Get-Font (9 * $s) 'normal'
    $fPct   = Get-Font (9.5 * $s) 'bold'
    $fPrice = Get-Font (17 * $s) 'bold'
    $fDelta = Get-Font (9 * $s) 'normal'
    $fInfo  = Get-Font (7.5 * $s) 'normal'

    $right = $W - (Px 12)

    for ($i = 0; $i -lt $script:Stocks.Count; $i++) {
        $u   = $script:UI[$i]
        $top = (Px 8) + ($i * $blkH)

        $u.Name.Font  = $fName
        $u.Name.Location = [System.Drawing.Point]::new((Px 12), $top)
        $u.Name.Size     = [System.Drawing.Size]::new((Px 178), (Px 18))

        $u.Pct.Font  = $fPct
        $u.Pct.Location = [System.Drawing.Point]::new(($right - (Px 116)), ($top - (Px 1)))
        $u.Pct.Size     = [System.Drawing.Size]::new((Px 116), (Px 19))

        $u.Price.Font  = $fPrice
        $u.Price.Location = [System.Drawing.Point]::new((Px 10), ($top + (Px 15)))
        $u.Price.Size     = [System.Drawing.Size]::new((Px 160), (Px 32))

        $u.Delta.Font  = $fDelta
        $u.Delta.Location = [System.Drawing.Point]::new(($right - (Px 128)), ($top + (Px 26)))
        $u.Delta.Size     = [System.Drawing.Size]::new((Px 128), (Px 17))

        $u.Info.Font  = $fInfo
        $u.Info.Location = [System.Drawing.Point]::new((Px 12), ($top + (Px 50)))
        $u.Info.Size     = [System.Drawing.Size]::new(($W - (Px 24)), (Px 15))

        if ($i -lt $script:Seps.Count) {
            $script:Seps[$i].Location = [System.Drawing.Point]::new((Px 12), (($top + $blkH) - (Px 8)))
            $script:Seps[$i].Size     = [System.Drawing.Size]::new(($W - (Px 24)), 1)
        }
    }

    if ($script:Empty.Count -ge 2) {
        $script:Empty[0].Font     = Get-Font (10 * $s) 'bold'
        $script:Empty[0].Location = [System.Drawing.Point]::new(0, (Px 14))
        $script:Empty[0].Size     = [System.Drawing.Size]::new($W, (Px 20))
        $script:Empty[1].Font     = Get-Font (8 * $s) 'normal'
        $script:Empty[1].Location = [System.Drawing.Point]::new(0, (Px 36))
        $script:Empty[1].Size     = [System.Drawing.Size]::new($W, (Px 18))
    }

    $gw = Px 15
    $grip.Location = [System.Drawing.Point]::new(($W - $gw), ($H - $gw))
    $grip.Size     = [System.Drawing.Size]::new($gw, $gw)
    $grip.BringToFront()

    # 拖动缩放时鼠标移动会把 WM_PAINT 饿死在消息队列里，顶栏按钮会停在旧尺寸，
    # 必须在这里强制同步重绘一次，按钮才不会“等鼠标移上去才恢复”。
    $form.Invalidate($true)
    $form.Update()
}

# ---------- 主题按钮 ----------
function Update-ModeButtons {
    $isDark = ($script:Theme -eq "dark")
    foreach ($pair in @(@{ B = $btnDarkMode; On = $isDark }, @{ B = $btnLightMode; On = (-not $isDark) })) {
        $pair.B.Tag.On    = $pair.On
        $pair.B.BackColor = $script:C.Head
        $pair.B.Invalidate()
    }
}

$script:Tip = New-Object System.Windows.Forms.ToolTip
$script:Tip.SetToolTip($btnDarkMode, "深色模式")
$script:Tip.SetToolTip($btnLightMode, "浅色模式")

function Set-Theme([string]$name) {
    if (-not $Themes.ContainsKey($name)) { return }
    $script:Theme = $name
    $t = $Themes[$name]
    $script:C = $t

    $form.BackColor = $t.Bg
    $header.BackColor = $t.Head
    $body.BackColor   = $t.Bg
    $grip.BackColor   = $t.Bg

    $lblStatus.BackColor = $t.Head
    $lblStatus.ForeColor = $t.Sub
    $btnClose.BackColor  = $t.Head
    $btnClose.ForeColor  = $t.Sub
    $btnMin.BackColor    = $t.Head
    $btnMin.Invalidate()

    foreach ($u in $script:UI) {
        foreach ($k in @("Name", "Pct", "Price", "Delta", "Info")) { $u.$k.BackColor = $t.Bg }
        $u.Name.ForeColor = $t.Text
    }
    foreach ($sp in $script:Seps) { $sp.BackColor = $t.Line }
    if ($script:Empty.Count -ge 2) {
        $script:Empty[0].BackColor = $t.Bg; $script:Empty[0].ForeColor = $t.Text
        $script:Empty[1].BackColor = $t.Bg; $script:Empty[1].ForeColor = $t.Sub
    }

    Update-ModeButtons
    $grip.Invalidate()
    Render
    Save-Pos
}

# ---------- 位置 ----------
function Save-Pos {
    try {
        $o = @{
            X     = $script:Form.Location.X
            Y     = $script:Form.Location.Y
            Scale = $script:Scale
            Theme = $script:Theme
            Alpha = $script:Alpha
            Rate  = $(if ($script:RateMode -eq "auto") { "auto" } else { [string]$script:RateMs })
        }
        $o | ConvertTo-Json -Compress | Out-File -FilePath $PosFile -Encoding ascii -Force
    } catch { }
}

function Clamp-Bounds {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $form.Location.X
    $y = $form.Location.Y
    if (($y + $form.Height) -gt $wa.Bottom) { $y = $wa.Bottom - $form.Height - (Pd 8) }
    if ($y -lt $wa.Top) { $y = $wa.Top + (Pd 8) }
    if (($x + $form.Width) -gt $wa.Right) { $x = $wa.Right - $form.Width - (Pd 8) }
    if ($x -lt $wa.Left) { $x = $wa.Left + (Pd 8) }
    $form.Location = [System.Drawing.Point]::new([int]$x, [int]$y)
}

# ---------- 行情刷新 ----------
# ---------- 交易时段（按本机时间判断） ----------
function Get-Session {
    $now = Get-Date
    $wk  = $now.DayOfWeek
    if ($wk -eq [System.DayOfWeek]::Saturday -or $wk -eq [System.DayOfWeek]::Sunday) { return "closed" }
    $hm = $now.ToString("HHmm")
    if ($hm -lt "0915") { return "pre" }
    if ($hm -le "1135") { return "am" }
    if ($hm -lt "1255") { return "lunch" }
    if ($hm -le "1505") { return "pm" }
    return "closed"
}

# ---------- 刷新频率 ----------
function Apply-Rate {
    if ($null -eq $script:Timer) { return }
    if ($script:RateMode -eq "auto") { $want = $script:AutoMs } else { $want = $script:RateMs }
    if ($want -le 0) { $script:Timer.Stop(); return }
    if ($script:Timer.Interval -ne $want) { $script:Timer.Interval = $want }
    if (-not $script:Timer.Enabled) { $script:Timer.Start() }
}

function Fetch-Quotes {
    param([switch]$Force)

    # 自选清空后没有任何代码可查，直接跳过；否则空查询会被当成“拉取失败”误报网络异常
    if ($script:Stocks.Count -eq 0) { Render; return }

    # 非交易时段直接不发请求（-Force 用于启动 / 加股票 / 手动刷新，需要拿到收盘价显示）
    if (-not $Force) {
        $sess = Get-Session
        if ($sess -ne "am" -and $sess -ne "pm") {
            if ($null -ne $script:Timer -and $script:Timer.Interval -ne 30000) { $script:Timer.Interval = 30000 }
            return
        }
    }

    $codes = ($script:Stocks | ForEach-Object { $_.Code }) -join ","
    $q = Request-Quotes $codes

    if ($q.Count -eq 0) {
        try { Add-Content -Path $LogFile -Value ("[{0}] fetch failed" -f (Get-Date -Format "HH:mm:ss")) } catch { }
        $script:ErrCount = $script:ErrCount + 1
        if ($script:ErrCount -ge 3) {
            $lblStatus.Text = "网络异常"
            $lblStatus.ForeColor = $script:C.Down
        }
        return
    }

    $script:ErrCount = 0
    foreach ($k in $q.Keys) { $script:State[$k] = $q[$k] }
    Render
}

# ---------- 渲染 ----------
function Render {
    $c = $script:C
    for ($i = 0; $i -lt $script:Stocks.Count; $i++) {
        $def = $script:Stocks[$i]
        $u   = $script:UI[$i]
        $d   = $script:State[$def.Code]
        if ($null -eq $d) {
            $u.Name.Text  = $def.Code.Substring(2)
            $u.Price.Text = "--"
            $u.Price.ForeColor = $c.Sub
            continue
        }

        $u.Name.Text = "{0}  {1}" -f $d.Name, $def.Code.Substring(2)

        if ($d.Price -le 0) {
            $u.Price.Text = "停牌"
            $u.Price.ForeColor = $c.Sub
            $u.Pct.Text = ""
            $u.Delta.Text = ""
        } else {
            $chg = $d.Price - $d.Prev
            $pct = 0.0
            if ($d.Prev -gt 0) { $pct = $chg / $d.Prev * 100 }

            if ($chg -gt 0.0001) { $col = $c.Up }
            elseif ($chg -lt -0.0001) { $col = $c.Down }
            else { $col = $c.Flat }

            $u.Price.Text = "{0:N2}" -f $d.Price
            $u.Price.ForeColor = $col
            $sign = ""
            if ($pct -gt 0) { $sign = "+" }
            $u.Pct.Text = "{0}{1:N2}%" -f $sign, $pct
            $u.Pct.ForeColor = $col
            $dsign = ""
            if ($chg -gt 0) { $dsign = "+" }
            $u.Delta.Text = "{0}{1:N2}" -f $dsign, $chg
            $u.Delta.ForeColor = $col
        }

        if ($d.Price -le 0) {
            $u.Info.Text = ""
        } else {
            $u.Info.Text = "今开 {0:N2}   最高 {1:N2}   最低 {2:N2}" -f $d.Open, $d.High, $d.Low
            $u.Info.ForeColor = $c.Sub
        }
    }

    # 状态：交易时段显示本机抓取时刻（秒在跳 = 在拉）；非交易时段显示「已收盘 / 午休 / 未开盘」
    $sess = Get-Session
    switch ($sess) {
        "am"    { $lblStatus.Text = Get-Date -Format "HH:mm:ss" }
        "pm"    { $lblStatus.Text = Get-Date -Format "HH:mm:ss" }
        "lunch" { $lblStatus.Text = "午休" }
        "pre"   { $lblStatus.Text = "未开盘" }
        default { $lblStatus.Text = "已收盘" }
    }
    if ($script:ErrCount -lt 3) { $lblStatus.ForeColor = $c.Sub }

    # 交易时段 1 秒拉一次；收盘 / 午休 / 未开盘完全不发请求，只留 30 秒一次的本地看表（到点自动恢复）
    if ($sess -eq "am" -or $sess -eq "pm") { $script:AutoMs = 1000 } else { $script:AutoMs = 30000 }
    Apply-Rate
}

# ================= 事件绑定 =================

$btnDarkMode.Add_Click({ Set-Theme "dark" })
$btnLightMode.Add_Click({ Set-Theme "light" })
$btnMin.Add_Click({
    Save-Pos
    $script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
})
$btnClose.Add_Click({ $timer.Stop(); $script:Form.Close() })
$btnClose.Add_MouseEnter({ $this.ForeColor = $script:C.Up }) | Out-Null
$btnClose.Add_MouseLeave({ $this.ForeColor = $script:C.Sub }) | Out-Null

$grip.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:Resizing = $true
        $script:RsFrom   = $script:Scale
        $script:RsY      = [System.Windows.Forms.Cursor]::Position.Y
        $script:RsH      = $script:Form.ClientSize.Height
    }
})
$grip.Add_MouseMove({
    param($s, $e)
    if ($script:Resizing) {
        $dy = [System.Windows.Forms.Cursor]::Position.Y - $script:RsY
        $ns = $script:RsFrom * (($script:RsH + $dy) / $script:RsH)
        if ($ns -lt $script:ScaleMin) { $ns = $script:ScaleMin }
        if ($ns -gt $script:ScaleMax) { $ns = $script:ScaleMax }
        $ns = [math]::Round($ns, 2)
        if ([math]::Abs($ns - $script:Scale) -ge 0.02) {
            $script:Scale = $ns
            Layout-UI
        }
    }
})
$grip.Add_MouseUp({
    param($s, $e)
    if ($script:Resizing) {
        $script:Resizing = $false
        Save-Pos
    }
})

foreach ($ctrl in @($header, $lblStatus, $body)) { Bind-Drag $ctrl }

$form.ContextMenuStrip = New-Menu $null
$header.ContextMenuStrip = $form.ContextMenuStrip
$body.ContextMenuStrip = $form.ContextMenuStrip

# ---------- 读取上次的位置 / 缩放 / 主题 ----------
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$placed = $false
if (Test-Path $PosFile) {
    try {
        $saved = Get-Content $PosFile -Raw | ConvertFrom-Json
        if ($saved.PSObject.Properties.Name -contains "Scale") {
            $sv = [double]$saved.Scale
            if ($sv -ge $script:ScaleMin -and $sv -le $script:ScaleMax) { $script:Scale = $sv }
        }
        if ($saved.PSObject.Properties.Name -contains "Theme") {
            if ($Themes.ContainsKey([string]$saved.Theme)) { $script:Theme = [string]$saved.Theme }
        }
        if ($saved.PSObject.Properties.Name -contains "Alpha") {
            $av = [double]$saved.Alpha
            if ($av -ge 0.30 -and $av -le 1.0) { $script:Alpha = $av }
        }
        if ($saved.PSObject.Properties.Name -contains "Rate") {
            $rv = [string]$saved.Rate
            if ($rv -eq "auto") {
                $script:RateMode = "auto"; $script:RateMs = 0
            } else {
                $n = 0
                if ([int]::TryParse($rv, [ref]$n)) {
                    if ($n -gt 0) { $script:RateMode = "manual"; $script:RateMs = $n }
                }
            }
        }
        $sx = [int]$saved.X; $sy = [int]$saved.Y
        if ($sx -gt ($wa.Left - 50) -and $sx -lt ($wa.Right - 60) -and $sy -gt ($wa.Top - 10) -and $sy -lt ($wa.Bottom - 60)) {
            $form.Location = [System.Drawing.Point]::new($sx, $sy)
            $placed = $true
        }
    } catch { }
}
$script:C = $Themes[$script:Theme]
$form.Opacity = $script:Alpha
# 必须用 @() 包住：Load-Watch 只返回 1 只时 PowerShell 会把数组解包成单个 hashtable，
# 那样 $Stocks.Count 会变成 hashtable 的键数（3），Build-Rows 会建出 3 行且前两行为空。
$script:Stocks = @(Load-Watch)
Build-Rows
Layout-UI

if (-not $placed) {
    $defX = $wa.Right - $form.Width - (Pd 24)
    $defY = $wa.Top + (Pd 80)
    $form.Location = [System.Drawing.Point]::new([int]$defX, [int]$defY)
}
Clamp-Bounds

# ---------- 定时 ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ Fetch-Quotes })
$timer.Start()
$script:Timer = $timer
Apply-Rate

$form.Add_Shown({
    Set-Theme $script:Theme
    Fetch-Quotes -Force
    Write-Log ("bounds=" + $form.Bounds.ToString() + " dpi=" + $script:Dpi)
})

[System.Windows.Forms.Application]::Run($form)
