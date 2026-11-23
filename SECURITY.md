# Security

## Reporting a vulnerability

Please report security issues privately through GitHub: on this repository, open the **Security** tab and choose **Report a vulnerability**. Don't open a public issue for them.

Include what you found, how to reproduce it, and the version you used. You should get a reply within a week.

## Supported versions

Fixes go into the latest release only.

## Threat model

[docs/security.md](docs/security.md) says what the gem trusts and doesn't, who might attack it, the defences, and the known gaps being worked on.

## Scope

curtilage downloads public map data (Geofabrik, Overture Maps, and opt-in Microsoft footprint files), runs the DuckDB CLI on it, and treats all of that data as untrusted: downloads are limited to allowed HTTPS hosts and capped in size, and map features with oversized or invalid geometry are dropped. Reports about any of these paths are welcome.
