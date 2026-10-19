#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Alert', 'Recovery')]
    [string]$EventType,

    [Parameter(Mandatory = $true)]
    [string]$SensorId,

    [Parameter(Mandatory = $true)]
    [string]$DeviceId,

    [Parameter(Mandatory = $true)]
    [string]$DeviceName,

    [string]$DeviceAddress = '',

    [Parameter(Mandatory = $true)]
    [string]$SensorName,

    [string]$SensorType = '',

    [Parameter(Mandatory = $true)]
    [string]$Message,

    [string]$Probe = '',

    [string]$Group = '',

    [Parameter(Mandatory = $true)]
    [string]$Priority,

    [string]$Tags = '',

    [string]$PrtgUrl = '',

    [string]$ConfigurationPath = 'C:\ProgramData\PRTG-ServiceNow\config.xml',

    [string]$LogPath = 'C:\ProgramData\PRTG-ServiceNow\ServiceNow-notification.log',

    [switch]$NoSend
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

function Write-SafeLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $logDirectory = Split-Path -Path $LogPath -Parent

    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item `
            -Path $logDirectory `
            -ItemType Directory `
            -Force |
            Out-Null
    }

    $logTimestamp = (Get-Date).ToUniversalTime().ToString(
        'yyyy-MM-ddTHH:mm:ss.fffZ'
    )

    Add-Content `
        -LiteralPath $LogPath `
        -Value "$logTimestamp $Text" `
        -Encoding UTF8
}

function Get-HttpStatusCode {
    param([Parameter(Mandatory = $true)][object]$Exception)

    $responseProperty = $Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) {
        return $null
    }

    $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
    if ($null -eq $statusProperty) {
        return $null
    }

    try { return [int]$statusProperty.Value }
    catch { return $null }
}

$configuration = $null
$tokenUrl = $null
$alertUrl = $null
$scope = $null
$clientId = $null
$protectedClientSecret = $null
$coreId = $null
$protectedSecretBytes = $null
$secretBytes = $null
$plainClientSecret = $null
$tokenRequest = $null
$tokenResponse = $null
$accessToken = $null
$headers = $null
$jsonPayload = $null
$response = $null
$phase = 'Configuration'

try {
    if (-not (Test-Path -LiteralPath $ConfigurationPath)) {
        throw "Configuration introuvable : $ConfigurationPath"
    }

    $configuration = Import-Clixml -LiteralPath $ConfigurationPath

    $tokenUrl = Get-ConfigurationValue `
        -Configuration $configuration `
        -Name 'TokenUrl'

    $alertUrl = Get-ConfigurationValue `
        -Configuration $configuration `
        -Name 'AlertUrl'

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
        throw 'Token URL inattendue.'
    }

    if ($alertUrl -ne 'https://uefadev.service-now.com/api/x_ames2_monitori_0/alerts/network/prtg') {
        throw 'Alert URL inattendue.'
    }

    if ($scope -ne 'network_prtg') {
        throw 'Scope OAuth inattendu.'
    }

    if ($coreId -ne 'NYON-PRTG') {
        throw 'Core ID inattendu.'
    }

    if ($SensorId -notmatch '^\d+$') {
        throw 'Le Sensor ID doit etre numerique.'
    }

    if ($DeviceId.Trim().Length -eq 0) {
        throw 'Le Device ID ne peut pas etre vide.'
    }

    if ($DeviceName.Trim().Length -eq 0) {
        throw 'Le Device Name ne peut pas etre vide.'
    }

    if ($SensorName.Trim().Length -eq 0) {
        throw 'Le Sensor Name ne peut pas etre vide.'
    }

    if ($Message.Trim().Length -eq 0) {
        throw 'Le Message ne peut pas etre vide.'
    }

    if ($Priority.Trim().Length -eq 0) {
        throw 'La Priority ne peut pas etre vide.'
    }

    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor `
        [Net.SecurityProtocolType]::Tls12

    $eventDateUtc = (Get-Date).ToUniversalTime()

    $eventTimestampUtc = $eventDateUtc.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffZ'
    )

    $eventIdTimestamp = $eventDateUtc.ToString(
        'yyyyMMddTHHmmssfffZ'
    )

    $eventId = '{0}-{1}-{2}-{3}' -f `
        $coreId,
        $SensorId,
        $eventIdTimestamp,
        ([guid]::NewGuid().ToString('N'))

    $deduplicationKey = 'PRTG:{0}:{1}' -f `
        $coreId,
        $SensorId

    if ($EventType -eq 'Alert') {
        $status = 'Down'
    }
    else {
        $status = 'Up'
    }

    $payload = [ordered]@{
        source              = 'PRTG'
        core_id             = $coreId
        event_id            = $eventId
        deduplication_key   = $deduplicationKey
        event_type          = $EventType
        status              = $status
        event_timestamp_utc = $eventTimestampUtc
        sent_timestamp_utc  = (Get-Date).ToUniversalTime().ToString(
            'yyyy-MM-ddTHH:mm:ss.fffZ'
        )
        probe               = $Probe
        group               = $Group
        device_id           = $DeviceId
        device_name         = $DeviceName
        device_address      = $DeviceAddress
        sensor_id           = $SensorId
        sensor_name         = $SensorName
        sensor_type         = $SensorType
        message             = $Message
        priority            = $Priority
        tags                = $Tags
        prtg_url            = $PrtgUrl
    }

    $jsonPayload = $payload | ConvertTo-Json -Depth 5

    Write-SafeLog (
        'START EventType={0} Status={1} SensorId={2} EventId={3} DeduplicationKey={4} NoSend={5}' -f `
            $EventType,
            $status,
            $SensorId,
            $eventId,
            $deduplicationKey,
            $NoSend.IsPresent
    )

    if ($NoSend.IsPresent) {
        Write-Host ''
        Write-Host 'DRY-RUN uniquement. Aucun envoi vers ServiceNow.' `
            -ForegroundColor Yellow
        Write-Host ''
        Write-Host "Deduplication key : $deduplicationKey" `
            -ForegroundColor Green
        Write-Host ''

        Write-SafeLog (
            'DRY-RUN EventType={0} SensorId={1} EventId={2}' -f `
                $EventType,
                $SensorId,
                $eventId
        )

        exit 0
    }

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

    $phase = 'OAuth'
    $tokenResponse = Invoke-RestMethod `
        -Method Post `
        -Uri $tokenUrl `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $tokenRequest `
        -UseBasicParsing `
        -TimeoutSec 30

    $accessTokenProperty = `
        $tokenResponse.PSObject.Properties['access_token']

    if ($null -eq $accessTokenProperty) {
        throw 'La reponse OAuth ne contient pas access_token.'
    }

    $accessToken = [string]$accessTokenProperty.Value

    if ($accessToken.Length -eq 0) {
        throw 'Le jeton OAuth recu est vide.'
    }

    $headers = @{
        Authorization = "Bearer $accessToken"
        Accept        = 'application/json'
    }

    $phase = 'Post'
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Method Post `
                -Uri $alertUrl `
                -Headers $headers `
                -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($jsonPayload)) `
                -UseBasicParsing `
                -TimeoutSec 60 `
                -ErrorAction Stop

            if ([int]$response.StatusCode -ne 201) {
                throw 'Statut HTTP de succes inattendu.'
            }

            Write-SafeLog (
                'SUCCESS EventType={0} Status={1} SensorId={2} EventId={3} HTTP=201' -f `
                    $EventType, $status, $SensorId, $eventId
            )
            Write-Host 'Envoi ServiceNow reussi. HTTP=201' -ForegroundColor Green
            exit 0
        }
        catch {
            $statusCode = Get-HttpStatusCode -Exception $_.Exception
            if ($statusCode -eq 409) {
                Write-SafeLog (
                    'DUPLICATE EventType={0} SensorId={1} EventId={2} HTTP=409' -f `
                        $EventType, $SensorId, $eventId
                )
                Write-Host 'Evenement deja recu. HTTP=409' -ForegroundColor Green
                exit 0
            }

            $networkFailure = $_.Exception -is [System.Net.WebException] -and
                $null -eq $statusCode
            $transient = $networkFailure -or $statusCode -eq 429 -or
                ($statusCode -ge 500 -and $statusCode -lt 600)
            if (-not $transient -or $attempt -eq 2) {
                throw
            }

            Write-SafeLog (
                'RETRY EventType={0} SensorId={1} EventId={2} Attempt={3} HTTP={4}' -f `
                    $EventType, $SensorId, $eventId, $attempt, $statusCode
            )
            Start-Sleep -Seconds 2
        }
    }
}
catch {
    $statusCode = Get-HttpStatusCode -Exception $_.Exception
    $httpStatus = if ($null -eq $statusCode) { '' } else { [string]$statusCode }
    $safeSensorId = if ($SensorId -match '^\d+$') { $SensorId } else { 'invalid' }

    Write-SafeLog (
        'ERROR EventType={0} SensorId={1} Stage={2} HTTP={3}' -f `
            $EventType,
            $safeSensorId,
            $phase,
            $httpStatus
    )

    Write-Host ''
    Write-Host 'Echec de la notification ServiceNow.' -ForegroundColor Red

    if ($httpStatus.Length -gt 0) {
        Write-Host "HTTP   : $httpStatus" -ForegroundColor Red
    }

    Write-Host ''
    exit 1
}
finally {
    $headers = $null
    $accessToken = $null
    $tokenRequest = $null
    $tokenResponse = $null
    $plainClientSecret = $null
    $secretBytes = $null
    $protectedSecretBytes = $null
    $protectedClientSecret = $null
    $configuration = $null
}