# syntax=docker/dockerfile:1
#
# rf-comments — multi-stage build.
#
#   docker build -t rf-comments .            # runtime image
#   docker build --target test .             # run the test-suite in Docker
#
# The SQLite database lives in /data, which must be a volume / bind mount.

ARG DEBIAN_IMAGE=debian:trixie-slim

# ---------------------------------------------------------------- build ----
FROM ${DEBIAN_IMAGE} AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends sbcl curl ca-certificates libsqlite3-0 libssl3t64 \
 && rm -rf /var/lib/apt/lists/*

# Quicklisp, pinned to one dist version for reproducible builds.
ARG QL_DIST=2026-01-01
ARG QL_SHA256=4a7a5c2aebe0716417047854267397e24a44d0cce096127411e9ce9ccfeb2c17
RUN curl -fsSL -o /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp \
 && echo "${QL_SHA256}  /tmp/quicklisp.lisp" | sha256sum -c - \
 && sbcl --non-interactive --load /tmp/quicklisp.lisp \
      --eval "(quicklisp-quickstart:install :path \"/opt/quicklisp/\" :dist-url \"http://beta.quicklisp.org/dist/quicklisp/${QL_DIST}/distinfo.txt\")" \
 && rm /tmp/quicklisp.lisp
ENV QUICKLISP_HOME=/opt/quicklisp/

WORKDIR /build
# Fetch and compile dependencies in their own layer (cached until the .asd changes).
COPY rf-comments.asd ./
RUN sbcl --non-interactive --load /opt/quicklisp/setup.lisp \
      --eval '(push (uiop:getcwd) asdf:*central-registry*)' \
      --eval '(ql:quickload (append (asdf:system-depends-on (asdf:find-system "rf-comments")) (list "fiveam" "cl-cookie")))'

COPY src ./src
COPY static ./static
COPY build.lisp ./
RUN sbcl --non-interactive --load build.lisp

# ----------------------------------------------------------------- test ----
FROM build AS test
COPY tests ./tests
RUN sbcl --non-interactive --load /opt/quicklisp/setup.lisp \
      --eval '(push (uiop:getcwd) asdf:*central-registry*)' \
      --eval '(ql:quickload :rf-comments/tests)' \
      --eval '(asdf:test-system :rf-comments)'

# -------------------------------------------------------------- runtime ----
FROM ${DEBIAN_IMAGE} AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends libsqlite3-0 libssl3t64 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --home-dir /nonexistent --shell /usr/sbin/nologin app \
 && mkdir /data && chown app:app /data

COPY --from=build /build/bin/rf-comments /usr/local/bin/rf-comments

ENV PORT=8080 \
    DB_PATH=/data/comments.db \
    EMAIL_BACKEND=log
VOLUME ["/data"]
EXPOSE 8080
USER app
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/usr/local/bin/rf-comments", "healthcheck"]
ENTRYPOINT ["/usr/local/bin/rf-comments"]
