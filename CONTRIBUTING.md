# Contributing to HealthSync

- Use [GitHub Issues](https://github.com/megabyte0x/healthysync/issues) for reproducible bugs and feature requests. For help using the app, see [Support](https://healthysync.app/support).
- For a bug report, include the app version, iOS version, steps to reproduce, and whether you use hosted storage or your own backend. Do not post health exports, bearer tokens, credentials, or device or workspace identifiers. Report security or privacy issues through the email on the support page, not in a public issue.
- Keep pull requests focused. Explain the user-visible change and list the checks you ran. Use synthetic health records in tests and examples.

## Run the relevant checks

| Area | Instructions |
| --- | --- |
| iOS app | [XCTest and device checks](HealthSync/README.md#tests) |
| Self-hosted API | [Pytest](backend/README.md#development-tests) |
| Hosted API and legacy bridge | [Worker tests and type checking](cloudflare/README.md#development) |
| Website and docs | [Type checking and static build](web/README.md#verification) |
