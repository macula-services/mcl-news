# mcl-news
#
# Sovereign news sensor: polls public RSS/Atom sources and reports each new item as a mesh fact
#
# NO DATA VOLUME AS GENERATED. The scaffold writes nothing, and a named volume
# for data that does not exist is a promise the image cannot keep. Add one
# together with the code that writes it, and declare it here and in the compose
# file at the same time.

# ⚠ THE TEAM IMAGE PAIR, PINNED BY DATED TAG AND DIGEST. macula-ci-otp builds
# (OTP 28.4.3 on an OpenSSL with ML-DSA, rebar3, Rust, cmake); the release
# runs on macula-pq-runtime, the same Debian trixie, so its ERTS and NIFs match
# the libc they run on. lint.yml pins the same build image, and the service
# tests guard all three pins and the release the RUN step below insists on.
FROM ghcr.io/macula-io/macula-ci-otp:20260923-1444@sha256:dd2ba6eb858a0eacedf0179300323fe5c6da46fb308d22da0ca8cfcd1f0718dc AS builder

# The OTP release, asserted here because the image tag names a date.
RUN erl -noshell -eval ' \
    Otp = string:trim(element(2, file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])))), \
    Mldsa = lists:member(mldsa87, crypto:supports(public_keys)), \
    io:format("OTP ~s, mldsa87 ~p~n", [Otp, Mldsa]), \
    case {Otp, Mldsa} of \
        {<<"28.4.3">>, true} -> halt(0); \
        _                    -> halt(1) \
    end.'

WORKDIR /build

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

FROM ghcr.io/macula-io/macula-pq-runtime:20260923-1444@sha256:15a5501b7277804c5a62c93121d157773d1401d238a1bf630ef4b50fc2f1df09
# LINKS THE PACKAGE TO THE REPOSITORY. On registries that read it, ghcr among
# them, a package without this label is an orphan: it does not appear on the
# repository page and does not inherit its visibility. A service that shipped
# private by accident failed its first pull with a bare "unauthorized", which
# names nothing and sends you looking in the wrong place.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-news"
# The commit this image was built from (build-push passes github.sha), so a
# digest a fleet pins can be traced back to its commit.
ARG REVISION=unknown
LABEL org.opencontainers.image.revision="${REVISION}"
# The runtime image carries what the release loads: OpenSSL 3, ncurses,
# libstdc++, CA certificates, and curl for the healthcheck below.
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/mcl_news ./

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV MCL_NODE_NAME=mcl_news
ENV MCL_NODE_HOST=127.0.0.1
ENV MCL_COOKIE=mcl_news
ENV MCL_HEALTH_PORT=8498

VOLUME ["/etc/mcl/secrets"]

EXPOSE 8498
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${MCL_HEALTH_PORT}/health" || exit 1

CMD ["/app/bin/mcl_news", "foreground"]
