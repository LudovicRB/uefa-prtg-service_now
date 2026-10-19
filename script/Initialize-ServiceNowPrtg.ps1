#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ConfigurationPath = 'C:\ProgramData\PRTG-ServiceNow\config.xml'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security

Write-Host ''
Write-Host 'Configuration OAuth PRTG vers ServiceNow DEV' -ForegroundColor Cyan
Write-Host 'Les informations sensibles ne seront pas affichees.' -ForegroundColor Cyan
Write-Host ''

$configurationDirectory = Split-Path -Path $ConfigurationPath -Parent

if (-not (Test-Path -LiteralPath $configurationDirectory)) {
    New-Item `
        -Path $configurationDirectory `
        -ItemType Directory `
        -Force |
        Out-Null
}

$clientId = Read-Host 'Client ID'

if ($null -eq $clientId) {
    throw 'Le Client ID ne peut pas etre vide.'
}

$clientId = $clientId.Trim()

if ($clientId.Length -eq 0) {
    throw 'Le Client ID ne peut pas etre vide.'
}

$secureClientSecret = Read-Host 'Client Secret' -AsSecureString

if ($null -eq $secureClientSecret) {
    throw 'Le Client Secret ne peut pas etre vide.'
}

$temporaryCredential = New-Object `
    -TypeName System.Management.Automation.PSCredential `
    -ArgumentList 'PRTG-ServiceNow', $secureClientSecret

$plainClientSecret = $temporaryCredential.GetNetworkCredential().Password

if ($null -eq $plainClientSecret) {
    throw 'Le Client Secret ne peut pas etre vide.'
}

if ($plainClientSecret.Length -eq 0) {
    throw 'Le Client Secret ne peut pas etre vide.'
}

$secretBytes = [System.Text.Encoding]::UTF8.GetBytes(
    $plainClientSecret
)

$protectedSecretBytes = `
    [System.Security.Cryptography.ProtectedData]::Protect(
        $secretBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )

$protectedSecret = [System.Convert]::ToBase64String(
    $protectedSecretBytes
)

$configuration = [ordered]@{
    InstanceUrl           = 'https://uefadev.service-now.com'
    TokenUrl              = 'https://uefadev.service-now.com/oauth_token.do'
    AlertUrl              = 'https://uefadev.service-now.com/api/x_ames2_monitori_0/alerts/network/prtg'
    Scope                 = 'network_prtg'
    ClientId              = $clientId
    ProtectedClientSecret = $protectedSecret
    CoreId                = 'NYON-PRTG'
}

$configuration |
    Export-Clixml `
        -LiteralPath $ConfigurationPath `
        -Force

$plainClientSecret = $null
$secureClientSecret = $null
$temporaryCredential = $null
$secretBytes = $null
$protectedSecretBytes = $null
$protectedSecret = $null
$configuration = $null

if (-not (Test-Path -LiteralPath $ConfigurationPath)) {
    throw "Le fichier de configuration n'a pas ete cree."
}

$createdFile = Get-Item -LiteralPath $ConfigurationPath

if ($createdFile.Length -le 0) {
    throw 'Le fichier de configuration est vide.'
}

Write-Host ''
Write-Host 'Configuration enregistree avec succes.' -ForegroundColor Green
Write-Host "Fichier : $ConfigurationPath"
Write-Host "Taille  : $($createdFile.Length) octets"
Write-Host ''
Write-Host 'Le Client Secret est protege avec Windows DPAPI LocalMachine.' `
    -ForegroundColor Green
Write-Host 'Il ne sera pas affiche dans les logs.' `
    -ForegroundColor Green
Write-Host ''