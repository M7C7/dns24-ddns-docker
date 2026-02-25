FROM alpine:3.19

LABEL maintainer="Mr7Chris7"
LABEL description="DDNS Updater for dns24.ch — multi-type records, NS verification, outage detection, Discord notifications, propagation tracking"
LABEL version="2.0.0"

RUN apk add --no-cache \
    bash \
    curl \
    bind-tools \
    tzdata

ENV TZ=Europe/Zurich
ENV CONFIG_DIR=/config

RUN mkdir -p /opt/ddns-updater /config/meta /config/records

COPY script/ddns-updater.sh /opt/ddns-updater/ddns-updater.sh
COPY entrypoint.sh /opt/ddns-updater/entrypoint.sh
COPY .env.example /opt/ddns-updater/.env.example

RUN chmod +x /opt/ddns-updater/ddns-updater.sh /opt/ddns-updater/entrypoint.sh

VOLUME ["/config"]

ENTRYPOINT ["/opt/ddns-updater/entrypoint.sh"]
