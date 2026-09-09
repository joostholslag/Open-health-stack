#!/bin/sh
# hades entrypoint: self-bootstrap, then serve.
#
# On a fresh /data volume there is no terminology yet, so first boot installs
# fhir.db from the public FHIR package registry (hl7.fhir.r4.core +
# hl7.terminology.r4 — no license needed). That download + index takes minutes;
# the compose healthcheck start_period and the chart's startupProbe budget for
# it, and `make wait` should run with WAIT_TIMEOUT=420 after a volume wipe.
#
# serve picks up EVERY *.db in /data, so adding SNOMED or LOINC later
# (`make hades-snomed`, or the k8s Job runbook in charts/health-stack/README.md)
# only needs the file dropped in /data plus a restart — no image change.
set -eu
DATA_DIR="${HADES_DATA_DIR:-/data}"
PORT="${HADES_PORT:-8080}"
JAVA_OPTS="${JAVA_OPTS:--Xmx1g}"

if ! ls "${DATA_DIR}"/*.db >/dev/null 2>&1; then
  echo "hades: no *.db in ${DATA_DIR} — bootstrapping fhir.db (downloads packages, takes minutes)"
  java ${JAVA_OPTS} -jar /app/hades.jar install "${DATA_DIR}/fhir.db" \
    --dist hl7.fhir.r4.core@4.0.1 --dist hl7.terminology.r4@7.0.1
fi
exec java ${JAVA_OPTS} -jar /app/hades.jar serve "${DATA_DIR}"/*.db --port "${PORT}"
