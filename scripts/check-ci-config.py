# check-ci-config v1
"""Pin what `.gitlab-ci.yml` actually does today, so a later edit to it is
caught rather than silently drifting from the claims made about it.

Standalone and offline (stdlib only), same shape as `check-citation.py`
beside it. NOT wired into `tools/verify.R` -- that chain is scoped to R
package verification, and this checks CI *configuration*, not R behavior.
Run it directly:

    python3 scripts/check-ci-config.py

WHAT IT CHECKS.

1. Library-path ordering (SEOR-dyzgzyot). rocker's own `Renviron.site` sets
   `R_LIBS=${R_LIBS-'...site-library:...library'}` -- a default-assignment
   form that an already-set `R_LIBS` environment variable defeats. Measured
   directly against `rocker/r-ver:4.5.1` on 2026-09-23:

       R_LIBS_USER=/tmp/rlib only:  .libPaths()[1] == site-library (loses)
       R_LIBS=/tmp/rlib:... set:    .libPaths()[1] == /tmp/rlib    (wins)

   So this file needs `R_LIBS_USER` for tools that read it directly (pak's
   default install target) AND an explicit `R_LIBS` naming the same cache
   directory FIRST, or the cache silently never holds the built library. This
   check pins that both variables are set that way today.

2. The `pages` job's top-level-.md filter (SEOR-wqxhftpv). Extracts the
   actual shell command from the file (marked by a `CI-PIN:` sentinel
   comment, so this never re-implements the filter logic -- it runs the real
   one) and executes it against synthetic scratch directories, then asserts
   which files would survive to be published by pkgdown and which get moved
   out of the source tree first.

Both checks read the ACTUAL command text out of `.gitlab-ci.yml`, not a
paraphrase of it, so a future edit that changes the command is what this
script notices.
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys
import tempfile

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CI_FILE = REPO_ROOT / ".gitlab-ci.yml"

SENTINEL = "CI-PIN: agent-md filter step below"

# The real top-level *.md inventory in this repository as of 2026-09-23
# (`ls *.md`), plus one synthetic file, GEMINI.md, that names no agent tool
# actually in use here -- it stands in for "the next agent-file family no one
# has invented yet", which is exactly the class of file SEOR-wqxhftpv exists
# to keep private by default. GEMINI.md is never created on disk outside this
# script's own scratch directories.
KNOWN_MD_FILES = [
    "ACKNOWLEDGMENTS.md",
    "AGENTS.md",
    "CHANGELOG.md",
    "CLAUDE.md",
    "CODE_OF_CONDUCT.md",
    "CONTRIBUTING.md",
    "cran-comments.md",
    "FP_AGENTS.md",
    "FP_CLAUDE.md",
    "NEWS.md",
    "README.md",
    "SECURITY.md",
]
FUTURE_FAMILY_FILE = "GEMINI.md"


class CheckFailed(AssertionError):
    pass


def read_ci_file() -> str:
    return CI_FILE.read_text()


# ---------------------------------------------------------------------------
# Check 1: library-path ordering
# ---------------------------------------------------------------------------


def extract_variable(text: str, name: str) -> str:
    match = re.search(rf'^\s*{re.escape(name)}:\s*"([^"]*)"', text, re.MULTILINE)
    if not match:
        raise CheckFailed(
            f"variables.{name} not found in .gitlab-ci.yml "
            "(expected a top-level `variables:` entry, quoted)"
        )
    return match.group(1)


def check_library_paths() -> None:
    text = read_ci_file()
    r_libs_user = extract_variable(text, "R_LIBS_USER")
    r_libs = extract_variable(text, "R_LIBS")

    cache_dir = "$CI_PROJECT_DIR/.cache/R"
    if r_libs_user != cache_dir:
        raise CheckFailed(
            f"R_LIBS_USER is {r_libs_user!r}, expected {cache_dir!r} -- the "
            "cache: paths: entry (.cache/R) and R_LIBS_USER must name the "
            "same directory or the cache key stops meaning anything."
        )
    if not r_libs.startswith(cache_dir + ":"):
        raise CheckFailed(
            f"R_LIBS is {r_libs!r}, expected it to START with "
            f"{cache_dir!r} followed by ':' -- rocker's Renviron.site only "
            "defers to an ALREADY-SET R_LIBS; if the cache directory is not "
            "first, packages install into the container's site-library and "
            "the cache is archived empty on every job (measured live against "
            "rocker/r-ver:4.5.1, 2026-09-23)."
        )
    print("OK  library paths: R_LIBS_USER and R_LIBS both put the cache dir first")


# ---------------------------------------------------------------------------
# Check 2: the pages job's agent-md filter
# ---------------------------------------------------------------------------


def extract_filter_command(text: str) -> str:
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if SENTINEL in line:
            for candidate in lines[i + 1 :]:
                stripped = candidate.strip()
                if not stripped:
                    continue
                if not stripped.startswith("- "):
                    break
                cmd = stripped[2:].strip()
                if len(cmd) >= 2 and cmd[0] == cmd[-1] and cmd[0] in "'\"":
                    cmd = cmd[1:-1]
                return cmd
    raise CheckFailed(
        f"no {SENTINEL!r} sentinel found above a `- ` script line in "
        ".gitlab-ci.yml -- the pages job's filter step must be marked so "
        "this check runs the REAL command rather than a copy of it."
    )


def run_filter(cmd: str, files: list[str]) -> tuple[set[str], set[str]]:
    """Run `cmd` in a scratch dir seeded with `files`; return (survivors,
    moved) as sets of filenames."""
    # A relative `scripts/...` reference is correct in real CI, where the job
    # runs with $CI_PROJECT_DIR (the repo root) as cwd. Here the working
    # directory is a throwaway scratch dir, so re-anchor that one reference
    # to the real repo root -- the command text itself is untouched.
    resolved_cmd = cmd.replace("scripts/", f"{REPO_ROOT / 'scripts'}/")
    with tempfile.TemporaryDirectory() as scratch, tempfile.TemporaryDirectory() as moved_to:
        for name in files:
            (pathlib.Path(scratch) / name).write_text("stub\n")
        env = dict(os.environ)
        env["AGENT_MD_DIR"] = moved_to
        result = subprocess.run(
            ["sh", "-c", resolved_cmd],
            cwd=scratch,
            env=env,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise CheckFailed(
                f"filter command exited {result.returncode}\n"
                f"  cmd: {cmd}\n  stdout: {result.stdout}\n  stderr: {result.stderr}"
            )
        survivors = {p.name for p in pathlib.Path(scratch).glob("*.md")}
        moved = {p.name for p in pathlib.Path(moved_to).glob("*.md")}
        return survivors, moved


def check_md_filter() -> None:
    text = read_ci_file()
    cmd = extract_filter_command(text)

    # Scenario A: today's real top-level .md inventory. Every agent-file
    # family already known to this repo (AGENTS*, CLAUDE*, FP_*) must be kept
    # off the published site; everything else must survive.
    survivors, _ = run_filter(cmd, KNOWN_MD_FILES)
    expected_removed = {"AGENTS.md", "CLAUDE.md", "FP_AGENTS.md", "FP_CLAUDE.md"}
    still_present = expected_removed & survivors
    if still_present:
        raise CheckFailed(
            f"known agent file(s) survived the filter and would publish: "
            f"{sorted(still_present)}"
        )
    expected_survivors = set(KNOWN_MD_FILES) - expected_removed
    if survivors != expected_survivors:
        raise CheckFailed(
            "the filter's survivor set for today's known .md files changed:\n"
            f"  expected: {sorted(expected_survivors)}\n"
            f"  actual:   {sorted(survivors)}\n"
            "(a change here means either a keep-listed file stopped "
            "surviving, or a file that used to be filtered now is not -- "
            "update KNOWN_MD_FILES/expected sets deliberately if that is "
            "the intended new behavior, don't just silence this.)"
        )
    print(f"OK  agent-md filter: known inventory survivors == {sorted(expected_survivors)}")

    # Scenario B: the known inventory PLUS one file naming no agent tool this
    # repo has ever used. Pinned here as a KNOWN, NAMED fact about today's
    # filter, not as an aspiration: the current filter names only the bad
    # globs it already knows about (AGENTS*.md, CLAUDE*.md, FP_*.md), so a
    # file from any OTHER agent tool's instruction-file family -- GEMINI.md
    # stands in for "the next one nobody has invented yet" -- is invisible to
    # those three patterns and survives to publish. That is the SEOR-wqxhftpv
    # defect (fail-OPEN by name, not fail-CLOSED by keep-list); pinning it
    # here, rather than silently asserting the fixed behavior, means the fix
    # commit has to visibly FLIP this assertion (see the comment on the next
    # line once it does) instead of quietly rewriting history.
    #
    # FLIP THIS when SEOR-wqxhftpv's keep-list filter lands: assert
    # FUTURE_FAMILY_FILE is NOT in future_survivors instead.
    future_survivors, _ = run_filter(cmd, KNOWN_MD_FILES + [FUTURE_FAMILY_FILE])
    if FUTURE_FAMILY_FILE not in future_survivors:
        raise CheckFailed(
            f"{FUTURE_FAMILY_FILE} no longer survives the filter -- if the "
            "SEOR-wqxhftpv keep-list fix landed, flip this assertion (see "
            "the comment above) to require it does NOT survive; don't just "
            "delete the check."
        )
    print(
        f"OK  agent-md filter: {FUTURE_FAMILY_FILE} (unknown family) still "
        "survives -- known fail-open gap, pinned pending SEOR-wqxhftpv"
    )


def main() -> int:
    checks = [check_library_paths, check_md_filter]
    failures = []
    for check in checks:
        try:
            check()
        except CheckFailed as exc:
            failures.append(f"FAIL  {check.__name__}: {exc}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
