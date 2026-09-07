# Repository Instructions

- Keep Windows PowerShell 5.1 compatibility and preserve the root PRTG wrapper path.
- Use only the ServiceNow Scripted REST API contract in `AGENTS.md`; never restore Table API calls to production logic.
- Keep automated tests fully offline with Pester 3.4.0 mocks.
- Never add, display, log, or commit secrets, tokens, authorization headers, CLIXML content, or request/response bodies.
- Provide complete replacement content for any changed integration PowerShell script.
- Check references and run relevant syntax, JSON, and Pester validation before deleting or moving files.