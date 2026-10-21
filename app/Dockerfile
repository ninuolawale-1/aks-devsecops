# syntax=docker/dockerfile:1
#
# Hardened multi-stage build.
#  - Stage 1 compiles a static binary with the full Go toolchain.
#  - Stage 2 ships ONLY that binary on distroless/static: no shell, no package
#    manager, no libc, runs as UID 65532. Far fewer packages = far fewer CVEs.
#
# Production tip: pin both images by digest (image@sha256:...) once you've
# pulled them, and let Dependabot/Renovate bump the digests. Tags can be moved;
# digests can't.

FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/secure-api .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/secure-api /secure-api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/secure-api"]
