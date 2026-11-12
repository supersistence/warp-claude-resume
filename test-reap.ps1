<#
  Tests for warp-claude-reap.ps1 against REAL synthetic orphan trees.

  One launcher (cmd.exe, standing in for warp.exe) starts three
  `bash --noprofile --norc` panes and exits, orphaning them:
    A  runs a copy of sleep.exe named claude.exe     (session-mode target)
    C  same, different argument                      (-All target)
    B  waits for a trigger, then runs the reaper's -All -Kill ITSELF, from
       inside an orphan tree -- the situation in which the background sweep
       once killed itself halfway through.
  The launcher's PID is written to a private instances file, so only these
  fakes can ever match. Real sessions and real Warp processes are never touched.

    powershell -NoProfile -ExecutionPolicy Bypass -File test-reap.ps1
#>
$ErrorActionPreference = "Stop"
$reap = Join-Path $PSScriptRoot "warp-claude-reap.ps1"
$git = "C:\Program Files\Git\usr\bin"
$t = Join-Path $env:TEMP ("reaptest-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$script:pass = 0; $script:fail = 0
function Ok($name, $cond, $detail = "") {
  if ($cond) { $script:pass++; "  ok    $name" } else { $script:fail++; "  FAIL  $name $detail" }
}
function Reap { & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $reap @args }
function Alive($id) { [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }
function Find-Fake($arg) {
  Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "claude.exe" -and $_.ExecutablePath -like "$t*" -and $_.CommandLine -match " $arg`$" } | Select-Object -First 1
}

New-Item -ItemType Directory $t | Out-Null
$posix = $null
try {
  Copy-Item "$git\sleep.exe" "$t\claude.exe"
  Copy-Item "$git\msys-2.0.dll" $t
  $posix = (& "$git\cygpath.exe" -u $t).Trim()
  $inst = "$t\instances"; $instB = "$t\instances-b"
  $reapW = $reap
  # B: wait for the trigger, then reap everything it can see (strict mode).
  Set-Content -Encoding ascii "$t\b.sh" @"
while [ ! -f '$posix/go' ]; do sleep 0.2; done
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '$reapW' -All -Kill -InstancesFile '$instB' > '$posix/b.out' 2>&1
echo done >> '$posix/b.out'
sleep 120
"@
  Set-Content -Encoding ascii "$t\launch.cmd" @"
@start "" /min "$git\bash.exe" --noprofile --norc -c "'$posix/claude.exe' 300"
@start "" /min "$git\bash.exe" --noprofile --norc -c "'$posix/claude.exe' 301"
@start "" /min "$git\bash.exe" --noprofile --norc "$posix/b.sh"
"@
  # No -Wait: in PS 5.1 it also waits for the (deliberately long-lived) children.
  $launcher = Start-Process cmd.exe -ArgumentList "/c", "`"$t\launch.cmd`"" -WindowStyle Hidden -PassThru
  # The launcher may already have exited; its handle still knows when it started.
  $launcherLine = "$($launcher.Id) $($launcher.StartTime.ToFileTime())"
  $a = $null; $c = $null; $b = $null
  for ($i = 0; $i -lt 50 -and -not ($a -and $c -and $b); $i++) {
    Start-Sleep -Milliseconds 200
    $a = Find-Fake 300; $c = Find-Fake 301
    # MSYS fork children copy the parent's command line; B is the one the launcher started.
    $b = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq "bash.exe" -and $_.CommandLine -like "*b.sh*" -and [int]$_.ParentProcessId -eq $launcher.Id } | Select-Object -First 1
  }
  $launcher.WaitForExit(10000) | Out-Null
  Ok "fake orphan panes started" ($a -and $c -and $b)
  if (-not ($a -and $c -and $b)) { return }
  $aRoot = Get-CimInstance Win32_Process -Filter "ProcessId=$($a.ParentProcessId)"
  $cRoot = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.ParentProcessId)"
  Ok "launcher is gone (really orphaned)" (-not (Alive $launcher.Id))

  $sd = "$t\sessions"; New-Item -ItemType Directory $sd | Out-Null
  function Session($file, $procId, $sid, $created) {
    @{ pid = $procId; sessionId = $sid; procStart = "$($created.ToFileTime())" } | ConvertTo-Json | Set-Content -Encoding utf8 "$sd\$file"
  }
  Session a.json $a.ProcessId "fake-orphan" $a.CreationDate
  Session b.json $a.ProcessId "fake-reused" $a.CreationDate.AddMinutes(-5)
  $me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
  Session c.json $PID "fake-live" $me.CreationDate

  # --- strict mode: the dead parent must be a remembered Warp
  Set-Content -Encoding ascii $inst ""
  $l = Reap -All -InstancesFile $inst
  Ok "strict: dead parent not a known Warp -> not an orphan" (-not ("$l" -match "tree $($aRoot.ProcessId) ")) "got: $l"
  Ok "strict: running reaper records live warp.exe" (@(Get-Process warp -ErrorAction SilentlyContinue).Count -eq 0 -or (Get-Content $inst | Where-Object { $_ -match '^\d+ \d+$' }))
  $l = Reap -All -Loose -InstancesFile $inst
  Ok "-Loose: matched without a known Warp" ("$l" -match "tree $($aRoot.ProcessId) ") "got: $l"
  Set-Content -Encoding ascii $inst $launcherLine
  Set-Content -Encoding ascii $instB $launcherLine
  $l = Reap -All -InstancesFile $inst
  Ok "strict: known dead Warp parent -> orphan" ("$l" -match "tree $($aRoot.ProcessId) " -and "$l" -match "tree $($cRoot.ProcessId) ") "got: $l"
  Ok "list mode killed nothing" ((Alive $a.ProcessId) -and (Alive $c.ProcessId))

  # --- session mode
  Ok "live (non-orphan) process never matched" (-not (Reap -SessionId fake-live -SessionsDir $sd -InstancesFile $inst))
  Ok "PID with mismatched start time never matched" (-not (Reap -SessionId fake-reused -SessionsDir $sd -InstancesFile $inst))
  Ok "unknown session matches nothing" (-not (Reap -SessionId nope -SessionsDir $sd -InstancesFile $inst))
  Reap -SessionId "../x" -SessionsDir $sd -InstancesFile $inst | Out-Null
  Ok "bad session id rejected" ($LASTEXITCODE -eq 2)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $kill = Reap -SessionId fake-orphan -SessionsDir $sd -InstancesFile $inst -Kill
  $ms = $sw.ElapsedMilliseconds
  Start-Sleep -Milliseconds 500
  Ok "session kill reported" ("$kill" -match "^killed tree $($aRoot.ProcessId) .*claude pid $($a.ProcessId)") "got: $kill"
  Ok "session kill: that claude and its bash gone" (-not (Alive $a.ProcessId) -and -not (Alive $aRoot.ProcessId))
  Ok "session kill: other orphans untouched" ((Alive $c.ProcessId) -and (Alive $b.ProcessId))

  # --- the reaper running from INSIDE an orphan tree must not kill itself
  Set-Content -Encoding ascii "$t\go" ""
  for ($i = 0; $i -lt 100; $i++) {
    if ((Test-Path "$t\b.out") -and (Get-Content "$t\b.out" -Raw) -match "done") { break }
    Start-Sleep -Milliseconds 200
  }
  $bout = if (Test-Path "$t\b.out") { Get-Content "$t\b.out" -Raw } else { "" }
  Ok "reaper inside an orphan tree finished (did not kill itself)" ($bout -match "done") "got: $bout"
  Ok "...and its own tree is still alive" (Alive $b.ProcessId)
  Ok "...and it never listed its own tree" (-not ($bout -match "tree $($b.ProcessId) ")) "got: $bout"
  Start-Sleep -Milliseconds 500
  Ok "...but it did kill the other orphan" (-not (Alive $c.ProcessId) -and -not (Alive $cRoot.ProcessId)) "got: $bout"
  Ok "test process itself untouched" (Alive $PID)
  "  (session-mode kill took $ms ms)"
}
finally {
  Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like "$t*" -or $_.CommandLine -like "*$t*" -or ($posix -and $_.CommandLine -like "*$posix*") } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 300
  Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue
}
""
"$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
