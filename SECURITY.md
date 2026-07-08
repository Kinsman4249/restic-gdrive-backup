# Security Policy

## Supported Versions

This project is currently pre-1.0. Only the most recent release receives security fixes.

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |
| older   | :x:                |

## Reporting a Vulnerability

If you find a security issue in this project, **please do not file a public GitHub issue**.

Instead, open a private GitHub Security Advisory:

1. Go to the [Security tab](https://github.com/Kinsman4249/restic-gdrive-backup/security) of this repository.
2. Click **"Report a vulnerability"**.
3. Provide as much detail as possible: affected version, reproduction steps, impact, and any suggested mitigation.

You should receive an acknowledgment within a few business days. If the issue is confirmed, a fix will be developed privately and released as a patch version. You'll be credited in the release notes (or anonymously, if you prefer).

## Scope

In-scope:

- Vulnerabilities in any code or scripts shipped by this project
- Insecure default configurations written by this project's setup / install code
- Any path that could allow privilege escalation or unauthorized access to credentials managed by this project

Out of scope:

- Vulnerabilities in upstream dependencies — please report those to the dependency's own maintainers
- Vulnerabilities in third-party services this project integrates with — report those to the service directly
- General hardening suggestions for your own host or environment (use a feature request issue instead)
