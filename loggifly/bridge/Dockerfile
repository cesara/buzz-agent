# Debian slim, not alpine: nak's release binaries are dynamically linked
# against glibc and cannot run on musl.
FROM python:3.12-slim

ARG NAK_VERSION=0.20.2
ARG TARGETARCH

# nak = nostr army knife, used offline to sign events.
# TARGETARCH is only set by buildx; fall back to uname for plain docker build.
# Downloaded with python so no wget/curl dependency. The final --version
# check fails the build loudly if the binary doesn't run on this base image.
RUN set -eux; \
    arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then \
      case "$(uname -m)" in \
        x86_64)  arch=amd64 ;; \
        aarch64) arch=arm64 ;; \
        *) echo "unsupported arch: $(uname -m)"; exit 1 ;; \
      esac; \
    fi; \
    python -c "import urllib.request; urllib.request.urlretrieve( \
      'https://github.com/fiatjaf/nak/releases/download/v${NAK_VERSION}/nak-v${NAK_VERSION}-linux-' + '${arch}', \
      '/usr/local/bin/nak')"; \
    chmod +x /usr/local/bin/nak; \
    /usr/local/bin/nak --version

RUN useradd -u 10001 bridge
USER bridge

COPY bridge.py /app/bridge.py

ENV PORT=8788
EXPOSE 8788

CMD ["python", "/app/bridge.py"]
