# Packaging

Files for installing curtilage outside RubyGems. Nothing here is published automatically; none of it ships in the gem.

## Homebrew (`homebrew/curtilage.rb`)

A formula for a tap repository, `homebrew-curtilage`, under the same GitHub owner. It installs the gem from RubyGems with Homebrew's Ruby and depends on Homebrew's DuckDB.

At each release, after the gem is pushed:

1. `shasum -a 256 curtilage-X.Y.Z.gem` and update `url` and `sha256`.
2. Check it locally: `brew install --build-from-source ./packaging/homebrew/curtilage.rb`, then `brew test curtilage` and `brew audit --strict --new curtilage`.
3. Copy the formula to `Formula/curtilage.rb` in the tap repository and push.

Users then run `brew install mohanenm/curtilage/curtilage` and `curtilage doctor`.

## Docker

The repository's `Dockerfile` builds the image (gem, DuckDB checked by SHA256, extensions preinstalled, non-root, health check for `curtilage serve`). Publishing it to GitHub Container Registry for amd64 and arm64 with provenance and an SBOM is planned in `docs/design/release-plan.md` and waits for a decision to turn publishing on.
