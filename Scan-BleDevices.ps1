param(
    [int]$Seconds = 20,
    [int]$MinRssi = -100,
    [string]$NameContains = "",
    [string]$Address = "",
    [string]$ManufacturerCompanyId = "",
    [switch]$ShowManufacturerData
)

$ErrorActionPreference = "Stop"

function Initialize-BleTypes {
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    . (Join-Path $scriptRoot "lib\BleBridge.ps1")
    Add-BleBridgeType
}

Initialize-BleTypes

$bridge = [BleAdvertisementBridge]::new()
$seen = @{}
$summary = @{}
$started = [DateTime]::UtcNow

Write-Host "Scanning BLE advertisements for $Seconds seconds. Press Ctrl+C to stop."
Write-Host "RSSI threshold for display: $MinRssi dBm"
if (-not [string]::IsNullOrWhiteSpace($NameContains)) {
    Write-Host "Name filter: $NameContains"
}
if (-not [string]::IsNullOrWhiteSpace($Address)) {
    Write-Host "Address filter: $Address"
}
if (-not [string]::IsNullOrWhiteSpace($ManufacturerCompanyId)) {
    Write-Host "Manufacturer company filter: $ManufacturerCompanyId"
}
Write-Host ""

try {
    $bridge.Start()
    while (([DateTime]::UtcNow - $started).TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 250
        foreach ($record in $bridge.Drain(1000)) {
            if ($record.Rssi -lt $MinRssi) {
                continue
            }

            $name = $record.Name
            $address = $record.Address
            if (-not [string]::IsNullOrWhiteSpace($Address)) {
                $normalizedWantedAddress = ($Address -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
                $normalizedRecordAddress = ($address -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
                if ($normalizedRecordAddress -ne $normalizedWantedAddress) {
                    continue
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($NameContains)) {
                if ([string]::IsNullOrWhiteSpace($name) -or $name.IndexOf($NameContains, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    continue
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($ManufacturerCompanyId)) {
                $wantedCompanyId = ($ManufacturerCompanyId -replace "[^0-9A-Fa-f]", "").ToUpperInvariant()
                if ([string]::IsNullOrWhiteSpace($record.ManufacturerData) -or -not $record.ManufacturerData.ToUpperInvariant().Contains($wantedCompanyId + ":")) {
                    continue
                }
            }

            $key = $address
            $now = Get-Date -Format "HH:mm:ss"
            $serviceUuids = $record.ServiceUuids
            $manufacturerData = $record.ManufacturerData

            if (-not $summary.ContainsKey($key)) {
                $summary[$key] = [pscustomobject]@{
                    Address = $address
                    Count = 0
                    MinRssi = 999
                    MaxRssi = -999
                    Names = New-Object System.Collections.Generic.HashSet[string]
                    ManufacturerData = New-Object System.Collections.Generic.HashSet[string]
                    ServiceUuids = New-Object System.Collections.Generic.HashSet[string]
                    FirstSeen = $now
                    LastSeen = $now
                }
            }
            $entry = $summary[$key]
            $entry.Count++
            $entry.MinRssi = [Math]::Min([int]$entry.MinRssi, [int]$record.Rssi)
            $entry.MaxRssi = [Math]::Max([int]$entry.MaxRssi, [int]$record.Rssi)
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                [void]$entry.Names.Add($name)
            }
            if (-not [string]::IsNullOrWhiteSpace($manufacturerData)) {
                [void]$entry.ManufacturerData.Add($manufacturerData)
            }
            if (-not [string]::IsNullOrWhiteSpace($serviceUuids)) {
                [void]$entry.ServiceUuids.Add($serviceUuids)
            }
            $entry.LastSeen = $now

            $last = $seen[$key]
            if ($null -eq $last -or $last.Rssi -ne $record.Rssi -or $last.Name -ne $name) {
                $seen[$key] = [pscustomobject]@{
                    Name = $name
                    Rssi = $record.Rssi
                    LastSeen = $now
                }

                $line = "{0} RSSI={1,4} dBm Address={2} Name={3}" -f $now, $record.Rssi, $address, $(if ($name) { $name } else { "<empty>" })
                if (-not [string]::IsNullOrWhiteSpace($serviceUuids)) {
                    $line += " Services=$serviceUuids"
                }
                if ($ShowManufacturerData -and -not [string]::IsNullOrWhiteSpace($manufacturerData)) {
                    $line += " ManufacturerData=$manufacturerData"
                }
                Write-Host $line
            }
        }
    }
}
finally {
    $bridge.Dispose()
}

Write-Host ""
Write-Host "Scan complete. Unique addresses observed: $($seen.Count)"
if ($summary.Count -gt 0) {
    Write-Host ""
    Write-Host "Summary:"
    $summary.Values |
        Sort-Object @{ Expression = "MaxRssi"; Descending = $true }, @{ Expression = "Count"; Descending = $true } |
        ForEach-Object {
            $names = if ($_.Names.Count -gt 0) { ($_.Names -join "|") } else { "<empty>" }
            $manufacturer = if ($_.ManufacturerData.Count -gt 0) { ($_.ManufacturerData -join "|") } else { "" }
            $services = if ($_.ServiceUuids.Count -gt 0) { ($_.ServiceUuids -join "|") } else { "" }
            $line = "Address={0} Count={1} RSSI={2}..{3} Name={4}" -f $_.Address, $_.Count, $_.MinRssi, $_.MaxRssi, $names
            if (-not [string]::IsNullOrWhiteSpace($manufacturer)) {
                $line += " ManufacturerData=$manufacturer"
            }
            if (-not [string]::IsNullOrWhiteSpace($services)) {
                $line += " Services=$services"
            }
            Write-Host $line
        }
}
