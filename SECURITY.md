# Security Policy

## Supported versions

`sitemapr` is experimental and not yet on CRAN. Security fixes are made against
the latest development version on `main`; please upgrade to the most recent
commit or release before reporting.

| Version                    | Supported          |
| -------------------------- | ------------------ |
| Latest `main` / release    | :white_check_mark: |
| Older development versions | :x:                |

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Preferred channel - **GitHub private vulnerability reporting**:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.

This opens a private security advisory visible only to the maintainers.

If you cannot use that channel, email the maintainer at
**bartek@turczynski.pl** instead.

Do not include secrets, credentials, tokens, or private customer data in issues,
pull requests, logs, or `_scratch/`.

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
