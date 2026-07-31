FROM python:3.12-alpine

ARG NAK_VERSION=0.20.2
ARG TARGETARCH

# nak = nostr army knife, used offline to sign events (static Go binary, works on musl).
# TARGETARCH is only set by buildx; fall back to uname so plain `docker build`
# (which Coolify may use) gets the right binary too. The final --version check
# fails the build loudly if the download didn't produce a working binary.
RUN set -eux; \
    arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then \
      case "$(uname -m)" in \
        x86_64)  arch=amd64 ;; \
        aarch64) arch=arm64 ;; \
        *) echo "unsupported arch: $(uname -m)"; exit 1 ;; \
      esac; \
    fi; \
    wget -O /usr/local/bin/nak \
      "https://github.com/fiatjaf/nak/releases/download/v${NAK_VERSION}/nak-v${NAK_VERSION}-linux-${arch}"; \
    chmod +x /usr/local/bin/nak; \
    /usr/local/bin/nak --version

RUN adduser -D -u 10001 bridge
USER bridge

COPY bridge.py /app/bridge.py

ENV PORT=8788
EXPOSE 8788

CMD ["python", "/app/bridge.py"]
