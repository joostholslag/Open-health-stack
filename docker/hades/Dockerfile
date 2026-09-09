# ============================================================================
# hades — FHIR R4 terminology server (SNOMED CT / LOINC / FHIR packages).
# ----------------------------------------------------------------------------
# Upstream (https://github.com/wardle/hades) ships a plain Java 21+ JAR only —
# no official Docker image — so this stack builds its own. The upstream content
# version is pinned HERE (ARG HADES_VERSION + HADES_SHA256, bumped in lockstep;
# fetch the release's .jar.sha256 asset for the checksum), while the pushed
# image tag (ghcr.io/freshehrteam/hades:IMAGE_TAG) is the team's release tag —
# same convention as hapi-openfhir.
#
# The image is deliberately DATA-FREE: terminology lives in *.db files on the
# /data volume, bootstrapped or imported at runtime (see entrypoint.sh). Never
# bake terminology into a pushed image — SNOMED CT license terms preclude
# redistribution, and even the free FHIR packages would bloat every pull.
#
# Two stages because eclipse-temurin ships neither curl nor wget: the curl
# image fetches + checksums the JAR at build time, and curl is installed into
# the runtime layer for the compose healthcheck (GET /fhir/metadata).
# ============================================================================

ARG HADES_VERSION=2.0.282
ARG HADES_SHA256=2a069fd40ccdb9e64aae6d7360b3f1727108323b7f9db236f2d00593fdbb0bfe

FROM curlimages/curl:8.10.1 AS fetch
ARG HADES_VERSION
ARG HADES_SHA256
RUN curl -fsSL -o /tmp/hades.jar \
      "https://github.com/wardle/hades/releases/download/v${HADES_VERSION}/hades-${HADES_VERSION}.jar" \
 && echo "${HADES_SHA256}  /tmp/hades.jar" | sha256sum -c -

FROM eclipse-temurin:21-jre
RUN apt-get update && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /tmp/hades.jar /app/hades.jar
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/app/entrypoint.sh"]
