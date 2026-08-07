param(
    [int]$FarSeconds = 45,
    [int]$NearSeconds = 30,
    [int]$MinRssi = -100,
    [string]$BasePrefix = "004C1005",
    [string]$ConfigPath = "",
    [string]$InputPath = "",
    [switch]$NoApply,
    [switch]$ForceApply
)

$ErrorActionPreference = "Stop"
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot "config.json"
}
$outputDir = Join-Path $scriptRoot "calibration"
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

function Normalize-Hex {
    param([string]$Value)
    return ($Value -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
}

function Test-HexPattern {
    param(
        [string]$Hex,
        [string]$Pattern
    )

    $normalizedHex = Normalize-Hex $Hex
    $normalizedPattern = ($Pattern -replace "[^0-9A-Fa-f?]", "").ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($normalizedPattern) -or $normalizedHex.Length -lt $normalizedPattern.Length) {
        return $false
    }
    for ($i = 0; $i -lt $normalizedPattern.Length; $i++) {
        if ($normalizedPattern[$i] -ne '?' -and $normalizedPattern[$i] -ne $normalizedHex[$i]) {
            return $false
        }
    }
    return $true
}

function Get-FingerprintPatterns {
    param([string]$Hex)

    if ($Hex.Length -lt 12) {
        return @()
    }
    $tailLength = $Hex.Length - 12
    $tail = "?" * $tailLength
    return @(
        # Precise state-byte candidate.
        $Hex.Substring(0, 12) + $tail
        # State-family candidate that survives low-nibble rotation.
        $Hex.Substring(0, 9) + "?" + $Hex.Substring(10, 2) + $tail
    ) | Select-Object -Unique
}

function Get-Median {
    param([int[]]$Values)

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return -999
    }
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) {
        return [int]$sorted[$middle]
    }
    return [int][Math]::Round(($sorted[$middle - 1] + $sorted[$middle]) / 2.0)
}

function Get-PatternStats {
    param(
        [object[]]$Records,
        [string]$Pattern,
        [int]$RssiThreshold
    )

    $items = @($Records | Where-Object { Test-HexPattern -Hex $_.ManufacturerData -Pattern $Pattern })
    if ($items.Count -eq 0) {
        return [pscustomobject]@{
            Count = 0
            StrongCount = 0
            MedianRssi = -999
            MaxRssi = -999
            Addresses = @()
        }
    }

    $rssiValues = @($items | ForEach-Object { [int]$_.Rssi })
    $strongItems = @($items | Where-Object { [int]$_.Rssi -ge $RssiThreshold })
    return [pscustomobject]@{
        Count = $items.Count
        StrongCount = $strongItems.Count
        MedianRssi = Get-Median -Values $rssiValues
        MaxRssi = [int](($rssiValues | Measure-Object -Maximum).Maximum)
        Addresses = @($items | Select-Object -ExpandProperty Address -Unique)
    }
}

function Collect-Phase {
    param(
        $Bridge,
        [string]$Phase,
        [int]$Seconds,
        [int]$MinimumRssi,
        [string]$Prefix
    )

    [void]$Bridge.Drain(10000)
    $records = New-Object System.Collections.Generic.List[object]
    $started = [DateTime]::UtcNow
    $nextStatus = 0
    while (([DateTime]::UtcNow - $started).TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 250
        $elapsed = [int]([DateTime]::UtcNow - $started).TotalSeconds
        if ($elapsed -ge $nextStatus) {
            Write-Host ("{0}: {1}/{2}s, samples={3}" -f $Phase, $elapsed, $Seconds, $records.Count)
            $nextStatus = $elapsed + 5
        }

        foreach ($record in $Bridge.Drain(2000)) {
            if ([int]$record.Rssi -lt $MinimumRssi) {
                continue
            }
            foreach ($item in ([string]$record.ManufacturerData -split ";")) {
                $hex = Normalize-Hex $item
                if (-not $hex.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
                $patterns = @(Get-FingerprintPatterns -Hex $hex)
                if ($patterns.Count -eq 0) {
                    continue
                }
                $records.Add([pscustomobject]@{
                    Phase = $Phase
                    TimestampUtc = $record.TimestampUtc.ToString("o")
                    Address = [string]$record.Address
                    Rssi = [int]$record.Rssi
                    ManufacturerData = $hex
                    Pattern = $patterns[0]
                })
            }
        }
    }
    return $records.ToArray()
}

function Get-CalibrationAnalysis {
    param(
        [object[]]$FarRecords,
        [object[]]$NearRecords,
        [int]$RssiThreshold,
        [int]$RequiredHits,
        [int]$MinimumRssi
    )

    $candidates = New-Object System.Collections.Generic.List[object]
    $patterns = @($NearRecords | ForEach-Object { Get-FingerprintPatterns -Hex (Normalize-Hex $_.ManufacturerData) } | Select-Object -Unique)
    $searchStartThreshold = [Math]::Min($RssiThreshold, -75)
    $minimumNearStrong = [Math]::Max(($RequiredHits * 2), 5)
    foreach ($pattern in $patterns) {
        $selectedThreshold = $null
        $far = $null
        $near = $null
        foreach ($threshold in $searchStartThreshold..-55) {
            $thresholdFar = Get-PatternStats -Records $FarRecords -Pattern $pattern -RssiThreshold $threshold
            $thresholdNear = Get-PatternStats -Records $NearRecords -Pattern $pattern -RssiThreshold $threshold
            $farMarginOk = ($thresholdFar.Count -eq 0 -or $threshold -ge ($thresholdFar.MaxRssi + 2))
            if ($thresholdFar.StrongCount -eq 0 -and $farMarginOk -and $thresholdNear.StrongCount -ge $minimumNearStrong) {
                $selectedThreshold = $threshold
                $far = $thresholdFar
                $near = $thresholdNear
                break
            }
        }
        if ($null -eq $selectedThreshold) {
            $selectedThreshold = $searchStartThreshold
            $far = Get-PatternStats -Records $FarRecords -Pattern $pattern -RssiThreshold $selectedThreshold
            $near = Get-PatternStats -Records $NearRecords -Pattern $pattern -RssiThreshold $selectedThreshold
        }
        $farBaseline = if ($far.Count -eq 0) { $MinimumRssi - 5 } else { $far.MedianRssi }
        $maxBaseline = if ($far.Count -eq 0) { $MinimumRssi - 5 } else { $far.MaxRssi }
        $medianDelta = $near.MedianRssi - $farBaseline
        $maxDelta = $near.MaxRssi - $maxBaseline
        $farMarginOk = ($far.Count -eq 0 -or $selectedThreshold -ge ($far.MaxRssi + 2))
        $eligible = (
            $far.StrongCount -eq 0 -and
            $farMarginOk -and
            $near.StrongCount -ge $minimumNearStrong
        )
        $generalizationBonus = if ($pattern.Length -gt 9 -and $pattern[9] -eq '?') { 30 } else { 0 }
        $thresholdPenalty = $selectedThreshold - $searchStartThreshold
        $score = [int](
            ([Math]::Min($near.StrongCount, 20) * 2) +
            ([Math]::Max([Math]::Min($medianDelta, 30), -30)) +
            ([Math]::Max([Math]::Min($maxDelta, 20), -20)) +
            $(if ($far.StrongCount -eq 0) { 25 } else { 0 }) +
            $generalizationBonus -
            $thresholdPenalty
        )
        $candidates.Add([pscustomobject]@{
            Pattern = $pattern
            RssiThreshold = $selectedThreshold
            Eligible = $eligible
            Score = $score
            FarCount = $far.Count
            FarStrongCount = $far.StrongCount
            FarMedianRssi = $far.MedianRssi
            FarMaxRssi = $far.MaxRssi
            NearCount = $near.Count
            NearStrongCount = $near.StrongCount
            NearMedianRssi = $near.MedianRssi
            NearMaxRssi = $near.MaxRssi
            MedianDelta = $medianDelta
            MaxDelta = $maxDelta
            NearAddresses = $near.Addresses
        })
    }

    $ranked = @($candidates | Sort-Object @{ Expression = "Eligible"; Descending = $true }, @{ Expression = "Score"; Descending = $true })
    $selected = @($ranked | Where-Object { $_.Eligible } | Select-Object -First 1)
    $ambiguous = $false
    $eligibleCandidates = @($ranked | Where-Object { $_.Eligible })
    if ($eligibleCandidates.Count -gt 1 -and ($eligibleCandidates[0].Score - $eligibleCandidates[1].Score) -lt 5) {
        $ambiguous = $true
    }
    return [pscustomobject]@{
        Selected = if ($selected.Count -gt 0) { $selected[0] } else { $null }
        Ambiguous = $ambiguous
        Candidates = $ranked
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config = Get-Content -LiteralPath $ConfigPath -Encoding UTF8 -Raw | ConvertFrom-Json
$rssiThreshold = [int]$config.proximity.rssiThreshold
$requiredHits = [int]$config.proximity.hitCount
$normalizedPrefix = Normalize-Hex $BasePrefix
$capture = $null
$capturePath = ""

if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
    $capture = Get-Content -LiteralPath $InputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    $capturePath = (Resolve-Path -LiteralPath $InputPath).Path
}
else {
    . (Join-Path $scriptRoot "lib\BleBridge.ps1")
    Add-BleBridgeType
    $bridge = [BleAdvertisementBridge]::new()
    try {
        $bridge.Start()
        Write-Host "Apple Watch calibration"
        Write-Host "Only Apple Nearby Info packets beginning with $normalizedPrefix will be sampled."
        Write-Host ""
        [void](Read-Host "Move the watch far away from this PC, then press Enter")
        $farRecords = Collect-Phase -Bridge $bridge -Phase "far" -Seconds $FarSeconds -MinimumRssi $MinRssi -Prefix $normalizedPrefix
        Write-Host ""
        [void](Read-Host "Bring the watch close to this PC, then press Enter")
        $nearRecords = Collect-Phase -Bridge $bridge -Phase "near" -Seconds $NearSeconds -MinimumRssi $MinRssi -Prefix $normalizedPrefix
    }
    finally {
        $bridge.Dispose()
    }

    $capture = [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString("o")
        BasePrefix = $normalizedPrefix
        RssiThreshold = $rssiThreshold
        FarSeconds = $FarSeconds
        NearSeconds = $NearSeconds
        Far = @($farRecords)
        Near = @($nearRecords)
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $capturePath = Join-Path $outputDir "apple-watch-calibration-$stamp.json"
    $capture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $capturePath -Encoding UTF8
}

$analysis = Get-CalibrationAnalysis -FarRecords @($capture.Far) -NearRecords @($capture.Near) -RssiThreshold $rssiThreshold -RequiredHits $requiredHits -MinimumRssi $MinRssi
$reportPath = [IO.Path]::ChangeExtension($capturePath, ".txt")
$report = New-Object System.Collections.Generic.List[string]
$report.Add("Apple Watch BLE calibration report")
$report.Add("Capture: $capturePath")
$report.Add("RSSI search start: $([Math]::Min($rssiThreshold, -75))")
$report.Add("Far samples: $(@($capture.Far).Count)")
$report.Add("Near samples: $(@($capture.Near).Count)")
$report.Add("")
$report.Add("Candidates:")
foreach ($candidate in @($analysis.Candidates | Select-Object -First 10)) {
    $report.Add(("Pattern={0} Threshold={1} Eligible={2} Score={3} Far={4}/{5} Near={6}/{7} MedianDelta={8} MaxDelta={9}" -f $candidate.Pattern, $candidate.RssiThreshold, $candidate.Eligible, $candidate.Score, $candidate.FarStrongCount, $candidate.FarCount, $candidate.NearStrongCount, $candidate.NearCount, $candidate.MedianDelta, $candidate.MaxDelta))
}
$report.Add("")

$applied = $false
if ($null -eq $analysis.Selected) {
    $report.Add("RESULT: FAILED - no pattern separated the far and near phases.")
}
elseif ($analysis.Ambiguous -and -not $ForceApply) {
    $report.Add("RESULT: AMBIGUOUS - multiple patterns scored almost equally. Configuration was not changed.")
}
else {
    $selectedPattern = [string]$analysis.Selected.Pattern
    $selectedRssiThreshold = [int]$analysis.Selected.RssiThreshold
    $report.Add("RESULT: SELECTED $selectedPattern at $selectedRssiThreshold dBm")
    if (-not $NoApply) {
        $backupPath = "$ConfigPath.calibration-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath
        if ($null -eq $config.target.PSObject.Properties["manufacturerDataHexPattern"]) {
            $config.target | Add-Member -NotePropertyName manufacturerDataHexPattern -NotePropertyValue ""
        }
        $config.target.nameContains = ""
        $config.target.address = ""
        $config.target.serviceUuid = ""
        $config.target.manufacturerDataHexPrefix = ""
        $config.target.manufacturerDataHexPattern = $selectedPattern
        $config.proximity.rssiThreshold = $selectedRssiThreshold
        $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        $report.Add("Config updated: $ConfigPath")
        $report.Add("Config backup: $backupPath")
        $applied = $true
    }
    else {
        $report.Add("Config not changed because -NoApply was specified.")
    }
}

$report | Set-Content -LiteralPath $reportPath -Encoding UTF8
$report | ForEach-Object { Write-Host $_ }
Write-Host "Report: $reportPath"
if ($applied) {
    Write-Host "Restart BLE Proximity Wake before testing the new rule."
}
