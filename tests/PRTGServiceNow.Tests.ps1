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