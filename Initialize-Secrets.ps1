#requires -Version 5.1
<#+
.SYNOPSIS
  Stores the ServiceNow OAuth client secret outside the repository.

.DESCRIPTION
  The resulting CLIXML file is encrypted for the Windows user and computer
  that create it. Run this script as the PRTG execution account.
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory = 'C:\ProgramData\PRTG-ServiceNow',
    [string]$AllowedIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-RestrictedAcl {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Identity)

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }

    $identities = @($Identity, 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators') | Select-Object -Unique
    foreach ($account in $identities) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($account, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

$workspacePath = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
$targetPath = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if ($targetPath -eq $workspacePath -or $targetPath.StartsWith($workspacePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be outside the workspace.'
}

New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
Set-RestrictedAcl -Path $targetPath -Identity $AllowedIdentity

$secretPath = Join-Path $targetPath 'servicenow-oauth-client-secret.xml'
$clientSecret = Read-Host 'ServiceNow OAuth client secret' -AsSecureString
$clientSecret | Export-Clixml -LiteralPath $secretPath -Force
Set-RestrictedAcl -Path $secretPath -Identity $AllowedIdentity

Write-Host "Secret file created: $secretPath"
Write-Host 'Use it only under the same Windows account and on the same computer that created it.'