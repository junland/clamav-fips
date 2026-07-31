# clamav-fips

FIPS-compatible Docker container that compiles and runs **ClamAV 1.5.3** with
OpenSSL 3's FIPS provider active.

## How it works

| Stage | What happens |
|-------|-------------|
| **Builder** | Ubuntu 22.04 image installs all build-time dependencies, runs `openssl fipsinstall` to generate the FIPS integrity file, downloads and verifies the ClamAV 1.5.3 source tarball (SHA-256 checked), then compiles ClamAV with CMake/Ninja against the system OpenSSL 3 FIPS-capable library. |
| **Runtime** | A fresh Ubuntu 22.04 image installs only runtime libraries, copies the FIPS integrity file and the compiled ClamAV installation from the builder stage, then patches `openssl.cnf` to activate the FIPS provider so every TLS/hash operation performed by ClamAV is FIPS-compliant. |

The container **entrypoint is `clamscan`**. Arguments passed to `docker run`
are forwarded directly to `clamscan`.

## Requirements

- Docker Engine ≥ 20.10 (BuildKit recommended)
- Docker Compose v2 (optional, for the convenience wrapper)

## Build

```bash
docker build -t clamav-fips:1.5.3 .
```

Or with Docker Compose:

```bash
docker compose build
```

## Usage

### Print help

```bash
docker run --rm clamav-fips:1.5.3
```

### Scan a local directory

```bash
docker run --rm \
  -v /path/to/virus-db:/var/lib/clamav:ro \
  -v /path/to/scan:/scan:ro \
  clamav-fips:1.5.3 --database=/var/lib/clamav /scan
```

### Update virus definitions first, then scan (two-step)

```bash
# 1. Update definitions using freshclam (override the entrypoint)
docker run --rm \
  -v clamav-db:/var/lib/clamav \
  --entrypoint freshclam \
  clamav-fips:1.5.3

# 2. Scan with the updated definitions
docker run --rm \
  -v clamav-db:/var/lib/clamav:ro \
  -v /path/to/scan:/scan:ro \
  clamav-fips:1.5.3 --database=/var/lib/clamav /scan
```

### Verify FIPS mode is active

```bash
docker run --rm --entrypoint openssl clamav-fips:1.5.3 list -providers
# Expected output includes: fips (active)
```

## Docker Compose

A `docker-compose.yml` is included for convenience. Edit the `source` path
under `volumes` to point at the directory you want to scan, then run:

```bash
docker compose up
```

## Build arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `CLAMAV_VERSION` | `1.5.3` | ClamAV version to compile |
| `CLAMAV_SHA256` | *(pinned)* | Expected SHA-256 of the source tarball |
