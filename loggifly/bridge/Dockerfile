FROM python:3.12-alpine

ARG NAK_VERSION=0.20.2
ARG TARGETARCH

# nak = nostr army knife, used offline to sign events (static Go binary, works on musl)
RUN wget -q -O /usr/local/bin/nak \
      "https://github.com/fiatjaf/nak/releases/download/v${NAK_VERSION}/nak-v${NAK_VERSION}-linux-${TARGETARCH}" \
    && chmod +x /usr/local/bin/nak

RUN adduser -D -u 10001 bridge
USER bridge

COPY bridge.py /app/bridge.py

ENV PORT=8788
EXPOSE 8788

CMD ["python", "/app/bridge.py"]
