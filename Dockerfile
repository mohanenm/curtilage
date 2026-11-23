# curtilage with the DuckDB CLI and its extensions, ready to run:
#
#   docker build -t curtilage .
#   docker run --rm curtilage generate --pin -80.0,35.0
#   docker run --rm -v "$PWD:/work" curtilage generate --in pins.csv --out premises.geojson
#
# Add -v curtilage-cache:/cache to keep on-demand builds between runs
# (reused for a month).
FROM ruby:3.3-slim

ARG DUCKDB_VERSION=1.4.4
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && curl -fsSL -o /tmp/duckdb.zip \
      "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${arch}.zip" \
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
 && gem install --no-document curtilage-*.gem \
 && rm -rf /src

RUN useradd --create-home curtilage \
 && mkdir -p /cache /work \
 && chown curtilage /cache /work
USER curtilage
ENV CURTILAGE_EXTENSIONS=/home/curtilage/.duckdb/extensions \
    CURTILAGE_CACHE_DIR=/cache
# Fetch DuckDB's extensions once, at build time, not on every run.
RUN curtilage doctor

WORKDIR /work
ENTRYPOINT ["curtilage"]
CMD ["--help"]
