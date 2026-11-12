<#
  warp-claude-reap.ps1 -- find (and optionally kill) process trees orphaned by
  an ungraceful Warp exit on Windows.

  When warp.exe dies without closing its panes (crash, Task Manager "End
  task"), Windows does not take the pane processes down with it. Each pane's
  bash -> bash -> claude.exe chain (plus claude's MCP servers) keeps running
  with no terminal attached. Nothing can ever type into it again, but an
  orphaned claude still holds its session: after a restart the resumed copy and
  the orphan both write the same transcript, and both show up in Remote Control.

  What counts as an orphaned Warp pane (the "root" of the tree to kill):
    - a bash.exe whose command line is `--noprofile --norc` (how Warp launches
      Git Bash), whose parent process no longer exists, and
    - that dead parent was a warp.exe: its PID and start time are in the
      warp-instances file, which every run of this script appends the live
      warp.exe processes to. Windows cannot tell us what a dead process was,
      so we remember Warps while they are alive.
  The second test is what makes this safe. MSYS2 children show their parent's
  command line, so a job backgrounded in a live tab (`( job & )`, `nohup`)
  is ALSO a `bash --noprofile --norc` with a dead parent -- but its dead
  parent was a bash, not a recorded warp.exe. Found on a live machine: the
  background sweep's own launcher looked like an orphan and the sweep killed
  itself halfway through.
  -Loose drops the second test (for orphans of Warps that ran before this
  tracking existed). Never used automatically.
  Whatever the mode, the tree containing this script's own process is never a
  candidate, and a parent PID now owned by a NEWER process counts as dead.

  Usage (called by warp-claude.bash; safe to run by hand):
    -SessionId <id>   only trees running a claude.exe for this Claude session,
                      matched via ~/.claude/sessions/<pid>.json (pid AND process
                      start time must match, so a reused PID is never killed)
    -All              every orphaned Warp pane tree
    -Loose            see above
    -Kill             kill the matched trees (default: list only)
    -InstancesFile    where Warp PIDs are remembered (default: next to this file)
#>
param(
  [string]$SessionId = "",
  [switch]$All,
  [switch]$Kill,
  [switch]$Loose,
  [string]$SessionsDir = (Join-Path $env:USERPROFILE ".claude\sessions"),
  [string]$InstancesFile = (Join-Path $PSScriptRoot "warp-instances")
)
$ErrorActionPreference = "SilentlyContinue"

if (-not $All -and -not ($SessionId -match '^[0-9A-Za-z_-]{1,64}$')) { exit 2 }

$procs = @{}
$kids = @{}
Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate |
  ForEach-Object {
    $procs[[int]$_.ProcessId] = $_
    $pp = [int]$_.ParentProcessId
    if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-Object System.Collections.ArrayList }
    [void]$kids[$pp].Add($_)
  }

# --- Warp instance memory: "<pid> <start FILETIME>" per line, 30-day window.
$instances = @{}          # "pid filetime" -> [int64]filetime
$cutoff = (Get-Date).AddDays(-30).ToFileTime()
foreach ($line in @(Get-Content -LiteralPath $InstancesFile)) {
  if ($line -match '^(\d{1,10}) (\d{1,20})$' -and [int64]$matches[2] -gt $cutoff) { $instances[$line] = [int64]$matches[2] }
}
$before = $instances.Count
foreach ($w in $procs.Values) {
  if ($w.Name -eq "warp.exe") { $instances["$($w.ProcessId) $($w.CreationDate.ToFileTime())"] = $w.CreationDate.ToFileTime() }
}
if ($instances.Count -ne $before -or -not (Test-Path -LiteralPath $InstancesFile)) {
  Set-Content -LiteralPath $InstancesFile -Encoding ascii -Value @($instances.Keys | Sort-Object)
}

# True if PID $ppid, as a parent of something started at $childStart, was a
# recorded warp.exe that is no longer running.
function Test-DeadWarp([int]$ppid, $childStart) {
  $live = $procs[$ppid]
  foreach ($k in $instances.Keys) {
    $parts = $k.Split(" ")
    if ([int]$parts[0] -ne $ppid) { continue }
    $started = [DateTime]::FromFileTime([int64]$parts[1])
    if ($started -gt $childStart) { continue }          # that Warp came later
    if ($live -and [math]::Abs(($live.CreationDate - $started).TotalSeconds) -lt 1) { return $false }  # still running
    return $true
  }
  return $false
}

function Get-LiveParent($p) {
  $pp = $procs[[int]$p.ParentProcessId]
  if (-not $pp) { return $null }
  # PID reuse: a "parent" created after the child is not the real parent.
  if ($pp.CreationDate -gt $p.CreationDate) { return $null }
  return $pp
}

# This script's own ancestry: never a candidate (the background sweep runs
# under a bash that itself looks orphaned).
$self = @{}
$c = $procs[[int]$PID]
for ($i = 0; $c -and $i -lt 64; $i++) { $self[[int]$c.ProcessId] = 1; $c = Get-LiveParent $c }

function Test-OrphanRoot($p) {
  if ($p.Name -ne "bash.exe" -or $p.CommandLine -notmatch '--noprofile\s+--norc') { return $false }
  if ($self.ContainsKey([int]$p.ProcessId)) { return $false }
  if (Get-LiveParent $p) { return $false }
  if ($Loose) { return $true }
  return (Test-DeadWarp ([int]$p.ParentProcessId) $p.CreationDate)
}

# Root of the orphaned Warp pane tree containing $p, or $null if $p is not in one.
function Get-OrphanRoot($p) {
  $cur = $p
  for ($i = 0; $i -lt 64; $i++) {
    if ($cur.Name -eq "warp.exe") { return $null }
    $parent = Get-LiveParent $cur
    if (-not $parent) {
      if (Test-OrphanRoot $cur) { return $cur } else { return $null }
    }
    $cur = $parent
  }
  return $null
}

function Get-Descendants($rootId) {
  $out = New-Object System.Collections.ArrayList
  $queue = New-Object System.Collections.Queue
  $queue.Enqueue([int]$rootId)
  while ($queue.Count) {
    $id = $queue.Dequeue()
    if (-not $kids.ContainsKey($id)) { continue }
    foreach ($ch in $kids[$id]) {
      # Skip a "child" older than its parent: that is PID reuse, not a child.
      if ($ch.CreationDate -ge $procs[$id].CreationDate) {
        [void]$out.Add($ch); $queue.Enqueue([int]$ch.ProcessId)
      }
    }
  }
  return ,$out
}

$roots = @{}
if ($All) {
  foreach ($p in $procs.Values) {
    if (Test-OrphanRoot $p) { $roots[[int]$p.ProcessId] = $p }
  }
} else {
  foreach ($f in Get-ChildItem -LiteralPath $SessionsDir -Filter "*.json") {
    try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if ($j.sessionId -ne $SessionId) { continue }
    $p = $procs[[int]$j.pid]
    if (-not $p -or $p.Name -ne "claude.exe") { continue }
    # procStart is the process creation time as a Windows FILETIME.
    try { $started = [DateTime]::FromFileTime([int64]$j.procStart) } catch { continue }
    if ([math]::Abs(($p.CreationDate - $started).TotalSeconds) -gt 2) { continue }
    $r = Get-OrphanRoot $p
    if ($r) { $roots[[int]$r.ProcessId] = $r }
  }
}

$ws = @{}
if ($roots.Count) { Get-Process | ForEach-Object { $ws[$_.Id] = $_.WorkingSet64 } }
foreach ($r in $roots.Values) {
  $desc = Get-Descendants $r.ProcessId
  # Belt and braces: never kill a tree that contains this script.
  if (@($desc | Where-Object { $self.ContainsKey([int]$_.ProcessId) }).Count) { continue }
  $claudes = @($desc | Where-Object { $_.Name -eq "claude.exe" })
  $mb = [int]((@($r) + @($desc) | ForEach-Object { $ws[[int]$_.ProcessId] } | Measure-Object -Sum).Sum / 1MB)
  $what = if ($claudes.Count) { "claude pid " + (($claudes | ForEach-Object { $_.ProcessId }) -join ",") } else { "shell only" }
  $verb = if ($Kill) { "killed" } else { "orphan" }
  # Kill exactly the tree computed above (children first), not `taskkill /T`:
  # taskkill follows ParentProcessId alone, so a reused PID could pull in an
  # unrelated process. Get-Descendants already drops "children" older than
  # their parent.
  if ($Kill) {
    $victims = @($desc) | Sort-Object CreationDate -Descending
    foreach ($v in @($victims) + $r) { Stop-Process -Id ([int]$v.ProcessId) -Force -ErrorAction SilentlyContinue }
  }
  "{0} tree {1} (started {2:HH:mm:ss}, {3} procs, {4} MB): {5}" -f $verb, $r.ProcessId, $r.CreationDate, (1 + $desc.Count), $mb, $what
}
exit 0
