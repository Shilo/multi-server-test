param(
    [string]$Label = "cpu-profile",
    [int]$ClientCount = 10,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$LogRoot = Join-Path $ProjectRoot ".logs\cpu_rate_profiles"
$OutPath = Join-Path $LogRoot "$Label.csv"
$SummaryPath = Join-Path $LogRoot "$Label-summary.json"
$StopPath = Join-Path $LogRoot "$Label.stop"

New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
Remove-Item $OutPath, $SummaryPath, $StopPath -ErrorAction SilentlyContinue

$sampler = Start-Job -ScriptBlock {
	param($OutPath, $StopPath, $ProjectRoot)

	$logicalProcessors = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
	"timestamp,role,pids,core_pct,host_pct,working_set_mb" | Set-Content -LiteralPath $OutPath
	$previous = @{}

	while (-not (Test-Path -LiteralPath $StopPath)) {
		$now = Get-Date
		$groups = @{}
		$processes = Get-CimInstance Win32_Process |
			Where-Object { $_.Name -like "Godot*" -and $_.CommandLine -like "*multi-server-test*" }

		foreach ($windowsProcess in $processes) {
			$process = Get-Process -Id $windowsProcess.ProcessId -ErrorAction SilentlyContinue
			if (-not $process -or $null -eq $process.CPU) {
				continue
			}

			$commandLine = [string]$windowsProcess.CommandLine
			$role = "other"
			if ($commandLine.Contains("server/master/master.tscn")) {
				$role = "master"
			} elseif ($commandLine.Contains("server/world/world.tscn")) {
				$role = "world"
			} elseif ($commandLine.Contains("client/client.tscn")) {
				$role = "client"
			} elseif ($commandLine.Contains("--editor") -or $commandLine.Contains("export_world_packs")) {
				$role = "tool"
			}

			$pidKey = [string]$windowsProcess.ProcessId
			if ($previous.ContainsKey($pidKey)) {
				$elapsedSeconds = ($now - $previous[$pidKey].time).TotalSeconds
				$cpuDelta = [double]$process.CPU - [double]$previous[$pidKey].cpu
				if ($elapsedSeconds -gt 0 -and $cpuDelta -ge 0) {
					if (-not $groups.ContainsKey($role)) {
						$groups[$role] = [pscustomobject]@{ Core = 0.0; WorkingSet = 0.0; Pids = @() }
					}
					$groups[$role].Core += ($cpuDelta / $elapsedSeconds) * 100.0
					$groups[$role].WorkingSet += [double]$process.WorkingSet64 / 1MB
					$groups[$role].Pids += $windowsProcess.ProcessId
				}
			}

			$previous[$pidKey] = @{ Time = $now; Cpu = [double]$process.CPU }
		}

		$serverCore = 0.0
		$serverWorkingSet = 0.0
		$serverPids = @()
		foreach ($role in @("master", "world")) {
			if ($groups.ContainsKey($role)) {
				$serverCore += $groups[$role].Core
				$serverWorkingSet += $groups[$role].WorkingSet
				$serverPids += $groups[$role].Pids
			}
		}
		if ($serverPids.Count -gt 0) {
			$groups["server_total"] = [pscustomobject]@{
				Core = $serverCore
				WorkingSet = $serverWorkingSet
				Pids = $serverPids
			}
		}

		$allCore = 0.0
		$allWorkingSet = 0.0
		$allPids = @()
		foreach ($role in $groups.Keys) {
			if ($role -eq "server_total" -or $role -eq "all_godot") {
				continue
			}
			$allCore += $groups[$role].Core
			$allWorkingSet += $groups[$role].WorkingSet
			$allPids += $groups[$role].Pids
		}
		if ($allPids.Count -gt 0) {
			$groups["all_godot"] = [pscustomobject]@{
				Core = $allCore
				WorkingSet = $allWorkingSet
				Pids = $allPids
			}
		}

		foreach ($role in ($groups.Keys | Sort-Object)) {
			$group = $groups[$role]
			$line = "{0},{1},{2},{3:N3},{4:N3},{5:N3}" -f `
				$now.ToString("o"),
				$role,
				($group.Pids -join "+"),
				$group.Core,
				($group.Core / [double]$logicalProcessors),
				$group.WorkingSet
			Add-Content -LiteralPath $OutPath -Value $line
		}

		Start-Sleep -Milliseconds 500
	}
} -ArgumentList $OutPath, $StopPath, $ProjectRoot

try {
	& (Join-Path $PSScriptRoot "run_smoke.ps1") `
		-UsePackRatWorldPacks `
		-ClientCount $ClientCount `
		-TimeoutSeconds $TimeoutSeconds
}
finally {
	New-Item -ItemType File -Force -Path $StopPath | Out-Null
	Wait-Job $sampler | Out-Null
	Receive-Job $sampler | Out-Null
	Remove-Job $sampler
}

$summary = Import-Csv $OutPath |
	Group-Object role |
	ForEach-Object {
		$rows = $_.Group
		[pscustomobject]@{
			role = $_.Name
			samples = $rows.Count
			avg_core_pct = [math]::Round((($rows | ForEach-Object { [double]$_.core_pct }) | Measure-Object -Average).Average, 2)
			max_core_pct = [math]::Round((($rows | ForEach-Object { [double]$_.core_pct }) | Measure-Object -Maximum).Maximum, 2)
			avg_host_pct = [math]::Round((($rows | ForEach-Object { [double]$_.host_pct }) | Measure-Object -Average).Average, 2)
			max_working_set_mb = [math]::Round((($rows | ForEach-Object { [double]$_.working_set_mb }) | Measure-Object -Maximum).Maximum, 2)
		}
	} |
	Sort-Object role

$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $SummaryPath
$summary | Format-Table -AutoSize
Write-Host "CPU_PROFILE_DONE label=$Label csv=$OutPath summary=$SummaryPath"
