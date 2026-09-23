#!/bin/sh
# Move every top-level *.md file out of the pkgdown build tree UNLESS it is on
# the keep list below, so pkgdown:::build_site() cannot render it.
#
# pkgdown renders EVERY top-level .md file: pkgdown:::package_mds() hardcodes
# its own skip list (README/NEWS/LICENSE) and _pkgdown.yml has no setting
# that can add to it. The previous version of this filter, run inline in
# `.gitlab-ci.yml`'s `pages` job, was `rm -f AGENTS*.md CLAUDE*.md FP_*.md` --
# it named the BAD files, which is fail-OPEN: a new agent tool's
# instruction-file family (GEMINI.md, CODEX.md, ...) matches none of those
# three globs and gets published as if it were user documentation. That is
# exactly how the leak this filter exists to stop reached four repos after
# being fixed in one (SEOR-pibdjanz), and is tracked as its own defect,
# SEOR-wqxhftpv, because the glob shape reintroduces the same gap for any
# family it was not written to already know about.
#
# Inverted here to a GOOD list: name what belongs on the site, move
# everything else. An unknown top-level .md file defaults to private.
#
# Moved into $AGENT_MD_DIR rather than deleted: deleting leaves pkgdown's
# search.json pointing at pages that then 404. pslr's `pages` job established
# the move-not-delete precedent (see its .gitlab-ci.yml, "agent-md") for the
# same reason; this reuses its /tmp/agent-md/ default.
#
# Fails loud on purpose, same as pslr's explicit `mv` list did: after the
# move, if any file matching a KNOWN agent-instruction family is still
# present at the top level, this script exits nonzero rather than letting
# `pkgdown::build_site()` run and silently publish it. The keep-list design
# no longer depends on knowing every agent tool's naming convention up front
# to stay safe, but this still catches a bug in the keep list itself (for
# example, an agent file name accidentally added to it).
#
# scripts/check-ci-config.py runs this exact file (not a copy of its logic)
# against synthetic scratch directories, so a change here is what that pin
# notices.

set -eu

target_dir="${AGENT_MD_DIR:-/tmp/agent-md}"
mkdir -p "$target_dir"

# Meant for the site's readers. LICENSE.md and THIRD_PARTY_NOTICES.md are not
# present in this repository today (licensing lives in the extensionless
# `LICENSE` file, which this *.md glob never touches) but are listed so
# adding either later needs no second round of this. ACKNOWLEDGMENTS.md is a
# per-repo addition: _pkgdown.yml's navbar links straight to it.
#
# cran-comments.md is listed for self-documentation only, not because it was
# ever at risk: `pkgdown:::package_mds()` hardcodes it as `no_render`, and
# `cran-comments.html` 404s on every fleet site regardless of whether that
# site's filter mentions the name at all (confirmed empirically across five
# live sites, 2026-09-23). Its presence on or absence from this list changes
# nothing.
#
# CHANGELOG.md is GRANDFATHERED, not newly kept: it is not referenced by
# _pkgdown.yml and its own text says NEWS.md is the site-rendered file it
# mirrors -- an argument for retiring CHANGELOG.html, not a decision. That
# page already answers 200 on the live site today, and this job auto-deploys
# on every push to the default branch, so removing it here would take down a
# live page as a by-product of closing the AGENTS.md/CLAUDE.md leak this
# script exists for. Retiring it is a separate, owner-made editorial call
# (SEOR-wqxhftpv decision, 2026-09-23), not something to do while unattended.
keep="README.md NEWS.md LICENSE.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md THIRD_PARTY_NOTICES.md ACKNOWLEDGMENTS.md cran-comments.md CHANGELOG.md"

for f in *.md; do
  [ -f "$f" ] || continue
  case " $keep " in
    *" $f "*) ;;
    *) mv "$f" "$target_dir/" ;;
  esac
done

for pattern in 'AGENTS*.md' 'CLAUDE*.md' 'FP_*.md'; do
  # shellcheck disable=SC2086
  remaining=$(ls $pattern 2>/dev/null || true)
  if [ -n "$remaining" ]; then
    echo "ERROR: agent-instruction file(s) survived the filter: $remaining" >&2
    exit 1
  fi
done
