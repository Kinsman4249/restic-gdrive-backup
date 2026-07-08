# Privacy Policy

Effective date: 2026-07-08

This policy covers restic-gdrive-backup, a self-hosted backup application. You install and run it on your own server. Every installation is operated by the person who installed it. The developer runs no servers for this application and receives no data from it.

## Summary

- Your files are encrypted on your own machine before anything is uploaded
- Backups are stored in your own Google Drive, readable only with your encryption key
- The application sends no data to the developer: no telemetry, no analytics, no tracking
- Alert emails go only to the address you configure, through a provider you configure

## Data the application handles

**Files you choose to back up.** The application encrypts them with AES-256 on your server, using an encryption key that only you hold, and uploads the encrypted result to your Google Drive. The key is stored in a root-only file on your server and is never transmitted anywhere.

**Google account access.** The application connects to Google Drive through rclone using OAuth authorization that you grant. The resulting access token is stored on your server in a root-only file and is used solely to read and write the backup folder in your own Google Drive. No other Google data is accessed.

**Alert emails.** When a backup fails or goes stale, the application sends an email through the smtp2go API using the source and destination addresses you configure. Alert messages can contain your server's hostname, file paths, and error output.

## Data the application does not collect

The application contains no telemetry, analytics, crash reporting, or usage tracking of any kind. It never contacts the developer. The developer cannot see your files, your Google account, your encryption key, or your alert emails.

## Google user data and Limited Use

This application's use of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements. Specifically, data accessed through the Google Drive scope is used only to store, list, and retrieve your encrypted backup archives. It is not sold, not used for advertising, not used to train models, and not read by any human. It is not transferred to anyone except as necessary to provide the backup function you configured (that is, to Google Drive itself).

## Third-party services

The application interacts with services under their own privacy policies:

- Google Drive stores your encrypted backup data ([Google privacy policy](https://policies.google.com/privacy))
- smtp2go delivers alert emails ([smtp2go privacy policy](https://www.smtp2go.com/privacy/))

Your own server and hosting provider are your choice and are outside the scope of this policy.

## Retention and deletion

Backups are retained according to the schedule you configure (daily, weekly, and monthly limits) and pruned automatically. You can delete all backup data at any time by removing the backup folder from your Google Drive or running the documented restic commands. You can revoke the application's Google Drive access at any time in your Google account security settings. Uninstall instructions are in the README.

## Security

All files are encrypted client-side with AES-256 before upload. Encryption keys and API credentials are stored in root-only files with 600 permissions. All network communication with Google and smtp2go uses HTTPS.

## Children

This application is a server administration tool and is not directed at children.

## Changes to this policy

Changes are published in this repository. The git history of this file is the complete record of changes.

## Contact

Questions about this policy: open an issue on the [GitHub repository](https://github.com/Kinsman4249/restic-gdrive-backup/issues). For private contact, use the repository's [security advisories](https://github.com/Kinsman4249/restic-gdrive-backup/security/advisories/new).
