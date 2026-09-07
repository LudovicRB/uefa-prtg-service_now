#requires -Version 5.1
<#+
.SYNOPSIS
  Sends one explicitly approved pilot event to the ServiceNow DEV API.

.DESCRIPTION
  This is a manual integration test. It is not a Pester test and must never be
  run against production. It prompts before sending the single real request.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [switch]$AllowDevRequest,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [ValidateSet('DEV')]
    [string]$EnvironmentName = 'DEV',

    [ValidateSet('OPEN', 'RECOVER')]
    [string]$Action = 'OPEN',

    [ValidateSet('Down', 'Unknown', 'Unusual', 'Up', 'Warning')]
    [string]$Status = 'Down',

    [string]$SensorId = '999999',
    [string]$DeviceId = 'PRTG-DEV-TEST',
    [string]$Device = 'PRTG DEV test device',
    [string]$Sensor = 'Scripted REST API validation',
    [string]$Message = 'Manual DEV integration test. Do not use for production monitoring.',
    [string]$Priority = '3'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $AllowDevRequest) {
    throw 'This manual DEV test requires -AllowDevRequest and an interactive confirmation.'
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Configuration file not found: $ConfigPath"
}

$modulePath = Join-Path $PSScriptRoot 'PRTGServiceNow.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$baseUri = ConvertTo-ServiceNowBaseUri -InstanceUrl $config.InstanceUrl
Write-Host "Target environment: $EnvironmentName ($($baseUri.Host))"

if (-not $PSCmdlet.ShouldProcess("$($baseUri.Host) ($EnvironmentName)", 'Send one pilot PRTG event')) {
    return
}
$confirmation = Read-Host 'Type DEV to send the pilot event'
if ($confirmation -cne 'DEV') {
    throw 'Manual confirmation did not match DEV. No request was sent.'
}

$result = Invoke-PrtgServiceNow -Action $Action -Status $Status -SensorId $SensorId -DeviceId $DeviceId -DeviceName $Device -SensorName $Sensor -Message $Message -Priority $Priority -Config $config
Write-Host "Completed outcome=$($result.Outcome) http_status=$($result.HttpStatus)"
if ($null -ne $result.Response) {
    Write-Host "Response status: $($result.Response.status)"
    Write-Host "Alert identifier: $($result.Response.alert_sys_id)"
}