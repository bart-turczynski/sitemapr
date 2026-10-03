# Security Policy

## Supported versions

Security fixes are made against the latest released version of `sitemapr` and the
development version on `main`. Until the first release, only `main` is
supported. Once there is a release, please upgrade to the most recent one
before reporting.

| Version                        | Supported          |
| ------------------------------ | ------------------ |
| Latest release                 | :white_check_mark: |
| Development version (`main`)   | :white_check_mark: |
| Older releases                 | :x:                |

## Reporting a vulnerability

**Please do not report security vulnerabilities through public issues.**

Preferred channel — **email the maintainer at bartek@turczynski.pl.**

Alternatively, open a **confidential issue** on the GitLab project:

1. Go to [Issues](https://gitlab.com/bart-turczynski/sitemapr/-/work_items) and click
   **New issue**.
2. Tick **This issue is confidential** before submitting.

A confidential issue is visible only to you, its assignees and the project
members whose role lets them see confidential issues.

Email is listed first deliberately: it works whether or not you have a GitLab
account, and it is the channel the maintainer monitors.

Do not include secrets, credentials, tokens, or private customer data in a
report, an issue, a merge request or a log. A reproduction against a server
you control, or a loopback server under a test policy, is enough.

## What to expect

- We aim to acknowledge a report within **7 days**.
- We will investigate, work on a fix, and coordinate disclosure with you.
- We are happy to credit reporters in the release notes unless you prefer to
  remain anonymous.

## Scope

`sitemapr` is an R library for parsing, discovering, and validating sitemaps. It
handles untrusted XML, URL, archive, and network inputs. Its security surface
includes XXE-safe XML parsing, bounded archive extraction, safe URL handling,
and SSRF protections for sitemap discovery.
