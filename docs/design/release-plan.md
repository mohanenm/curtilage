# Release plan: trusted publishing, provenance, SBOM

Status: proposal, not in effect. Releases are still published by hand (`gem push`, with RubyGems MFA required).

## Goal

Anyone can check that a published gem or Docker image was built by this repository's CI from a tagged commit, and nobody needs a long-lived RubyGems API key.

## Proposal

**1. RubyGems trusted publishing (OIDC).** A `release.yml` workflow, run when a `v*` tag is pushed:

1. checks out the tag and runs `bundle exec rake` (tests and RuboCop);
2. waits for approval in a protected GitHub environment named `release` (you as the required reviewer);
3. builds the gem and publishes it with `rubygems/release-gem` (pinned to a commit SHA), which swaps GitHub's OIDC token for a short-lived RubyGems token. No API key is stored anywhere.

**2. Provenance for the gem.** The same job attests the `.gem` file (`actions/attest-build-provenance`, Sigstore-signed, recorded in GitHub's attestation store); `release-gem` can also upload the attestation to RubyGems. Users check it with `gh attestation verify curtilage-X.Y.Z.gem --repo mohanenm/curtilage`.

**3. The Docker image.** A second job builds `linux/amd64` and `linux/arm64` with `docker/build-push-action` (pinned), with BuildKit provenance (`mode=max`) and an SBOM attached, pushes `ghcr.io/mohanenm/curtilage:X.Y.Z` and `:latest`, and attests the image (`push-to-registry: true`). Users check it with `gh attestation verify oci://ghcr.io/mohanenm/curtilage:X.Y.Z --repo mohanenm/curtilage`.

**4. A GitHub release** with the changelog section for the version, the `.gem` attached.

**Permissions**: only the release jobs get `id-token: write` (OIDC), `attestations: write`, `contents: write` (the GitHub release) and `packages: write` (GHCR); everything else stays read-only.

## Release steps, once set up

1. A pull request bumps `lib/curtilage/version.rb` and moves the changelog's Unreleased entries under the new version.
2. After merging, tag the merge commit `vX.Y.Z` and push the tag.
3. Approve the `release` environment when the tests pass. The gem, image, attestations and GitHub release follow.

## One-time setup (yours; I can't do these)

- rubygems.org → curtilage → Trusted publishers: add GitHub Actions, repository `mohanenm/curtilage`, workflow `release.yml`, environment `release`.
- GitHub → Settings → Environments: create `release`, required reviewer you, deployment tags `v*` only.
- GitHub → Settings → Code security: turn on **private vulnerability reporting** (SECURITY.md points people to it) and Dependabot alerts.
- After the first image push: make the GHCR package public and link it to the repository.

## Trade-offs

- A compromised workflow could publish. Against that: the approval gate, actions pinned to SHAs, least-privilege permissions, and tag-only triggers.
- Manual `gem push` with MFA stays possible as a fallback. Trusted publishing needs no OTP, so the approval gate is what stands in for it.
- CI talks to new hosts (GHCR, Sigstore, RubyGems' OIDC exchange). That's CI only; the gem itself still contacts only map-data hosts.
- Signed provenance proves where an artifact was built, not that the code is safe; it complements, not replaces, review.

## Decisions needed

1. Adopt RubyGems trusted publishing with an approval gate?
2. Publish the Docker image to GHCR (amd64 and arm64) on each release?
3. Keep manual `gem push` (MFA) as a fallback?
