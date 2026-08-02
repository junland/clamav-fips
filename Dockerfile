# ==============================================================================
# Stage 1 – Builder
# Compiles ClamAV 1.5.3 from source against OpenSSL 3 FIPS provider on Alpine.
# ==============================================================================
FROM alpine:3.24 AS builder

ARG CLAMAV_VERSION=1.5.3
ARG CLAMAV_SHA256=89af57a45bbf13de4dc91ed7f20b435388c88428eb7dc30639a02b2f0fc2dad1

# ── Build-time dependencies ──────────────────────────────────────────────────
RUN apk add --no-cache \
        build-base \
        bzip2-dev \
        cargo \
        check-dev \
        cmake \
        curl-dev \
        json-c-dev \
        libmilter-dev \
        libmspack-dev \
        libxml2-dev \
        linux-headers \
        musl-fts-dev \
        ncurses-dev \
        ninja \
        openssl-dev \
        openssl-fips \
        pcre2-dev \
        pkgconf \
        python3 \
        rust \
        rust-bindgen \
        rust-lldb \
        rustfmt \
        rustup \
        samurai \
        wget \
        zlib-dev


RUN mkdir -p /src

# ── Download and verify ClamAV source ────────────────────────────────────────
WORKDIR /src

RUN wget -q "https://github.com/Cisco-Talos/clamav/releases/download/clamav-${CLAMAV_VERSION}/clamav-${CLAMAV_VERSION}.tar.gz" -O "clamav-${CLAMAV_VERSION}.tar.gz" 
        
RUN echo "${CLAMAV_SHA256}  clamav-${CLAMAV_VERSION}.tar.gz" | sha256sum -c -

RUN tar -xzf "clamav-${CLAMAV_VERSION}.tar.gz" && rm "clamav-${CLAMAV_VERSION}.tar.gz"

# ── Build ClamAV ─────────────────────────────────────────────────────────────
WORKDIR /src/clamav-${CLAMAV_VERSION}
RUN cmake -B build -G Ninja \
		-DCMAKE_BUILD_TYPE=None \
		-DCMAKE_INSTALL_PREFIX=/usr \
		-DCMAKE_INSTALL_LIBDIR=/usr/lib \
		-DCMAKE_SKIP_INSTALL_RPATH=ON \
		-DAPP_CONFIG_DIRECTORY=/etc/clamav \
		-DDATABASE_DIRECTORY=/var/lib/clamav \
		-DENABLE_DOXYGEN=OFF \
		-DENABLE_SYSTEMD=OFF \
		-DENABLE_TESTS=ON \
		-DENABLE_CLAMONACC=ON \
		-DENABLE_MILTER=ON \
		-DENABLE_EXTERNAL_MSPACK=ON \
		-DENABLE_EXAMPLES=ON \
		-DENABLE_EXAMPLES_DEFAULT=ON \
		-DHAVE_SYSTEM_LFS_FTS=ON \
		-DENABLE_JSON_SHARED=ON

RUN cmake --build build

RUN cmake --install build --prefix /opt/clamav

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
COPY --from=builder /etc/ssl/fipsmodule.cnf /etc/ssl/fips.cnf

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

# Create symlinks for ClamAV binaries in /usr/bin and /usr/sbin
RUN ln -s /opt/clamav/bin/* /usr/bin/ \
    && ln -s /opt/clamav/sbin/* /usr/sbin/

# Create symlinks for ClamAV libraries in /usr/lib
RUN ln -s /opt/clamav/lib/* /usr/lib/

# Create symlinks for ClamAV configuration files in /etc/clamav
RUN mkdir -p /etc/clamav \
    && ln -s /opt/clamav/etc/* /etc/clamav/

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
