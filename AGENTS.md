# Agent Guide

## Purpose and runtime

This repository integrates PRTG notifications with the ServiceNow Scripted REST API using Windows PowerShell 5.1. The runtime verified for this workspace is Windows PowerShell 5.1.26100.8875, Desktop edition, x64. Pester 3.4.0 is installed; do not upgrade it without a demonstrated requirement.

## Layout

- `PRTG-ServiceNow.ps1` is the deployed PRTG wrapper and must remain next to `PRTGServiceNow.psm1`.
- `PRTGServiceNow.psm1` holds reusable integration logic.
- `tests/` contains offline Pester tests only.
- `Test-ServiceNowScriptedRestApi.ps1` is a manually approved DEV pilot, never an automated test.

## ServiceNow contract

Use OAuth client credentials with `{InstanceUrl}/oauth_token.do`, scope `network_prtg`. Production events use only `POST /api/x_ames2_monitori_0/alerts/network/prtg`; no Table API endpoint belongs in the production flow.

`OPEN` maps to `event_type` `Alert`; `RECOVER` maps to `Recovery`. Preserve technical `status` as one of `Down`, `Unknown`, `Unusual`, `Up`, or `Warning`. ServiceNow manages alert lifecycle, deduplication, and recovery.

Required payload fields are `source`, `core_id`, `event_id`, `deduplication_key`, `event_type`, `status`, `event_timestamp_utc`, `sent_timestamp_utc`, `device_id`, `device_name`, `sensor_id`, `sensor_name`, `message`, and `priority`. `source` is `PRTG`; the deduplication key is `PRTG:<core_id>:<sensor_id>`. Optional fields are `probe`, `group`, `device_address`, `sensor_type`, `tags`, and `prtg_url`.

Treat `201` as success. Treat documented `409` duplicate events as an explicit idempotent result, log non-sensitive metadata, and do not retry it. `400`, `401`, and `404` fail without retry. Only retry transient network failures, `429`, and `5xx` using the same generated event ID.

## Security

Secrets remain in user-and-machine-bound CLIXML outside the workspace. Never log or commit credentials, client IDs, access tokens, authorization headers, decrypted CLIXML content, request bodies, response bodies, or authenticated URLs. Require absolute HTTPS instance URLs without user info and leave certificate validation enabled. `Initialize-Secrets.ps1` must keep restrictive ACLs for the PRTG execution identity, SYSTEM, and Administrators.

## Changes and tests

Every correction to an integration PowerShell script must be supplied as a complete replacement script, not a fragment. Keep Windows PowerShell 5.1 compatibility. Do not add dependencies, extensions, MCP servers, tasks, or folders without a demonstrated need.

Automated tests must mock OAuth, HTTP, sleeps, secret access, and logging. They must never access a network, ServiceNow instance, real secret, or live infrastructure. Run:

```powershell
Import-Module Pester -RequiredVersion 3.4.0
Invoke-Pester -Script .\tests\PRTGServiceNow.Tests.ps1
```

Before moving or deleting a file, search scripts, tests, documentation, VS Code configuration, and deployment references; confirm a replacement exists and run syntax, JSON, and applicable Pester validation.