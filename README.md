# PRTG to ServiceNow

PowerShell 5.1 integration that sends PRTG events to the ServiceNow Scripted REST API. ServiceNow owns alert creation, deduplication, updates, and recovery processing.

## Files

- `PRTG-ServiceNow.ps1`: PRTG entry point. Deploy it with `PRTGServiceNow.psm1` in the same directory.
- `PRTGServiceNow.psm1`: OAuth, payload, logging, and HTTP logic.
- `config.example.json`: non-sensitive configuration template.
- `Initialize-Secrets.ps1`: creates the OAuth client-secret CLIXML outside this workspace.
- `tests/PRTGServiceNow.Tests.ps1`: offline Pester 3.4.0 tests.
- `Test-ServiceNowScriptedRestApi.ps1`: protected, manual DEV pilot only.

## Prerequisites and setup

The supported runtime is Windows PowerShell 5.1. Copy `config.example.json` to `C:\ProgramData\PRTG-ServiceNow\config.json`, provide the approved ServiceNow instance URL and OAuth client ID, then run `Initialize-Secrets.ps1` as the Windows account used by PRTG. The secret CLIXML is tied to that account and computer.

`InstanceUrl` must be an absolute HTTPS URL without embedded credentials. `CoreId` is `NYON-PRTG`; `OAuthScope` is `network_prtg`.

## PRTG parameters

`OPEN` is mapped to `Alert`; `RECOVER` is mapped to `Recovery`. They are compatibility inputs only and are never sent as `event_type` values. The `Status` argument must be one of `Down`, `Unknown`, `Unusual`, `Up`, or `Warning` and is sent unchanged.

The PRTG notification must provide `SensorId`, `DeviceId`, `Device`, `Sensor`, `Status`, `Message`, and `Priority`. Optional inputs are `Probe`, `Group`, `DeviceAddress`, `SensorType`, `Tags`, and `SensorUrl`. Configure the PRTG notification with the verified placeholders available in the target PRTG installation; this repository does not define placeholder names.

The production request is `POST /api/x_ames2_monitori_0/alerts/network/prtg`. Each request contains `event_id`, an event-specific UTC timestamp plus GUID identifier, and stable `deduplication_key` `PRTG:NYON-PRTG:<sensor_id>`.

## Validation

Run offline tests only:

```powershell
Import-Module Pester -RequiredVersion 3.4.0
Invoke-Pester -Script .\tests\PRTGServiceNow.Tests.ps1
```

`Test-ServiceNowScriptedRestApi.ps1` never runs under Pester. It accepts only `DEV`, requires `-AllowDevRequest`, PowerShell confirmation, and an interactive `DEV` confirmation before sending one real pilot event. Do not run it against production.

## Security

No secret belongs in this workspace, PRTG command line, configuration example, tests, or logs. Logs contain only bounded, cleaned operational metadata and never request/response bodies or authentication headers. See `AGENTS.md` for the complete operational contract.