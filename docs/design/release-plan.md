# Releases: trusted publishing and provenance

Releases are published by `.github/workflows/release.yml` when a `v*` tag is pushed. Nobody needs a RubyGems API key: GitHub's OIDC token is swapped for a short-lived RubyGems token (trusted publishing). Publishing by hand (`gem push`, with RubyGems MFA) still works as a fallback, but a gem published that way has no provenance attestation. The repository must stay public: the environment's required reviewer and the public Sigstore attestation need it on a free account.

## What the workflow does

1. Checks out the tag; checks the tag matches `Curtilage::VERSION` and the CHANGELOG has a section for it; runs `bundle exec rake` (tests and RuboCop).
2. Waits for approval in the protected `release` environment.
3. Builds the gem and attests its provenance (`actions/attest-build-provenance`: a Sigstore-signed statement that this repository's workflow built this file from this commit, recorded in GitHub's attestation store).
4. Drafts the GitHub release (the CHANGELOG section as its notes, the `.gem` attached), so that nothing but publishing it is left once the gem is out.
5. Pushes the gem to RubyGems with the attestation attached, then publishes the draft release.

Only the release job gets write permissions (`contents`, `id-token`, `attestations`); actions are pinned to commit SHAs.

## Release steps

1. A pull request bumps `lib/curtilage/version.rb` and moves the CHANGELOG's Unreleased entries under the new version.
2. After merging: `git checkout main && git pull --ff-only`, then `git tag -a vX.Y.Z -m X.Y.Z && git push origin vX.Y.Z`.
3. Approve the `release` environment on the workflow run once the tests pass.

## One-time setup

- rubygems.org → curtilage → Trusted publishers: add a GitHub Actions publisher with repository `mohanenm/curtilage`, workflow `release.yml`, environment `release`.
- GitHub → Settings → Environments: create `release` with a required reviewer and deployment tags limited to `v*`.
- GitHub → Settings → Code security: private vulnerability reporting on (SECURITY.md sends reporters there).
- Optional: a tag ruleset limiting who can create, move or delete `v*` tags.

The approval gate stands in for MFA, which trusted publishing doesn't use. It holds because the trusted publisher is bound to the `release` environment: a tag pushed with an edited workflow that drops `environment: release` gets a token RubyGems refuses, and one that keeps it waits for the reviewer.

## Verifying a release

```sh
gh attestation verify curtilage-X.Y.Z.gem --repo mohanenm/curtilage \
  --signer-workflow mohanenm/curtilage/.github/workflows/release.yml --source-ref refs/tags/vX.Y.Z
```

With `--repo` alone it shows only that some workflow in this repository built the file; the two extra flags tie it to the release workflow and the tag. The gem's page on rubygems.org also shows the attestation.

## If a release run fails

- Before the gem is pushed: fix the cause, delete the draft release and the tag (`git push --delete origin vX.Y.Z`), tag again and push.
- After the gem is pushed (only publishing the draft is left): publish it on GitHub (Releases → the draft → Publish), or `gh release edit vX.Y.Z --draft=false`. Don't rerun the job: RubyGems refuses the same version twice.

## Not done

- The Docker image isn't published; build it from the repository (README, Docker). Publishing it with provenance would add a job pushing to GHCR.
- Signed provenance shows where a file was built, not that its code is safe; it complements review.
