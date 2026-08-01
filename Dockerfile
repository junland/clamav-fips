# ==============================================================================
# Stage 1 – Builder
# Compiles OpenSSL 3 (with FIPS provider) and ClamAV 1.5.3 from source.
# Ubuntu 22.04's standard openssl package does not ship fips.so, so OpenSSL
# must be built from source with the "enable-fips" option.
# ==============================================================================
FROM ubuntu:22.04 AS builder

ARG CLAMAV_VERSION=1.5.3
ARG CLAMAV_SHA256=36af674e0fa4c7a065a23de3c7e748d0c5a14df8928f9a22c68df9d6c6b36e33
ARG OPENSSL_VERSION=3.0.21
ARG OPENSSL_SHA256=617e29af8e421f46649484a4937e48c685e47f46488167c982f88bc4ec1d522f

ENV DEBIAN_FRONTEND=noninteractive

# ── Build-time dependencies ──────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        ninja-build \
        pkg-config \
        python3 \
        wget \
        perl \
        # ClamAV mandatory deps (OpenSSL provided by source build below)
        zlib1g-dev \
        libpcre2-dev \
        libxml2-dev \
        libjson-c-dev \
        libcurl4-openssl-dev \
        # Optional: milter support
        libmilter-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Build OpenSSL with FIPS provider from source ─────────────────────────────
# The Ubuntu 22.04 openssl package does not include fips.so; it must be
# compiled from source using the "enable-fips" configuration option.
WORKDIR /src
RUN wget -q "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        -O openssl.tar.gz \
    && echo "${OPENSSL_SHA256}  openssl.tar.gz" | sha256sum -c - \
    && tar -xzf openssl.tar.gz \
    && rm openssl.tar.gz

WORKDIR /src/openssl-${OPENSSL_VERSION}
RUN ./config \
        --prefix=/opt/openssl \
        --openssldir=/opt/openssl/ssl \
        --libdir=lib \
        enable-fips \
        shared \
        zlib \
    && make -j"$(nproc)" \
    && make install_sw install_fips

# ── Generate the OpenSSL FIPS provider integrity file ────────────────────────
# fipsinstall computes the HMAC of fips.so and writes the result to fips.cnf.
# Placing fips.cnf alongside fips.so lets the FIPS provider find it
# automatically at startup without needing an explicit path in openssl.cnf.
RUN /opt/openssl/bin/openssl fipsinstall \
        -out /opt/openssl/lib/ossl-modules/fips.cnf \
        -module /opt/openssl/lib/ossl-modules/fips.so

# ── Activate FIPS in the OpenSSL configuration ───────────────────────────────
RUN sed -i 's/^\(# *\)\?openssl_conf = .*/openssl_conf = openssl_init/' \
        /opt/openssl/ssl/openssl.cnf \
    && cat >> /opt/openssl/ssl/openssl.cnf <<'EOF'

# ── FIPS provider activation ──────────────────────────────────────────────────
[openssl_init]
providers = provider_sect

[provider_sect]
fips = fips_sect
base = base_sect

[fips_sect]
activate = 1

[base_sect]
activate = 1
EOF

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
        # Disable features not needed in a minimal FIPS container
        -DENABLE_EXAMPLES=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_DOCS=OFF \
        # Point cmake at the source-built, FIPS-capable OpenSSL
        -DOPENSSL_ROOT_DIR=/opt/openssl \
        -DOPENSSL_INCLUDE_DIR=/opt/openssl/include \
    && cmake --build build --parallel "$(nproc)" \
    && cmake --install build

# ==============================================================================
# Stage 2 – Runtime
# Minimal image with the FIPS-enabled OpenSSL and ClamAV install.
# ==============================================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# ── Runtime dependencies ─────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        # ClamAV runtime deps
        zlib1g \
        libpcre2-8-0 \
        libxml2 \
        libjson-c5 \
        libcurl4 \
        libmilter1.0.1 \
    && rm -rf /var/lib/apt/lists/*

# ── Copy FIPS-enabled OpenSSL from builder ────────────────────────────────────
# This brings fips.so, fips.cnf, and the patched openssl.cnf into the image.
COPY --from=builder /opt/openssl /opt/openssl

# ── Install ClamAV ────────────────────────────────────────────────────────────
COPY --from=builder /opt/clamav /opt/clamav

# Prepend our FIPS-enabled OpenSSL libraries so all binaries (including
# libcurl at runtime) resolve libssl/libcrypto from /opt/openssl/lib.
ENV PATH="/opt/openssl/bin:/opt/clamav/bin:/opt/clamav/sbin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/openssl/lib:/opt/clamav/lib"
ENV OPENSSL_CONF="/opt/openssl/ssl/openssl.cnf"

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
