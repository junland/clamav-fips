# ==============================================================================
# Stage 1 – Builder
# Compiles ClamAV 1.5.3 from source against OpenSSL 3 FIPS provider on Alpine.
# ==============================================================================
FROM alpine:3.24 AS builder

ARG CLAMAV_VERSION=1.5.3
ARG CLAMAV_SHA256=36af674e0fa4c7a065a23de3c7e748d0c5a14df8928f9a22c68df9d6c6b36e33

# ── Build-time dependencies ──────────────────────────────────────────────────
RUN apk add --no-cache \
        build-base \
        cmake \
        ninja \
        pkgconf \
        python3 \
        wget \
        rust \
        cargo \
        openssl-devel \
        openssl-fips \
        zlib-dev \
        pcre2-dev \
        libxml2-dev \
        json-c-dev \
        curl-dev \
        libmilter-dev

# ── Generate the OpenSSL FIPS provider integrity file ────────────────────────
RUN openssl fipsinstall \
        -out /etc/ssl/fips.cnf \
        -module /usr/lib/ossl-modules/fips.so

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
        -DENABLE_EXAMPLES=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_DOCS=OFF \
        -DOPENSSL_ROOT_DIR=/usr \
    && cmake --build build --parallel "$(nproc)" \
    && cmake --install build


# ==============================================================================
# Stage 2 – Runtime
# Minimal Alpine runtime image with OpenSSL 3 FIPS active.
# ==============================================================================
FROM alpine:3.24

# ── Runtime dependencies ─────────────────────────────────────────────────────
RUN apk add --no-cache \
        openssl \
        openssl-fips \
        zlib \
        pcre2 \
        libxml2 \
        json-c \
        curl \
        libmilter

# ── Enable OpenSSL FIPS provider ─────────────────────────────────────────────
COPY --from=builder /etc/ssl/fips.cnf /etc/ssl/fips.cnf

RUN sed -i 's/^\(# *\)\?openssl_conf = .*/openssl_conf = openssl_init/' /etc/ssl/openssl.cnf \
    && cat >> /etc/ssl/openssl.cnf <<'EOF'

# ── FIPS provider activation ──────────────────────────────────────────────────
[openssl_init]
providers = provider_sect

[provider_sect]
fips = fips_sect
base = base_sect

[fips_sect]
activate = 1
module-mac = /etc/ssl/fips.cnf

[base_sect]
activate = 1
EOF

# ── Install ClamAV ────────────────────────────────────────────────────────────
COPY --from=builder /opt/clamav /opt/clamav
ENV PATH="/opt/clamav/bin:/opt/clamav/sbin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/clamav/lib:${LD_LIBRARY_PATH}"

# ── Create dedicated system user (deterministic UID/GID) ──────────────────────
RUN addgroup -g 101 -S clamav \
    && adduser -u 101 -S -G clamav -s /sbin/nologin -h /var/lib/clamav clamav \
    && mkdir -p \
        /var/lib/clamav \
        /var/log/clamav \
        /var/run/clamav \
    && chown -R clamav:clamav \
        /var/lib/clamav \
        /var/log/clamav \
        /var/run/clamav \
        /opt/clamav/etc

# ── Default ClamAV configuration ─────────────────────────────────────────────
RUN cp /opt/clamav/etc/freshclam.conf.sample /opt/clamav/etc/freshclam.conf \
    && sed -i \
        -e 's/^Example/#Example/' \
        -e 's|^#\?DatabaseDirectory.*|DatabaseDirectory /var/lib/clamav|' \
        -e 's|^#\?UpdateLogFile.*|UpdateLogFile /var/log/clamav/freshclam.log|' \
        /opt/clamav/etc/freshclam.conf

RUN cp /opt/clamav/etc/clamd.conf.sample /opt/clamav/etc/clamd.conf \
    && sed -i \
        -e 's/^Example/#Example/' \
        -e 's|^#\?DatabaseDirectory.*|DatabaseDirectory /var/lib/clamav|' \
        -e 's|^#\?LogFile.*|LogFile /var/log/clamav/clamd.log|' \
        -e 's|^#\?LocalSocket.*|LocalSocket /var/run/clamav/clamd.sock|' \
        -e 's|^#\?PidFile.*|PidFile /var/run/clamav/clamd.pid|' \
        /opt/clamav/etc/clamd.conf

# ── Verification & Healthcheck ────────────────────────────────────────────────
# Confirm OpenSSL FIPS provider loads correctly during build
RUN openssl list -providers | grep -i fips

HEALTHCHECK --interval=60s --timeout=30s --start-period=120s --retries=3 \
    CMD clamscan --version && openssl list -providers | grep -i "fips" || exit 1

USER clamav
WORKDIR /var/lib/clamav

ENTRYPOINT ["clamscan"]
CMD ["--help"]
