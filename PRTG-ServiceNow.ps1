#requires -Version 5.1
<#+
.SYNOPSIS
  Sends PRTG notifications to the ServiceNow Scripted REST API.

.DESCRIPTION
  OPEN and RECOVER are retained for PRTG notification compatibility and are
  mapped internally to Alert and Recovery. ServiceNow owns alert lifecycle.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('OPEN', 'RECOVER')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$SensorId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Down', 'Unknown', 'Unusual', 'Up', 'Warning')]
    [string]$Status,

    [Parameter(Mandatory = $true)]
    [string]$DeviceId,

    [Parameter(Mandatory = $true)]
    [string]$Device,

    [Parameter(Mandatory = $true)]
    [string]$Sensor,

    [Parameter(Mandatory = $true)]
    [string]$Message,

    [Parameter(Mandatory = $true)]
    [string]$Priority,

    [string]$Probe = '',
    [string]$Group = '',
    [string]$DeviceAddress = '',
    [string]$SensorType = '',
    [string]$Tags = '',
    [string]$SensorUrl = '',

    [string]$ConfigPath = 'C:\ProgramData\PRTG-ServiceNow\config.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }

    $modulePath = Join-Path $PSScriptRoot 'PRTGServiceNow.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Required module not found: $modulePath"
    }

    Import-Module -Name $modulePath -Force -ErrorAction Stop
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $result = Invoke-PrtgServiceNow -Action $Action -Status $Status -SensorId $SensorId -DeviceId $DeviceId -DeviceName $Device -SensorName $Sensor -Message $Message -Priority $Priority -Config $config -Probe $Probe -Group $Group -DeviceAddress $DeviceAddress -SensorType $SensorType -Tags $Tags -PrtgUrl $SensorUrl

    Write-Output "OK outcome=$($result.Outcome) http_status=$($result.HttpStatus)"
    exit 0
}
catch {
    $message = (($_.Exception.Message -replace '[\r\n]+', ' ').Trim())
    if ($message.Length -gt 300) {
        $message = $message.Substring(0, 300)
    }
    Write-Error "ServiceNow integration failed: $message"
    exit 1
}