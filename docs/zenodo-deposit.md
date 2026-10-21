# Zenodo deposit by hand

sitemapr's releases are archived on Zenodo **by hand**, after each CRAN
release. The fleet's other packages minted their DOIs through Zenodo's GitHub
integration, which deposits when a GitHub Release is published on the
read-only mirror (rurl's `design/zenodo-dois.md`; step 14 of seor's
`design/release-checklist.md`). That route is closed for good. The GitHub
account the integration was linked to is permanently suspended, so no webhook
will ever deposit for this repository. The owner chose hand deposits on
2026-10-21 (SITE-knuqpfaf). The first deposit is SITE-uyslxjrb.

The deposit is the owner's job. It needs the owner's Zenodo login, or a
personal access token only the owner holds. An agent prepares the tarball and
the metadata and checks the record afterwards. It never creates, edits or
publishes a deposit.

## What Zenodo's documentation says

Read on 2026-10-21. Each URL answered HTTP 200 that day.

- **A software deposit needs no GitHub link.** Zenodo's "GitHub and Software"
  docs list two ways to archive software, "Archive a release from GitHub" and
  "Upload software manually". The manual route starts from an ordinary new
  upload ("Click the plus icon in the header, and select New upload"), sets
  *Resource type* to Software, and publishes. Sources:
  <https://help.zenodo.org/docs/github/archive-software/manual-upload/>,
  <https://help.zenodo.org/docs/deposit/create-new-upload/>.
- **Upload exactly one compressed file.** The manual-upload guide: "It is
  mandatory that only one compressed file (e.g. ZIP) is present in the record.
  Otherwise, the record is deemed invalid and not archived in Software
  Heritage." The record page then shows the archival status under *External
  resources > Archived in*. Same source.
- **`.zenodo.json` is a GitHub-integration file.** Zenodo documents it only as
  a file that "can be added to your GitHub repository", read when a GitHub
  release is archived:
  <https://help.zenodo.org/docs/github/describe-software/zenodo-json/>. The
  REST API docs say the same: it overrides the metadata Zenodo pulls from
  GitHub on a release. Source: <https://developers.zenodo.org/>. Neither the
  manual-upload guide nor the upload-form guide mentions it. **A hand deposit
  does not read the file.** Whoever deposits types its values into the form or
  sends them as the deposition's `metadata` in a REST call.
- **The REST deposition metadata uses the same field names as
  `.zenodo.json`.** These are `upload_type`, `title`, `creators` (with
  `name` and `orcid`), `description`, `version`, `language`, `access_right`,
  `license`, `keywords`, `notes`, `related_identifiers` and `references`. The
  table lists only `identifier`, `relation` and `resource_type` as keys of a
  related identifier, not `scheme`. `publication_date` is required and
  defaults to today. Writing needs a token with the `deposit:write` scope;
  publishing and new versions need `deposit:actions`. A sandbox at
  <https://sandbox.zenodo.org> mints test DOIs under `10.5072`. Source:
  <https://developers.zenodo.org/>.
- **Concept DOI and version DOI.** "The last DOI represents all the versions
  of the given software package", and "The Concept DOI resolves to the landing
  page of the latest version of your record". Every version gets its own
  version DOI. Source: <https://zenodo.org/help/versioning>. A later release
  is added from the latest version's record page with **New version**:
  <https://help.zenodo.org/docs/deposit/manage-versions/>. Over REST it is
  `POST /api/deposit/depositions/:id/actions/newversion` on the latest
  version's id.
- **A published record stays published.** "Once a deposition is published,
  you can no longer delete it" (<https://developers.zenodo.org/>). The owner
  can change its files only within 45 days of publishing
  (<https://help.zenodo.org/docs/deposit/create-new-upload/>). Metadata can
  still be edited later.

## The artifact

Upload **the CRAN source tarball of the release**, `sitemapr_X.Y.Z.tar.gz`,
as the record's only file. Use the bytes CRAN accepted: download the tarball
from CRAN's `src/contrib/` after acceptance, not one rebuilt locally. It is
the file `install.packages()` serves for that version, so the version DOI
names exactly what users installed.

Do not add the `vX.Y.Z` tag archive next to it. Two files break the
one-compressed-file rule, and the record is then not archived in Software
Heritage. The guide's example is a ZIP. If *Archived in* never lists Software
Heritage for a `.tar.gz`, replace the file within the 45-day window with the
tag as a ZIP, which carries the full source tree:

```sh
git archive --format=zip --prefix=sitemapr-X.Y.Z/ -o sitemapr-X.Y.Z.zip vX.Y.Z
```

## Metadata: `.zenodo.json` is the source of record

`.zenodo.json` holds the record's metadata. `scripts/check-citation.py`
already keeps its `"version"` in step with `DESCRIPTION` from the pre-push
hook and the `citation-version` CI job, and `.Rbuildignore` keeps it out of
the tarball. Read it from the release tag, not from `main`.

### In the upload form

Under *Digital Object Identifier (DOI)*, answer that there is no existing DOI. Zenodo assigns the DOI on
publishing, and *Get a DOI now!* is not needed. Then copy each field across.
Capitalized names are the section names in Zenodo's guide to the form
(<https://help.zenodo.org/docs/deposit/describe-records/>). Lowercase ones
describe fields that guide does not name, so look for the form's own label.

| `.zenodo.json` | Upload form |
|---|---|
| `upload_type: software` | Resource types: Software |
| `title` | Titles |
| (none) | Publication date: the date CRAN published the release |
| `creators` | Creators: Turczynski, Bart, with the ORCID |
| `description` | Descriptions |
| `license: MIT` | Licenses and rights: MIT License |
| `keywords` | Keywords and subjects, one per keyword |
| `version` | the version field (`X.Y.Z`, no leading `v`) |
| `language: eng` | the language field: English |
| `access_right: open` | public (open) access to record and files |
| `related_identifiers` | the related works field: each URL with its relation and resource type |
| `references` | the references field, one per line |
| `notes` | the additional notes field |

Fill in the form's *Software* section too, as the manual-upload guide
recommends. Check the preview against `.zenodo.json` before publishing,
because a published record cannot be deleted.

### Over the REST API

This sends the same metadata from the file. It needs the owner's token in
`ZENODO_TOKEN` with `deposit:write` and `deposit:actions`. Try it against the
sandbox first by swapping the host. `<id>` and `<bucket>` come from the first
response (`id`, `links.bucket`).

```sh
# 1. Create an empty deposition.
curl -s -H "Authorization: Bearer $ZENODO_TOKEN" -H "Content-Type: application/json" \
  -X POST https://zenodo.org/api/deposit/depositions -d '{}'

# 2. Upload the tarball into the deposition's bucket.
curl -s -H "Authorization: Bearer $ZENODO_TOKEN" \
  --upload-file sitemapr_X.Y.Z.tar.gz "<bucket>/sitemapr_X.Y.Z.tar.gz"

# 3. Send .zenodo.json as the metadata, without the undocumented `scheme`
#    key and with the publication date.
jq --arg d YYYY-MM-DD \
  '{metadata: (.publication_date = $d | .related_identifiers |= map(del(.scheme)))}' \
  .zenodo.json > metadata.json
curl -s -H "Authorization: Bearer $ZENODO_TOKEN" -H "Content-Type: application/json" \
  -X PUT https://zenodo.org/api/deposit/depositions/<id> -d @metadata.json

# 4. Publish. This cannot be undone.
curl -s -H "Authorization: Bearer $ZENODO_TOKEN" \
  -X POST https://zenodo.org/api/deposit/depositions/<id>/actions/publish
```

## Each later release

Add every later release as a **new version** of the same record. Never start
a fresh upload, which would mint a second concept DOI. On the latest
version's record page, press **New version**. Skip *Import files*, which
copies the previous tarball into the draft, and upload only the new one. Update
*Version*, *Publication date* and anything else that changed in
`.zenodo.json`, and publish. Over REST, call `actions/newversion` on the
latest version's id and work on the draft it names in `links.latest_draft`.
Check the draft's files first and delete any carried over from the previous
version, then repeat steps 2–4 above.

The concept DOI never changes, so the README badge and `CITATION.cff`'s `doi:`
stay as they are. Each new version gets its own version DOI.

## After the first deposit

1. **Read both DOIs** from the public API, which needs no token:
   `curl -s https://zenodo.org/api/records/<record-id>`. The `conceptdoi`
   field is the concept DOI and `doi` is the version DOI. Check that doi.org
   resolves both before committing either. A 404 means DataCite has not
   registered the DOI yet, so wait.
2. **Wire in the concept DOI** in one change, as rurl, pslr and punycoder do:
   - `CITATION.cff`: `doi: 10.5281/zenodo.NNN` (the concept DOI). Add an
     `identifiers:` block with the concept DOI and this release's version
     DOI, each with a `description`. `check-citation.py` allows a DOI once
     `DESCRIPTION` names a released version.
   - `README.Rmd`: replace the HTML comment in the badge block with the DOI
     badge from slot 11 of seor's `design/fleet-standard.md`, just ahead of
     the Zenodo "all software" badge. Point it at the concept DOI on doi.org:
     `[![DOI](https://zenodo.org/badge/DOI/<concept-doi>.svg)](https://doi.org/<concept-doi>)`.
     Never use `zenodo.org/badge/latestdoi/<id>`. That form is keyed by the
     GitHub repository id the integration supplied, and it answered 404 here
     (SITE-ewcnqior). Regenerate `README.md`.
   - `inst/CITATION`: add `doi = "10.5281/zenodo.NNN"` to the `bibentry()`.
   - `codemeta.json`: add the concept DOI as an identifier.
3. **At each later release**, update only the version-DOI entry in
   `CITATION.cff`'s `identifiers:`.

`.zenodo.json` stays under its own name. It is the metadata source of record
for the form and for the REST call, and `check-citation.py` reads it by name.
Renaming it would silently switch that check off. No webhook will read the
file now, so leaving it in the tree costs nothing.
