# ==============================================================================
# Stage 1 – Builder
# Compiles ClamAV from source against OpenSSL 3 FIPS provider.
# ==============================================================================
FROM debian:testing AS builder

ARG CLAMAV_VERSION=1.5.3
ARG CLAMAV_SHA256=89af57a45bbf13de4dc91ed7f20b435388c88428eb7dc30639a02b2f0fc2dad1

ENV DEBIAN_FRONTEND=noninteractive

# ── Build-time dependencies ──────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cargo \
        cmake \
        ninja-build \
        pkg-config \
        python3 \
        rustc \
        wget \
        dpkg-dev \
        # ClamAV mandatory deps
        openssl \
        libssl-dev \
        libbz2-dev \
        libncurses-dev \
        zlib1g-dev \
        libpcre2-dev \
        libxml2-dev \
        libjson-c-dev \
        libcurl4-openssl-dev \
        # Optional: milter support
        libmilter-dev \
        openssl-provider-fips \
    && rm -rf /var/lib/apt/lists/*

# ── Enable the distro-provided OpenSSL FIPS provider ─────────────────────────
RUN openssl fipsinstall \
        -module /usr/lib/*/ossl-modules/fips.so \
        -out /etc/ssl/fipsmodule.cnf \
    && sed -i \
        -e 's|^# \.include fipsmodule.cnf|.include /etc/ssl/fipsmodule.cnf|' \
        -e 's|^# fips = fips_sect|fips = fips_sect|' \
        /etc/ssl/openssl.cnf

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
# Minimal image with the FIPS provider active and ClamAV installed.
# ==============================================================================
FROM debian:testing

ENV DEBIAN_FRONTEND=noninteractive

# ── Runtime dependencies ─────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssl \
        openssl-provider-fips \
        libbz2-1.0 \
        libncursesw6 \
        zlib1g \
        libpcre2-8-0 \
        libxml2-16 \
        libjson-c5 \
        libcurl4t64 \
        libmilter1.0.1 \
    && rm -rf /var/lib/apt/lists/*

# ── Enable OpenSSL FIPS provider and install ClamAV ──────────────────────────
RUN openssl fipsinstall \
        -module /usr/lib/*/ossl-modules/fips.so \
        -out /etc/ssl/fipsmodule.cnf \
    && sed -i \
        -e 's|^# \.include fipsmodule.cnf|.include /etc/ssl/fipsmodule.cnf|' \
        -e 's|^# fips = fips_sect|fips = fips_sect|' \
        /etc/ssl/openssl.cnf
COPY --from=builder /opt/clamav /opt/clamav
ENV PATH="/opt/clamav/bin:/opt/clamav/sbin:${PATH}"

# ── Create dedicated system user (deterministic UID/GID) ──────────────────────
RUN groupadd -g 101 -r clamav \
    && useradd -u 101 -r -g clamav -s /usr/sbin/nologin -d /var/lib/clamav clamav \
    && mkdir -p \
        /var/lib/clamav \
        /var/log/clamav \
        /var/run/clamav \
    && chown -R clamav:clamav \
        /var/lib/clamav \
        /var/log/clamav \
        /var/run/clamav \
        /opt/clamav/etc

RUN echo /opt/clamav/lib > /etc/ld.so.conf.d/clamav.conf \
    && ldconfig

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
# Confirm OpenSSL FIPS provider loads correctly at build time
RUN openssl list -providers | grep -i fips

HEALTHCHECK --interval=60s --timeout=30s --start-period=120s --retries=3 \
    CMD clamscan --version && openssl list -providers | grep -i "fips" || exit 1

USER clamav
WORKDIR /var/lib/clamav

ENTRYPOINT ["clamscan"]
CMD ["--help"]
