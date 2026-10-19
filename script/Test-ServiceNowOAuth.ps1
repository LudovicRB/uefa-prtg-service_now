#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ConfigurationPath = 'C:\ProgramData\PRTG-ServiceNow\config.xml'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security

function Get-ConfigurationValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Configuration,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $value = $null
    $valueWasFound = $false

    if ($Configuration -is [System.Collections.IDictionary]) {
        if ($Configuration.Contains($Name)) {
            $value = $Configuration[$Name]
            $valueWasFound = $true
        }
    }

    if (-not $valueWasFound) {
        $property = $Configuration.PSObject.Properties[$Name]

        if ($null -ne $property) {
            $value = $property.Value
            $valueWasFound = $true
        }
    }

    if (-not $valueWasFound) {
        throw "Propriete absente de la configuration : $Name"
    }

    $textValue = [string]$value

    if ($null -eq $textValue) {
        throw "Valeur vide dans la configuration : $Name"
    }

    if ($textValue.Trim().Length -eq 0) {
        throw "Valeur vide dans la configuration : $Name"
    }

    return $textValue
}

$configuration = $null
$tokenUrl = $null
$scope = $null
$clientId = $null
$protectedClientSecret = $null
$coreId = $null
$protectedSecretBytes = $null
$secretBytes = $null
$plainClientSecret = $null
$tokenRequest = $null
$tokenResponse = $null

try {
    Write-Host ''
    Write-Host 'Test OAuth PRTG vers ServiceNow DEV' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-Path -LiteralPath $ConfigurationPath)) {
        throw "Configuration introuvable : $ConfigurationPath"
    }

    $configuration = Import-Clixml -LiteralPath $ConfigurationPath

    $tokenUrl = Get-ConfigurationValue `
        -Configuration $configuration `
        -Name 'TokenUrl'

    $scope = Get-ConfigurationValue `
        -Configuration $configuration `
        -Name 'Scope'

    $clientId = Get-ConfigurationValue `
        -Configuration $configuration `
        -Name 'ClientId'

    $protectedClientSecret = Get-ConfigurationValue `
        -Configuration $configuration `
        -Name 'ProtectedClientSecret'

    $coreId = Get-ConfigurationValue `
        -Configuration $configuration `
        -Name 'CoreId'

    if ($tokenUrl -ne 'https://uefadev.service-now.com/oauth_token.do') {
        throw "Token URL inattendue : $tokenUrl"
    }

    if ($scope -ne 'network_prtg') {
        throw "Scope OAuth inattendu : $scope"
    }

    if ($coreId -ne 'NYON-PRTG') {
        throw "Core ID inattendu : $coreId"
    }

    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor `
        [Net.SecurityProtocolType]::Tls12

    $protectedSecretBytes = [System.Convert]::FromBase64String(
        $protectedClientSecret
    )

    $secretBytes = `
        [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protectedSecretBytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        )

    $plainClientSecret = [System.Text.Encoding]::UTF8.GetString(
        $secretBytes
    )

    if ($null -eq $plainClientSecret) {
        throw 'Impossible de dechiffrer le Client Secret.'
    }

    if ($plainClientSecret.Length -eq 0) {
        throw 'Le Client Secret dechiffre est vide.'
    }

    $tokenRequest = @{
        grant_type    = 'client_credentials'
        client_id     = $clientId
        client_secret = $plainClientSecret
        scope         = $scope
    }

    $tokenResponse = Invoke-RestMethod `
        -Method Post `
        -Uri $tokenUrl `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $tokenRequest `
        -UseBasicParsing `
        -TimeoutSec 30

    $accessTokenProperty = $tokenResponse.PSObject.Properties['access_token']

    if ($null -eq $accessTokenProperty) {
        throw 'La reponse OAuth ne contient pas la propriete access_token.'
    }

    $accessToken = [string]$accessTokenProperty.Value

    if ($accessToken.Length -eq 0) {
        throw 'Le jeton OAuth recu est vide.'
    }

    $tokenType = ''
    $returnedScope = ''
    $expiresIn = ''

    $tokenTypeProperty = $tokenResponse.PSObject.Properties['token_type']
    $scopeProperty = $tokenResponse.PSObject.Properties['scope']
    $expiresProperty = $tokenResponse.PSObject.Properties['expires_in']

    if ($null -ne $tokenTypeProperty) {
        $tokenType = [string]$tokenTypeProperty.Value
    }

    if ($null -ne $scopeProperty) {
        $returnedScope = [string]$scopeProperty.Value
    }

    if ($null -ne $expiresProperty) {
        $expiresIn = [string]$expiresProperty.Value
    }

    Write-Host 'Authentification OAuth reussie.' -ForegroundColor Green
    Write-Host "Token type : $tokenType"
    Write-Host "Scope      : $returnedScope"
    Write-Host "Expires in : $expiresIn secondes"
    Write-Host ''
    Write-Host 'Le jeton OAuth n''a pas ete affiche.' -ForegroundColor Green
    Write-Host ''

    exit 0
}
catch {
    $currentException = $_.Exception
    $httpStatus = ''
    $responseBody = ''

    Write-Host ''
    Write-Host 'Echec du test OAuth.' -ForegroundColor Red
    Write-Host "Erreur : $($currentException.Message)" -ForegroundColor Red

    $responseProperty = $currentException.PSObject.Properties['Response']

    if ($null -ne $responseProperty) {
        $httpResponse = $responseProperty.Value

        if ($null -ne $httpResponse) {
            $statusCodeProperty = $httpResponse.PSObject.Properties['StatusCode']

            if ($null -ne $statusCodeProperty) {
                try {
                    $httpStatus = [int]$statusCodeProperty.Value
                    Write-Host "HTTP : $httpStatus" -ForegroundColor Red
                }
                catch {
                    $httpStatus = [string]$statusCodeProperty.Value
                    Write-Host "HTTP : $httpStatus" -ForegroundColor Red
                }
            }

            try {
                $responseStream = $httpResponse.GetResponseStream()

                if ($null -ne $responseStream) {
                    $reader = New-Object System.IO.StreamReader(
                        $responseStream
                    )

                    try {
                        $responseBody = $reader.ReadToEnd()
                    }
                    finally {
                        $reader.Dispose()
                        $responseStream.Dispose()
                    }
                }
            }
            catch {
                $responseBody = ''
            }
        }
    }

    if ($responseBody.Length -gt 0) {
        if ($responseBody.Length -gt 1000) {
            $responseBody = $responseBody.Substring(0, 1000)
        }

        Write-Host "Reponse : $responseBody" -ForegroundColor Red
    }

    Write-Host ''
    exit 1
}
finally {
    $tokenRequest = $null
    $tokenResponse = $null
    $plainClientSecret = $null
    $secretBytes = $null
    $protectedSecretBytes = $null
    $protectedClientSecret = $null
    $clientId = $null
    $configuration = $null
}