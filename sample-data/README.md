# sample-data/

This directory is **gitignored except for this README**.

Drop real personal data here during development:

- `sample-data/google-takeout/location-history.json` — your Google Takeout export
- `sample-data/screenshots-heic/*.HEIC` — original screenshots, kept here so the working tree is reproducible without exposing them

Nothing in here will be staged by `git add`, and the pre-commit hook will reject any attempt to force-add files from this folder.

If you want a synthetic, committed test fixture, see `fixtures/` instead.
