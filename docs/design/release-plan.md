# Releases: trusted publishing and provenance

Releases are published by `.github/workflows/release.yml` when a `v*` tag is pushed. Nobody needs a RubyGems API key: GitHub's OIDC token is swapped for a short-lived RubyGems token (trusted publishing). Publishing by hand (`gem push`, with RubyGems MFA) still works as a fallback.

## What the workflow does

1. Checks out the tag; checks the tag matches `Curtilage::VERSION` and the CHANGELOG has a section for it; runs `bundle exec rake` (tests and RuboCop).
2. Waits for approval in the protected `release` environment.
3. Builds the gem and attests its provenance (`actions/attest-build-provenance`: a Sigstore-signed statement that this repository's workflow built this file from this commit, recorded in GitHub's attestation store).
4. Pushes the gem to RubyGems with the attestation attached.
5. Creates the GitHub release from the tag, with the CHANGELOG section as its notes and the `.gem` attached.

Only the release job gets write permissions (`contents`, `id-token`, `attestations`); actions are pinned to commit SHAs.

## Release steps

1. A pull request bumps `lib/curtilage/version.rb` and moves the CHANGELOG's Unreleased entries under the new version.
2. After merging: `git checkout main && git pull --ff-only`, then `git tag -a vX.Y.Z -m X.Y.Z && git push origin vX.Y.Z`.
3. Approve the `release` environment on the workflow run once the tests pass.

## One-time setup

- rubygems.org → curtilage → Trusted publishers: add a GitHub Actions publisher with repository `mohanenm/curtilage`, workflow `release.yml`, environment `release`.
- GitHub → Settings → Environments: create `release` with a required reviewer and deployment tags limited to `v*`.

## Verifying a release

```sh
gh attestation verify curtilage-X.Y.Z.gem --repo mohanenm/curtilage
```

The gem's page on rubygems.org also shows the attestation.

## Not done

- The Docker image isn't published; build it from the repository (README, Docker). Publishing it with provenance would add a job pushing to GHCR.
- Signed provenance shows where a file was built, not that its code is safe; it complements review.
