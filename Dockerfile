# ==============================================================================
# Stage 1 – Builder
# Compiles ClamAV 1.5.3 from source against an OpenSSL 3 FIPS provider.
# ==============================================================================
FROM ubuntu:22.04 AS builder

ARG CLAMAV_VERSION=1.5.3
ARG CLAMAV_SHA256=36af674e0fa4c7a065a23de3c7e748d0c5a14df8928f9a22c68df9d6c6b36e33

ENV DEBIAN_FRONTEND=noninteractive

# ── Build-time dependencies ──────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        ninja-build \
        pkg-config \
        python3 \
        wget \
        # OpenSSL CLI (needed for openssl fipsinstall) + dev headers
        openssl \
        libssl-dev \
        zlib1g-dev \
        libpcre2-dev \
        libxml2-dev \
        libjson-c-dev \
        libcurl4-openssl-dev \
        # Optional: milter support
        libmilter-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Generate the OpenSSL FIPS provider integrity file ────────────────────────
# openssl fipsinstall writes fips.cnf which binds the FIPS module to its HMAC.
RUN openssl fipsinstall \
        -out /etc/ssl/fips.cnf \
        -module /usr/lib/x86_64-linux-gnu/ossl-modules/fips.so

# ── Download and verify ClamAV source ────────────────────────────────────────
WORKDIR /src
RUN wget -q "https://github.com/Cisco-Talos/clamav/releases/download/clamav-${CLAMAV_VERSION}/clamav-${CLAMAV_VERSION}.tar.gz" \
        -O "clamav-${CLAMAV_VERSION}.tar.gz" \
    && echo "${CLAMAV_SHA256}  clamav-${CLAMAV_VERSION}.tar.gz" | sha256sum -c - \
    && tar -xzf "clamav-${CLAMAV_VERSION}.tar.gz" \
    && rm "clamav-${CLAMAV_VERSION}.tar.gz"

# ── Build ClamAV ─────────────────────────────────────────────────────────────
WORKDIR /src/clamav-${CLAMAV_VERSION}
RUN cmake -G Ninja -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/clamav \
        # Disable features that are not needed in a minimal FIPS container
        -DENABLE_EXAMPLES=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_DOCS=OFF \
        # Point cmake at the system OpenSSL 3 (FIPS-capable)
        -DOPENSSL_ROOT_DIR=/usr \
    && cmake --build build --parallel "$(nproc)" \
    && cmake --install build

# ==============================================================================
# Stage 2 – Runtime
# Minimal image with the FIPS provider active and the ClamAV install dropped in.
# ==============================================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# ── Runtime dependencies ─────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        # OpenSSL 3 runtime + FIPS provider module
        openssl \
        libssl3 \
        # ClamAV runtime deps
        zlib1g \
        libpcre2-8-0 \
        libxml2 \
        libjson-c5 \
        libcurl4 \
        libmilter1.0.1 \
    && rm -rf /var/lib/apt/lists/*

# ── Enable OpenSSL FIPS provider ─────────────────────────────────────────────
# Copy the HMAC integrity file produced by "openssl fipsinstall" in the builder.
COPY --from=builder /etc/ssl/fips.cnf /etc/ssl/fips.cnf

# Patch the global openssl.cnf to activate the FIPS provider and make it the
# default, while keeping the base provider available for internal TLS plumbing.
RUN sed -i 's/^\(# *\)\?openssl_conf = .*/openssl_conf = openssl_init/' \
        /etc/ssl/openssl.cnf \
    && cat >> /etc/ssl/openssl.cnf <<'EOF'

# ── FIPS provider activation ──────────────────────────────────────────────────
[openssl_init]
providers = provider_sect

[provider_sect]
fips = fips_sect
base = base_sect

[fips_sect]
activate = 1
# Load integrity data from the fipsinstall step
module-mac = /etc/ssl/fips.cnf

[base_sect]
activate = 1
EOF

# ── Install ClamAV ────────────────────────────────────────────────────────────
COPY --from=builder /opt/clamav /opt/clamav
ENV PATH="/opt/clamav/bin:/opt/clamav/sbin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/clamav/lib:${LD_LIBRARY_PATH}"

# ── Create dedicated system user and required directories ─────────────────────
RUN groupadd -r clamav \
    && useradd -r -g clamav -s /usr/sbin/nologin -d /var/lib/clamav clamav \
    && mkdir -p \
        /var/lib/clamav \
        /var/log/clamav \
        /var/run/clamav \
    && chown -R clamav:clamav \
        /var/lib/clamav \
        /var/log/clamav \
        /var/run/clamav \
        /opt/clamav/etc

# ── Default ClamAV configuration (minimal, FIPS-friendly) ────────────────────
# freshclam.conf
RUN cp /opt/clamav/etc/freshclam.conf.sample /opt/clamav/etc/freshclam.conf \
    && sed -i \
        -e 's/^Example/#Example/' \
        -e 's|^#\?DatabaseDirectory.*|DatabaseDirectory /var/lib/clamav|' \
        -e 's|^#\?UpdateLogFile.*|UpdateLogFile /var/log/clamav/freshclam.log|' \
        /opt/clamav/etc/freshclam.conf

# clamd.conf
RUN cp /opt/clamav/etc/clamd.conf.sample /opt/clamav/etc/clamd.conf \
    && sed -i \
        -e 's/^Example/#Example/' \
        -e 's|^#\?DatabaseDirectory.*|DatabaseDirectory /var/lib/clamav|' \
        -e 's|^#\?LogFile.*|LogFile /var/log/clamav/clamd.log|' \
        -e 's|^#\?LocalSocket.*|LocalSocket /var/run/clamav/clamd.sock|' \
        -e 's|^#\?PidFile.*|PidFile /var/run/clamav/clamd.pid|' \
        /opt/clamav/etc/clamd.conf

# ── Healthcheck ───────────────────────────────────────────────────────────────
HEALTHCHECK --interval=60s --timeout=30s --start-period=120s --retries=3 \
    CMD clamscan --version || exit 1

USER clamav
WORKDIR /var/lib/clamav

# clamscan is the entrypoint; pass extra flags or paths via `docker run`.
# Example: docker run --rm clamav-fips /scan-target --database=/var/lib/clamav
ENTRYPOINT ["clamscan"]
CMD ["--help"]
