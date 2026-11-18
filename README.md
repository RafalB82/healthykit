# HealthSync

HealthSync is an open-source iPhone app that syncs selected Apple Health metrics and workouts to your own REST API or a private hosted HealthSync workspace.

[Download on the App Store](https://apps.apple.com/in/app/healthysync/id6776575569) · [User guide](https://healthysync.app/docs) · [Support](https://healthysync.app/support) · [Privacy policy](https://healthysync.app/privacy)

## Getting started

1. Install HealthSync on an iPhone running iOS 17 or later.
2. Confirm a storage destination. To run your own server, follow the [self-hosted backend setup](backend/README.md) and enter its base URL and upload token in the app.
3. Select the data types to sync, grant Apple Health read access, and tap **Sync Last 24 Hours**. Use **Sync historical data** for older records. Background sync is best effort: iOS decides when it runs.

HealthSync reads Apple Health on-device through HealthKit. It never writes to Apple Health and does not upload health data until you confirm a destination. The iOS app has no analytics or third-party health SDKs.

## Source and development

| Component | Where to start |
| --- | --- |
| iOS app | [Build, test, and understand sync](HealthSync/README.md) |
| Self-hosted FastAPI and Postgres backend | [Setup and read APIs](backend/README.md) · [Upload contract](backend/UPLOAD_API.md) |
| Hosted API | [Cloudflare Worker and D1 development](cloudflare/README.md) |
| Public website and user guides | [Next.js development](web/README.md) |

See [Contributing](CONTRIBUTING.md) for testing and reporting issues.

## License

Copyright 2026 megabyte0x. Licensed under [Apache 2.0](LICENSE).
