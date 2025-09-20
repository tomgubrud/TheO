param(
  [Parameter(Mandatory = $true, Position = 0)][string[]]$Files,
  [switch]$PauseBetween = $true,
  [int]$Width = 160
)

# Configure console for wide output
try {
  $raw = $Host.UI.RawUI
  $buf  = $raw.BufferSize
  $win  = $raw.WindowSize
  if ($buf.Width -lt $Width)  { $buf.Width = $Width }
  if ($win.Width -lt $Width)  { $win.Width = $Width }
  $buf.Height = [Math]::Max($buf.Height, 9000)
  $raw.BufferSize = $buf
  $raw.WindowSize = $win
} catch {}

$filesResolved = @()
foreach ($f in $Files) {
  $m = Get-ChildItem -LiteralPath $f -File -Recurse -ErrorAction SilentlyContinue
  if (-not $m) { $m = Get-ChildItem -Path $f -File -Recurse -ErrorAction SilentlyContinue }
  if ($m) { $filesResolved += $m } else { Write-Warning "No match: $f" }
}

if (-not $filesResolved) { throw "No files to print." }

$idx = 0
foreach ($fi in $filesResolved) {
  $idx++
  Write-Host ""
  Write-Host ("=" * $Width)
  Write-Host ("[{0}/{1}]  {2}" -f $idx, $filesResolved.Count, $fi.FullName) -ForegroundColor Cyan
  Write-Host ("=" * $Width)

  $ln = 0
  Get-Content -LiteralPath $fi.FullName | ForEach-Object {
    $ln++
    # Show line numbers, preserve whitespace with a visible · for trailing spaces and ↹ for tabs
    $line = $_ -replace "`t", "↹" -replace "\s+$", { param($m) "·" * $m.Length }
    "{0,5}: {1}" -f $ln, $line
  } | Out-Host

  if ($PauseBetween) {
    Write-Host ""
    Write-Host "Press Enter for next file (screenshot now)..." -ForegroundColor Yellow
    [void][System.Console]::ReadLine()
  }
}