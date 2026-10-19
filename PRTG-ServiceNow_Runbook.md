# PRTG to ServiceNow Runbook

Diagnostic snapshot: 2026-10-19. Current verdict: `ROOT_CAUSE_PROBABLE`.
This runbook records verified facts and safe diagnostic steps. No production
template, script, service, or runtime configuration was changed during the
diagnostic. No OAuth or ServiceNow request was sent.

## Architecture

PRTG Core evaluates a sensor notification trigger, then executes each enabled
method in the selected notification template independently. The intended
custom-notification path is:

1. PRTG state trigger fires after the configured Down delay.
2. The notification template sends its email and, separately, runs the selected
   `Execute Program` file from `Notifications\EXE`.
3. `Send-PrtgServiceNowAlert.ps1` reads the XML/CLIXML configuration, decrypts
   the DPAPI `LocalMachine` protected secret, requests an OAuth token, builds
   an event payload, and posts it to the ServiceNow Scripted REST API.
4. `Alert` represents Down and `Recovery` represents Up in the installed
   script. ServiceNow is expected to correlate both events using the
   deduplication key.

Email success proves only the email method ran. It does not prove that
`Execute Program` was enabled or that an executable file was selected.

## Verified Environment

- PRTG Network Monitor 26.3.124.1727 x64.
- PRTG server: `UEFA-NPV-NWWG01`.
- Windows PowerShell: 5.1.20348.5499.
- `PRTGCoreService` was Running as `LocalSystem`.
- Effective execution policy reported `LocalMachine = RemoteSigned`; other
  scopes were `Undefined` in the administrator session.
- No `Zone.Identifier` stream was found on the three ServiceNow scripts.
- PRTG Execute Program can use another Windows identity if Domain/Computer
  Name and User Name are configured in the template. That override was not
  inspected; do not assume the Core identity is the effective process identity
  until the template is checked.

## Files and Versions

Installed script directory:

`C:\Program Files (x86)\PRTG Network Monitor\notifications\exe`

Runtime configuration and log:

`C:\ProgramData\PRTG-ServiceNow\config.xml`

`C:\ProgramData\PRTG-ServiceNow\ServiceNow-notification.log`

The three workspace scripts under `script\` were SHA-256 identical to the
server copies when checked:

| File | SHA-256 |
| --- | --- |
| `Initialize-ServiceNowPrtg.ps1` | `5540035FCB62F0BA3982EF52C24C8CC65691048F7BD5E22BACBFD111291ECF2A` |
| `Send-PrtgServiceNowAlert.ps1` | `BFC7EF9C42383F39405F85752D51C66D3D4BCA590895875544FDBC8F6838FC15` |
| `Test-ServiceNowOAuth.ps1` | `1D4CB2317A5AFEB191F28AB4A851AEF1D54C24A1E67828E2CD058CB7878D0339` |

The hash above is the historical installed snapshot. The workspace copy of
`Send-PrtgServiceNowAlert.ps1` is now a corrected full replacement; it has not
been deployed to the PRTG server or exercised against DEV.

The main script parsed successfully with the Windows PowerShell 5.1 parser. Its
mandatory parameters are `EventType`, `SensorId`, `DeviceId`, `DeviceName`,
`SensorName`, `Message`, and `Priority`. `EventType` is constrained to `Alert`
or `Recovery`. Optional parameters include `DeviceAddress`, `SensorType`,
`Probe`, `Group`, `Tags`, `PrtgUrl`, `ConfigurationPath`, `LogPath`, and
`NoSend`.

## Configuration and Destination

The configuration was imported only to inspect safe metadata. The following
properties were present and non-empty: `InstanceUrl`, `TokenUrl`, `AlertUrl`,
`Scope`, `ClientId`, `ProtectedClientSecret`, and `CoreId`. No client ID or
secret value was displayed or decrypted.

The actual configured and script-enforced destination was:

- OAuth host/path: `uefadev.service-now.com/oauth_token.do`
- Event host/path: `uefadev.service-now.com/api/x_ames2_monitori_0/alerts/network/prtg`
- Scope: `network_prtg`
- Core ID: `NYON-PRTG`

The installed script rejects URLs other than these DEV URLs. This proves the
current artifact is DEV-bound; it does not prove that DEV is an approved
destination for the production PRTG server. Confirm the intended ServiceNow
environment with its owner before selecting or running this notification in
production. Do not change the destination without explicit approval.

## Notification Parameters

The proposed `VOIP - Down` parameter string is:

```text
-EventType "Alert" -SensorId "%sensorid" -DeviceId "%deviceid" -DeviceName "%device" -DeviceAddress "%host" -SensorName "%sensor" -Message "%message" -Probe "%probe" -Group "%group" -Priority "%priority" -Tags "%tags" -PrtgUrl "%linksensor"
```

The proposed `VOIP - Recovery` parameter string is:

```text
-EventType "Recovery" -SensorId "%sensorid" -DeviceId "%deviceid" -DeviceName "%device" -DeviceAddress "%host" -SensorName "%sensor" -Message "%message" -Probe "%probe" -Group "%group" -Priority "%priority" -Tags "%tags" -PrtgUrl "%linksensor"
```

Paessler's current placeholder reference lists `%sensorid`, `%deviceid`,
`%device`, `%host`, `%sensor`, `%message`, `%probe`, `%group`, `%priority`,
`%tags`, and `%linksensor`. These are valid in Execute Program parameters.
The PRTG manual requires quoting values with whitespace and escaping special
characters; PowerShell-specific literal double quotes require doubled quotes
or a backtick. Validate actual resolved values using only the approved
synthetic `NoSend` process. PRTG's Send Test Notification does not resolve
placeholders, so it is not a valid placeholder test.

These strings are candidates, not approved production settings. The template
must select `Send-PrtgServiceNowAlert.ps1` in `Executable File`; merely enabling
the Execute Program section is insufficient. Confirm the configured execution
identity fields without displaying any password.

## Incident Findings: 2026-10-11

Sensor 5531, Ping v2, Interphone CL Pedestrian:

- 15:45:51: Down.
- 16:00:52: the 900-second State Trigger fired; the `VOIP - Down` email was
  reported successful and received.
- 19:05:40: Up; `VOIP - Recovery` email was reported successful and received.
- During later inspection, the `VOIP - Down` template's Execute Program
  `Executable File` field showed `Select a file`.

The email and trigger therefore worked. If the template was unchanged since the
incident, the blank executable is strong evidence that no ServiceNow script
was launched. Because its historical state was not captured, this remains
`ROOT_CAUSE_PROBABLE`, not proven. The candidate script/config also point only
to DEV, which is a separate destination mismatch if the expected alert was in
PROD.

## Evidence Retention

- The integration log existed, but its last write time was 2026-08-18, before
  the incident. A sanitized search found no Sensor 5531/2026-10-11 entry.
- `Core.log` and `CoreAPI.log` last write times were 2026-08-03. `Core.log` had
  no incident markers. `CoreAPI.log` had 70 occurrences of `5531`, but none of
  the searched incident date formats or `VOIP - Down`; these occurrences do not
  establish the October event.
- The PowerShell Operational channel was enabled with circular retention,
  552 records, and a 15 MiB maximum. Its oldest retained event was
  2026-10-19 08:28:24, so it cannot prove execution on October 11.
- A Security 4688 search returned a generic failure both before and after
  elevation. The catch suppressed the distinction between access/query failure
  and no matching events; no conclusion can be drawn from it.
- No runtime or PowerShell event evidence currently proves that the script
  executed on October 11. Historical evidence may be unavailable.

## Security and Implementation Risks

Do not run the OAuth test or a real notification until the target and logging
risks are reviewed.

- The configuration file and log ACLs granted `BUILTIN\Users` read/execute in
  addition to SYSTEM and Administrators. The installed initializer exports the
  configuration but does not restrict its ACL. The configuration contains a
  DPAPI `LocalMachine` protected secret; this is not user-bound protection, so
  broad read access to the ciphertext is a security risk.
- On HTTP failure, the main script reads up to 2,000 characters of the response
  body and writes it to the integration log and console. The OAuth test prints
  up to 1,000 response-body characters on failure. This conflicts with the
  repository rule never to log/display response bodies.
- The main script's `finally` sets secret/token variables to `$null`, but does
  not zero the byte arrays. Nulling a .NET string is not secure memory erasure.
- Event IDs have millisecond timestamps but no random component. PRTG may
  retry an Execute Program notification up to three times after a nonzero exit
  code; each process run generates a new event ID, so retries do not reuse the
  same ID.
- The script does not special-case HTTP 409 as an idempotent duplicate and
  does not implement the documented transient retry policy. It logs SUCCESS
  after any non-throwing `Invoke-RestMethod` response rather than explicitly
  validating HTTP 201.
- The event status is hard-coded to Down for Alert and Up for Recovery. This
  matches the observed Ping Down/Up scenario but does not preserve every
  allowed technical PRTG status from the repository contract.
- `Test-ServiceNowOAuth.ps1` performs a real network request and has no dry-run
  switch. Do not run it without explicit authorization.

## Safe Diagnostic Sequence

1. Confirm the command shell is on the PRTG server, then record host, PowerShell
   version, PRTG services, and the Core service account.
2. Inventory script names, timestamps, sizes, and SHA-256. Do not dump a
   configuration file or secret.
3. Check `config.xml` existence and ACL. Inspect only property names,
   non-empty flags, and sanitized URL host/path. Never print ClientId or
   ProtectedClientSecret.
4. Check the integration log's date/size, then search by sensor/date while
   displaying only timestamps and markers, never raw message or response
   fields.
5. In PRTG `Logs > System Events > Notifications Related`, verify the
   State Trigger, email, and any Execute Program event separately.
6. Inspect `VOIP - Down` and `VOIP - Recovery` templates read-only. Confirm
   Execute Program is enabled, an executable is selected, parameters are
   correct, and whether a custom Windows identity is configured. Do not click
   Send Test Notification.
7. Confirm target environment with the ServiceNow owner. The currently
   installed script is hard-coded to DEV.
8. Do not send a request or modify a template/script without explicit approval.
   If approved, prepare synthetic `NoSend` validation first; it must not request
   OAuth or contact ServiceNow. A real DEV pilot needs separate approval and an
   agreed cleanup plan.

## Documentation References

Paessler documentation checked 2026-10-19:

- [Notification Templates](https://www.paessler.com/manuals/prtg/notification_templates)
- [Custom Notifications](https://www.paessler.com/manuals/prtg/custom_notifications)
- [Placeholders for Notifications](https://www.paessler.com/manuals/prtg/list_of_placeholders_for_notifications)
- [Escape Special Characters and Whitespaces in Parameters](https://www.paessler.com/manuals/prtg/escape_special_characters_and_whitespaces_in_parameters)