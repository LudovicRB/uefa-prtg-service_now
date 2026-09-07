Set-StrictMode -Version Latest

function Get-PropertyValue {
    param([Parameter(Mandatory = $true)][object]$Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureString)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Import-SecretText {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Secret file not found: $Path" }
    $secret = Import-Clixml -LiteralPath $Path
    if ($secret -is [Security.SecureString]) { return Convert-SecureStringToPlainText -SecureString $secret }
    throw "Secret file must contain a SecureString: $Path"
}

function ConvertTo-ServiceNowBaseUri {
    param([Parameter(Mandatory = $true)][string]$InstanceUrl)
    $uri = $null
    if (-not [Uri]::TryCreate($InstanceUrl, [UriKind]::Absolute, [ref]$uri)) { throw 'InstanceUrl must be an absolute URI.' }
    if ($uri.Scheme -ne 'https') { throw 'InstanceUrl must use HTTPS.' }
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo)) { throw 'InstanceUrl must not contain user credentials.' }
    if (-not [string]::IsNullOrWhiteSpace($uri.Query) -or -not [string]::IsNullOrWhiteSpace($uri.Fragment)) { throw 'InstanceUrl must not contain a query string or fragment.' }
    $builder = New-Object UriBuilder $uri
    $builder.Path = $builder.Path.TrimEnd('/')
    $builder.Query = ''
    $builder.Fragment = ''
    return $builder.Uri
}

function Get-ActionEventType {
    param([Parameter(Mandatory = $true)][ValidateSet('OPEN', 'RECOVER')][string]$Action)
    if ($Action -eq 'OPEN') { return 'Alert' }
    return 'Recovery'
}

function New-UtcTimestamp {
    param([datetime]$TimestampUtc = [datetime]::UtcNow)
    return $TimestampUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
}

function New-EventIdentifier {
    param([Parameter(Mandatory = $true)][string]$CoreId, [Parameter(Mandatory = $true)][string]$SensorId, [datetime]$TimestampUtc = [datetime]::UtcNow)
    $timestamp = $TimestampUtc.ToUniversalTime().ToString('yyyyMMddTHHmmssfffffffZ', [Globalization.CultureInfo]::InvariantCulture)
    return '{0}:{1}:{2}:{3}' -f $CoreId, $SensorId, $timestamp, ([Guid]::NewGuid().ToString('N'))
}

function New-ScriptedRestUri {
    param([Parameter(Mandatory = $true)][Uri]$BaseUri, [string]$SourceEventId = '')
    $path = '/api/x_ames2_monitori_0/alerts/network/prtg'
    if (-not [string]::IsNullOrWhiteSpace($SourceEventId)) { $path = '{0}/{1}' -f $path, [Uri]::EscapeDataString($SourceEventId) }
    return New-Object Uri ($BaseUri, $path)
}

function New-AlertPayload {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Alert', 'Recovery')][string]$EventType,
        [Parameter(Mandatory = $true)][ValidateSet('Down', 'Unknown', 'Unusual', 'Up', 'Warning')][string]$Status,
        [Parameter(Mandatory = $true)][string]$CoreId, [Parameter(Mandatory = $true)][string]$EventId,
        [Parameter(Mandatory = $true)][string]$DeviceId, [Parameter(Mandatory = $true)][string]$DeviceName,
        [Parameter(Mandatory = $true)][string]$SensorId, [Parameter(Mandatory = $true)][string]$SensorName,
        [Parameter(Mandatory = $true)][string]$Message, [Parameter(Mandatory = $true)][string]$Priority,
        [string]$Probe = '', [string]$Group = '', [string]$DeviceAddress = '', [string]$SensorType = '',
        [string]$Tags = '', [string]$PrtgUrl = '', [datetime]$EventTimestampUtc = [datetime]::UtcNow,
        [datetime]$SentTimestampUtc = [datetime]::UtcNow
    )
    $requiredValues = @{ core_id = $CoreId; event_id = $EventId; device_id = $DeviceId; device_name = $DeviceName; sensor_id = $SensorId; sensor_name = $SensorName; message = $Message; priority = $Priority }
    foreach ($name in $requiredValues.Keys) { if ([string]::IsNullOrWhiteSpace([string]$requiredValues[$name])) { throw "Required payload field is empty: $name" } }
    $payload = [ordered]@{
        source = 'PRTG'; core_id = $CoreId; event_id = $EventId; deduplication_key = 'PRTG:{0}:{1}' -f $CoreId, $SensorId
        event_type = $EventType; status = $Status; event_timestamp_utc = New-UtcTimestamp -TimestampUtc $EventTimestampUtc
        sent_timestamp_utc = New-UtcTimestamp -TimestampUtc $SentTimestampUtc; device_id = $DeviceId; device_name = $DeviceName
        sensor_id = $SensorId; sensor_name = $SensorName; message = $Message; priority = $Priority
    }
    $optionalValues = [ordered]@{ probe = $Probe; group = $Group; device_address = $DeviceAddress; sensor_type = $SensorType; tags = $Tags; prtg_url = $PrtgUrl }
    foreach ($name in $optionalValues.Keys) { if (-not [string]::IsNullOrWhiteSpace([string]$optionalValues[$name])) { $payload[$name] = $optionalValues[$name] } }
    return [PSCustomObject]$payload
}

function Get-OAuthAccessToken {
    param([Parameter(Mandatory = $true)][Uri]$BaseUri, [Parameter(Mandatory = $true)][object]$Config)
    $clientId = [string](Get-PropertyValue -Object $Config -Name 'OAuthClientId' -Default '')
    $secretFile = [string](Get-PropertyValue -Object $Config -Name 'OAuthClientSecretFile' -Default '')
    $scope = [string](Get-PropertyValue -Object $Config -Name 'OAuthScope' -Default 'network_prtg')
    $timeout = [int](Get-PropertyValue -Object $Config -Name 'HttpTimeoutSeconds' -Default 30)
    if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($secretFile)) { throw 'OAuthClientId and OAuthClientSecretFile are required.' }
    if ($timeout -lt 1) { throw 'HttpTimeoutSeconds must be greater than zero.' }
    $tokenUri = New-Object Uri ($BaseUri, '/oauth_token.do')
    $response = Invoke-RestMethod -Method Post -Uri $tokenUri -ContentType 'application/x-www-form-urlencoded' -Body @{ grant_type = 'client_credentials'; client_id = $clientId; client_secret = Import-SecretText -Path $secretFile; scope = $scope } -TimeoutSec $timeout -ErrorAction Stop
    if ($null -eq $response.access_token -or [string]::IsNullOrWhiteSpace([string]$response.access_token)) { throw 'OAuth response does not contain an access token.' }
    return [string]$response.access_token
}

function Get-HttpStatusCode {
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    try { if ($null -ne $ErrorRecord.Exception.Response) { return [int]$ErrorRecord.Exception.Response.StatusCode } } catch {}
    return $null
}

function Get-SafeErrorMessage {
    param([Parameter(Mandatory = $true)][string]$Message)
    $sanitized = ($Message -replace '[\r\n]+', ' ').Trim()
    if ($sanitized.Length -gt 300) { return $sanitized.Substring(0, 300) }
    return $sanitized
}

function Write-IntegrationLog {
    param([Parameter(Mandatory = $true)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level, [Parameter(Mandatory = $true)][string]$LogPath, [Parameter(Mandatory = $true)][string]$Text)
    $directory = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ('{0} [{1}] {2}' -f (New-UtcTimestamp), $Level, (Get-SafeErrorMessage -Message $Text))
}

function Invoke-ScriptedRestAlert {
    param([Parameter(Mandatory = $true)][Uri]$BaseUri, [Parameter(Mandatory = $true)][object]$Config, [Parameter(Mandatory = $true)][object]$Payload, [Parameter(Mandatory = $true)][string]$LogPath)
    $timeout = [int](Get-PropertyValue -Object $Config -Name 'HttpTimeoutSeconds' -Default 30)
    $maxAttempts = [int](Get-PropertyValue -Object $Config -Name 'MaxPostAttempts' -Default 2)
    if ($timeout -lt 1 -or $maxAttempts -lt 1) { throw 'HttpTimeoutSeconds and MaxPostAttempts must be greater than zero.' }
    $uri = New-ScriptedRestUri -BaseUri $BaseUri
    $logicalPath = $uri.AbsolutePath
    $body = $Payload | ConvertTo-Json -Depth 5 -Compress
    $accessToken = Get-OAuthAccessToken -BaseUri $BaseUri -Config $Config
    $headers = @{ Accept = 'application/json'; Authorization = "Bearer $accessToken" }
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Method Post -Uri $uri -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $body -UseBasicParsing -TimeoutSec $timeout -ErrorAction Stop
            if ([int]$response.StatusCode -ne 201) { throw "Unexpected successful HTTP status: $($response.StatusCode)" }
            $result = $response.Content | ConvertFrom-Json
            Write-IntegrationLog -Level 'INFO' -LogPath $LogPath -Text "method=POST path=$logicalPath status=201 category=created event_id=$($Payload.event_id) deduplication_key=$($Payload.deduplication_key)"
            return [PSCustomObject]@{ Outcome = 'Created'; HttpStatus = 201; Response = $result }
        }
        catch {
            $statusCode = Get-HttpStatusCode -ErrorRecord $_
            if ($statusCode -eq 409) {
                Write-IntegrationLog -Level 'INFO' -LogPath $LogPath -Text "method=POST path=$logicalPath status=409 category=duplicate_event event_id=$($Payload.event_id) deduplication_key=$($Payload.deduplication_key) message=$(Get-SafeErrorMessage -Message $_.Exception.Message)"
                return [PSCustomObject]@{ Outcome = 'Duplicate'; HttpStatus = 409; Response = $null }
            }
            $isTransient = ($null -eq $statusCode) -or ($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -lt 600)
            $category = if ($null -eq $statusCode) { 'network' } elseif ($statusCode -eq 400) { 'invalid_payload' } elseif ($statusCode -eq 401) { 'unauthorized' } elseif ($statusCode -eq 404) { 'invalid_route' } elseif ($statusCode -ge 500) { 'server' } else { 'http_error' }
            Write-IntegrationLog -Level $(if ($isTransient) { 'WARN' } else { 'ERROR' }) -LogPath $LogPath -Text "method=POST path=$logicalPath status=$statusCode category=$category event_id=$($Payload.event_id) deduplication_key=$($Payload.deduplication_key) message=$(Get-SafeErrorMessage -Message $_.Exception.Message)"
            if (-not $isTransient -or $attempt -ge $maxAttempts) { throw }
            Start-Sleep -Seconds ([Math]::Min(10, [Math]::Pow(2, $attempt)))
        }
    }
}

function Invoke-PrtgServiceNow {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('OPEN', 'RECOVER')][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('Down', 'Unknown', 'Unusual', 'Up', 'Warning')][string]$Status,
        [Parameter(Mandatory = $true)][string]$SensorId, [Parameter(Mandatory = $true)][string]$DeviceId,
        [Parameter(Mandatory = $true)][string]$DeviceName, [Parameter(Mandatory = $true)][string]$SensorName,
        [Parameter(Mandatory = $true)][string]$Message, [Parameter(Mandatory = $true)][string]$Priority,
        [Parameter(Mandatory = $true)][object]$Config, [string]$Probe = '', [string]$Group = '',
        [string]$DeviceAddress = '', [string]$SensorType = '', [string]$Tags = '', [string]$PrtgUrl = ''
    )
    if ($SensorId -notmatch '^\d+$') { throw 'SensorId must be numeric.' }
    $baseUri = ConvertTo-ServiceNowBaseUri -InstanceUrl ([string](Get-PropertyValue -Object $Config -Name 'InstanceUrl' -Default ''))
    $coreId = [string](Get-PropertyValue -Object $Config -Name 'CoreId' -Default '')
    $logPath = [string](Get-PropertyValue -Object $Config -Name 'LogPath' -Default 'C:\ProgramData\PRTG-ServiceNow\Logs\prtg-servicenow.log')
    if ([string]::IsNullOrWhiteSpace($coreId)) { throw 'CoreId is required.' }
    $eventTime = [datetime]::UtcNow
    $payload = New-AlertPayload -EventType (Get-ActionEventType -Action $Action) -Status $Status -CoreId $coreId -EventId (New-EventIdentifier -CoreId $coreId -SensorId $SensorId -TimestampUtc $eventTime) -DeviceId $DeviceId -DeviceName $DeviceName -SensorId $SensorId -SensorName $SensorName -Message $Message -Priority $Priority -Probe $Probe -Group $Group -DeviceAddress $DeviceAddress -SensorType $SensorType -Tags $Tags -PrtgUrl $PrtgUrl -EventTimestampUtc $eventTime -SentTimestampUtc ([datetime]::UtcNow)
    return Invoke-ScriptedRestAlert -BaseUri $baseUri -Config $Config -Payload $payload -LogPath $logPath
}

Export-ModuleMember -Function Invoke-PrtgServiceNow, New-AlertPayload, New-EventIdentifier, New-UtcTimestamp, Get-ActionEventType, ConvertTo-ServiceNowBaseUri, New-ScriptedRestUri