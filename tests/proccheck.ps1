Get-CimInstance Win32_Process -Filter "Name='erl.exe'" | ForEach-Object {
  $ws = [math]::Round($_.WorkingSetSize/1MB,1)
  "$($_.ProcessId) parent=$($_.ParentProcessId) created=$($_.CreationDate) rss=${ws}MB cmd=$($_.CommandLine)"
}
