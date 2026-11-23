# curtilage with the DuckDB CLI and its extensions, ready to run:
#
#   docker build -t curtilage .
#   docker run --rm curtilage generate --pin -80.0,35.0
#   docker run --rm -v "$PWD:/work" curtilage generate --in pins.csv --out premises.geojson
#
# Add -v curtilage-cache:/cache to keep on-demand builds between runs
# (reused for a month). The image also runs with a read-only root
# filesystem: --read-only --tmpfs /tmp -v curtilage-cache:/cache.
#
# The base image is pinned by digest and the DuckDB download by SHA256
# (Dependabot proposes base-image updates). To change DuckDB's version,
# pass --build-arg DUCKDB_VERSION= with that release's two checksums.

ARG RUBY_IMAGE=ruby:3.3-slim@sha256:bd9d41c0a4be443c6f750b5af47080e5dbea9cfaf2eb135d86b8d021ab04babf

FROM ${RUBY_IMAGE} AS build

ARG DUCKDB_VERSION=1.4.4
ARG DUCKDB_SHA256_AMD64=ea79eae4233f1aba9a020c8a61877de38a789bc62cdd37485d3589cd77dc0d3e
ARG DUCKDB_SHA256_ARM64=97995363217ddef691fe53b26df3b55ff368d356613d9daaea5999bb7a637e60
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && case "$arch" in \
      amd64) sum="$DUCKDB_SHA256_AMD64" ;; \
      arm64) sum="$DUCKDB_SHA256_ARM64" ;; \
      *) echo "no DuckDB checksum for $arch" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/duckdb.zip \
      "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${arch}.zip" \
 && echo "${sum}  /tmp/duckdb.zip" | sha256sum -c - \
 && unzip /tmp/duckdb.zip -d /usr/local/bin \
 && rm /tmp/duckdb.zip \
 && duckdb --version

# Only what the gem ships (see the gemspec); never the local data folder.
WORKDIR /src
COPY curtilage.gemspec README.md CHANGELOG.md LICENSE.txt SECURITY.md ./
COPY lib lib
COPY sql sql
COPY exe exe
COPY docs/reference.md docs/security.md docs/
RUN gem build curtilage.gemspec \
 && gem install --no-document curtilage-*.gem

# The image that runs: the gem and DuckDB, no build tools (curl, unzip).
FROM ${RUBY_IMAGE}

COPY --from=build /usr/local/bin/duckdb /usr/local/bin/duckdb
COPY --from=build /usr/local/bundle /usr/local/bundle

RUN useradd --create-home curtilage \
 && mkdir -p /cache /work \
 && chown curtilage /cache /work \
 && chmod 700 /cache
USER curtilage
ENV CURTILAGE_EXTENSIONS=/home/curtilage/.duckdb/extensions \
    CURTILAGE_CACHE_DIR=/cache
# Fetch DuckDB's extensions once, at build time, not on every run: the
# image then also works offline (CURTILAGE_OFFLINE=1).
RUN curtilage doctor

VOLUME ["/cache"]
WORKDIR /work
ENTRYPOINT ["curtilage"]
CMD ["--help"]
