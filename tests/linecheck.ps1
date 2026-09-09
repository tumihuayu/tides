param([string]$Path)
$b = [IO.File]::ReadAllBytes($Path)
$crlf = 0; $lf = 0
for ($i = 0; $i -lt $b.Length; $i++) {
  if ($b[$i] -eq 10) {
    if ($i -gt 0 -and $b[$i-1] -eq 13) { $crlf++ } else { $lf++ }
  }
}
$nonAscii = 0
foreach ($x in $b) { if ($x -gt 127) { $nonAscii++ } }
"$Path : CRLF=$crlf LF-only=$lf nonASCII-bytes=$nonAscii"
