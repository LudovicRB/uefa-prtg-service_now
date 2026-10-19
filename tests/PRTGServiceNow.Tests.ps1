#requires -Version 5.1
$modulePath = Join-Path $PSScriptRoot '..\PRTGServiceNow.psm1'
Import-Module $modulePath -Force

$moduleName = 'PRTGServiceNow'
$config = [PSCustomObject]@{
    InstanceUrl = 'https://dev.example.invalid'
    CoreId = 'NYON-PRTG'
    OAuthClientId = '<TEST_CLIENT_ID>'
    OAuthClientSecretFile = 'C:\not-a-real-secret.xml'
    OAuthScope = 'network_prtg'
    HttpTimeoutSeconds = 5
    MaxPostAttempts = 2
    LogPath = 'C:\not-a-real-log\integration.log'
}

function New-TestPayload {
    New-AlertPayload -EventType Alert -Status Down -CoreId 'NYON-PRTG' -EventId 'NYON-PRTG:42:test' -DeviceId 'device-42' -DeviceName 'Router A' -SensorId '42' -SensorName 'Ping' -Message 'Packet loss' -Priority '3'
}

function New-HttpException {
    param([int]$StatusCode)
    $exception = New-Object Exception "HTTP $StatusCode"
    $response = New-Object PSObject -Property @{ StatusCode = $StatusCode }
    $exception | Add-Member -MemberType NoteProperty -Name Response -Value $response
    return $exception
}

Describe 'PRTG ServiceNow event contract' {
    It 'maps OPEN to Alert' {
        Get-ActionEventType -Action OPEN | Should Be 'Alert'
    }

    It 'maps RECOVER to Recovery' {
        Get-ActionEventType -Action RECOVER | Should Be 'Recovery'
    }

    It 'preserves an allowed PRTG status' {
        $payload = New-AlertPayload -EventType Alert -Status Warning -CoreId 'NYON-PRTG' -EventId 'event' -DeviceId 'device' -DeviceName 'Device' -SensorId '42' -SensorName 'Sensor' -Message 'Message' -Priority '3'
        $payload.status | Should Be 'Warning'
    }

    It 'builds a stable deduplication key for one sensor' {
        (New-TestPayload).deduplication_key | Should Be 'PRTG:NYON-PRTG:42'
    }

    It 'generates unique event identifiers' {
        $timestamp = [datetime]'2026-09-07T12:00:00Z'
        $first = New-EventIdentifier -CoreId 'NYON-PRTG' -SensorId '42' -TimestampUtc $timestamp
        $second = New-EventIdentifier -CoreId 'NYON-PRTG' -SensorId '42' -TimestampUtc $timestamp
        $first | Should Not Be $second
        $first | Should Match '^NYON-PRTG:42:20260907T1200000000000Z:'
    }

    It 'uses UTC ISO 8601 timestamps' {
        (New-UtcTimestamp -TimestampUtc ([datetime]'2026-09-07T12:00:00Z')) | Should Match '^2026-09-07T12:00:00\.0000000Z$'
    }

    It 'includes all required payload fields and omits empty optional fields' {
        $payload = New-TestPayload
        @('source', 'core_id', 'event_id', 'deduplication_key', 'event_type', 'status', 'event_timestamp_utc', 'sent_timestamp_utc', 'device_id', 'device_name', 'sensor_id', 'sensor_name', 'message', 'priority') | ForEach-Object { ($payload.PSObject.Properties.Name -contains $_) | Should Be $true }
        ($payload.PSObject.Properties.Name -contains 'probe') | Should Be $false
        ($payload.PSObject.Properties.Name -contains 'tags') | Should Be $false
    }

    It 'rejects an HTTP instance URL' {
        { ConvertTo-ServiceNowBaseUri -InstanceUrl 'http://dev.example.invalid' } | Should Throw
    }

    It 'rejects an invalid instance URL' {
        { ConvertTo-ServiceNowBaseUri -InstanceUrl 'not a uri' } | Should Throw
    }
}

Describe 'Scripted REST calls remain offline' {
    BeforeEach {
        Mock Get-OAuthAccessToken { 'test-access-token' } -ModuleName $moduleName
        Mock Invoke-RestMethod { throw 'OAuth HTTP call must be mocked by Get-OAuthAccessToken.' } -ModuleName $moduleName
        Mock Write-IntegrationLog {} -ModuleName $moduleName
        Mock Start-Sleep {} -ModuleName $moduleName
    }

    It 'accepts HTTP 201 without a real network call' {
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 201; Content = '{"status":"created","message":"accepted","alert_sys_id":"test-id"}' } } -ModuleName $moduleName
        $result = Invoke-PrtgServiceNow -Action OPEN -Status Down -SensorId '42' -DeviceId 'device-42' -DeviceName 'Router A' -SensorName 'Ping' -Message 'Packet loss' -Priority '3' -Config $config
        $result.Outcome | Should Be 'Created'
        Assert-MockCalled Get-OAuthAccessToken -ModuleName $moduleName -Times 1 -Exactly -Scope It
        Assert-MockCalled Invoke-WebRequest -ModuleName $moduleName -Times 1 -Exactly -Scope It
        Assert-MockCalled Write-IntegrationLog -ModuleName $moduleName -Times 1 -Exactly -Scope It -ParameterFilter { $Text -notmatch 'test-access-token|TEST_CLIENT_ID' }
    }

    It 'treats the documented duplicate event response as an explicit idempotent result' {
        Mock Invoke-WebRequest { $exception = New-Object Exception 'HTTP 409'; $exception | Add-Member NoteProperty Response (New-Object PSObject -Property @{ StatusCode = 409 }); throw $exception } -ModuleName $moduleName
        $result = Invoke-PrtgServiceNow -Action RECOVER -Status Up -SensorId '42' -DeviceId 'device-42' -DeviceName 'Router A' -SensorName 'Ping' -Message 'Recovered' -Priority '3' -Config $config
        $result.Outcome | Should Be 'Duplicate'
        $result.HttpStatus | Should Be 409
    }

    It 'fails HTTP 400 without retrying' {
        Mock Invoke-WebRequest { $exception = New-Object Exception 'HTTP 400'; $exception | Add-Member NoteProperty Response (New-Object PSObject -Property @{ StatusCode = 400 }); throw $exception } -ModuleName $moduleName
        { Invoke-PrtgServiceNow -Action OPEN -Status Down -SensorId '42' -DeviceId 'device-42' -DeviceName 'Router A' -SensorName 'Ping' -Message 'Packet loss' -Priority '3' -Config $config } | Should Throw
        Assert-MockCalled Invoke-WebRequest -ModuleName $moduleName -Times 1 -Exactly -Scope It
    }

    It 'fails HTTP 401 without retrying' {
        Mock Invoke-WebRequest { $exception = New-Object Exception 'HTTP 401'; $exception | Add-Member NoteProperty Response (New-Object PSObject -Property @{ StatusCode = 401 }); throw $exception } -ModuleName $moduleName
        { Invoke-PrtgServiceNow -Action OPEN -Status Down -SensorId '42' -DeviceId 'device-42' -DeviceName 'Router A' -SensorName 'Ping' -Message 'Packet loss' -Priority '3' -Config $config } | Should Throw
        Assert-MockCalled Invoke-WebRequest -ModuleName $moduleName -Times 1 -Exactly -Scope It
    }

    It 'fails HTTP 404 without retrying' {
        Mock Invoke-WebRequest { $exception = New-Object Exception 'HTTP 404'; $exception | Add-Member NoteProperty Response (New-Object PSObject -Property @{ StatusCode = 404 }); throw $exception } -ModuleName $moduleName
        { Invoke-PrtgServiceNow -Action OPEN -Status Down -SensorId '42' -DeviceId 'device-42' -DeviceName 'Router A' -SensorName 'Ping' -Message 'Packet loss' -Priority '3' -Config $config } | Should Throw
        Assert-MockCalled Invoke-WebRequest -ModuleName $moduleName -Times 1 -Exactly -Scope It
    }

    It 'retries a server error once with the same event request' {
        Mock Invoke-WebRequest { $exception = New-Object Exception 'HTTP 500'; $exception | Add-Member NoteProperty Response (New-Object PSObject -Property @{ StatusCode = 500 }); throw $exception } -ModuleName $moduleName
        { Invoke-PrtgServiceNow -Action OPEN -Status Down -SensorId '42' -DeviceId 'device-42' -DeviceName 'Router A' -SensorName 'Ping' -Message 'Packet loss' -Priority '3' -Config $config } | Should Throw
        Assert-MockCalled Invoke-WebRequest -ModuleName $moduleName -Times 2 -Exactly -Scope It
        Assert-MockCalled Start-Sleep -ModuleName $moduleName -Times 1 -Exactly -Scope It
    }
}

Describe 'Installed notification script remains offline' {
    BeforeEach {
        $env:PRTG_TEST_SCRIPT = (Resolve-Path (Join-Path $PSScriptRoot '..\script\Send-PrtgServiceNowAlert.ps1')).Path
        $env:PRTG_TEST_LOG = Join-Path $TestDrive 'notification.log'
        $env:PRTG_TEST_ATTEMPTS = Join-Path $TestDrive 'attempts.log'
        Remove-Item -LiteralPath $env:PRTG_TEST_LOG, $env:PRTG_TEST_ATTEMPTS -ErrorAction SilentlyContinue
    }

    AfterEach {
        Remove-Item Env:PRTG_TEST_SCRIPT, Env:PRTG_TEST_LOG, Env:PRTG_TEST_ATTEMPTS, Env:PRTG_TEST_SCENARIO -ErrorAction SilentlyContinue
    }

    function Invoke-OfflineNotification {
        param([string]$Scenario)
        $env:PRTG_TEST_SCENARIO = $Scenario
        $child = @'
    Add-Type -AssemblyName System.Security
function Import-Clixml {
    $secret = [guid]::NewGuid().ToString('N')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($secret)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    [PSCustomObject]@{
        TokenUrl = 'https://uefadev.service-now.com/oauth_token.do'
        AlertUrl = 'https://uefadev.service-now.com/api/x_ames2_monitori_0/alerts/network/prtg'
        Scope = 'network_prtg'
        ClientId = [guid]::NewGuid().ToString('N')
        ProtectedClientSecret = [Convert]::ToBase64String($protected)
        CoreId = 'NYON-PRTG'
    }
}
function Invoke-RestMethod { [PSCustomObject]@{ access_token = [guid]::NewGuid().ToString('N') } }
function Start-Sleep { }
function Invoke-WebRequest {
    param($Method, $Uri, $Headers, $ContentType, $Body, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
    $eventId = ([System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json).event_id
    Add-Content -LiteralPath $env:PRTG_TEST_ATTEMPTS -Value $eventId
    $count = @(Get-Content -LiteralPath $env:PRTG_TEST_ATTEMPTS).Count
    if ($env:PRTG_TEST_SCENARIO -eq 'retry' -and $count -eq 1) { $code = 500 }
    elseif ($env:PRTG_TEST_SCENARIO -eq 'throttle' -and $count -eq 1) { $code = 429 }
    elseif ($env:PRTG_TEST_SCENARIO -eq 'duplicate') { $code = 409 }
    elseif ($env:PRTG_TEST_SCENARIO -eq 'reject') { $code = 400 }
    elseif ($env:PRTG_TEST_SCENARIO -eq 'unexpected') { return [PSCustomObject]@{ StatusCode = 202 } }
    else { return [PSCustomObject]@{ StatusCode = 201 } }
    $exception = New-Object System.Exception 'PRIVATE_EXCEPTION_MARKER'
    $exception | Add-Member NoteProperty Response ([PSCustomObject]@{ StatusCode = $code; Content = 'PRIVATE_BODY_MARKER' })
    throw $exception
}
$sensorId = if ($env:PRTG_TEST_SCENARIO -eq 'invalid') { "bad`nINJECTED" } else { '42' }
& $env:PRTG_TEST_SCRIPT -EventType Alert -SensorId $sensorId -DeviceId '12' -DeviceName 'Test' -SensorName 'Test' -Message 'Test' -Priority '3' -ConfigurationPath $env:PRTG_TEST_SCRIPT -LogPath $env:PRTG_TEST_LOG
'@
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($child))
        $output = & powershell.exe -NoProfile -EncodedCommand $encoded 2>&1 | Out-String
        return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }

    It 'accepts 201 without exposing response data' {
        $result = Invoke-OfflineNotification 'success'
        (Get-Content $env:PRTG_TEST_LOG -Raw) | Should Match 'Stage=Post|SUCCESS'
        $result.ExitCode | Should Be 0
        @(Get-Content $env:PRTG_TEST_ATTEMPTS).Count | Should Be 1
        $result.Output | Should Not Match 'PRIVATE_'
    }

    It 'accepts 409 once without exposing response data' {
        $result = Invoke-OfflineNotification 'duplicate'
        $result.ExitCode | Should Be 0
        @(Get-Content $env:PRTG_TEST_ATTEMPTS).Count | Should Be 1
        $result.Output | Should Not Match 'PRIVATE_'
        (Get-Content $env:PRTG_TEST_LOG -Raw) | Should Match 'DUPLICATE'
    }

    It 'does not retry 400 or leak exception and body markers' {
        $result = Invoke-OfflineNotification 'reject'
        $result.ExitCode | Should Be 1
        @(Get-Content $env:PRTG_TEST_ATTEMPTS).Count | Should Be 1
        ($result.Output + (Get-Content $env:PRTG_TEST_LOG -Raw)) | Should Not Match 'PRIVATE_'
    }

    It 'retries 500 with the same event identifier' {
        $result = Invoke-OfflineNotification 'retry'
        $result.ExitCode | Should Be 0
        $attempts = @(Get-Content $env:PRTG_TEST_ATTEMPTS)
        $attempts.Count | Should Be 2
        $attempts[0] | Should Be $attempts[1]
    }

    It 'retries 429 with the same event identifier' {
        $result = Invoke-OfflineNotification 'throttle'
        $result.ExitCode | Should Be 0
        $attempts = @(Get-Content $env:PRTG_TEST_ATTEMPTS)
        $attempts.Count | Should Be 2
        $attempts[0] | Should Be $attempts[1]
    }

    It 'rejects malformed sensor IDs without writing them to the log' {
        $result = Invoke-OfflineNotification 'invalid'
        $result.ExitCode | Should Be 1
        (Get-Content $env:PRTG_TEST_LOG -Raw) | Should Match 'SensorId=invalid'
        (Get-Content $env:PRTG_TEST_LOG -Raw) | Should Not Match 'INJECTED'
        (Test-Path $env:PRTG_TEST_ATTEMPTS) | Should Be $false
    }

    It 'rejects a non-201 successful response' {
        $result = Invoke-OfflineNotification 'unexpected'
        $result.ExitCode | Should Be 1
        @(Get-Content $env:PRTG_TEST_ATTEMPTS).Count | Should Be 1
    }
}