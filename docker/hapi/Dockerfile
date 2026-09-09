# ghcr.io/freshehrteam/hapi-openfhir = stock HAPI FHIR + the openFHIR interceptor JAR.
#
# That is the entire delta over hapiproject/hapi: the interceptor on the classpath
# and the IPS operation enabled. Nothing else is customised.
#
# The interceptor JAR is fetched at build time from the GitHub release asset of
#   https://github.com/openFHIR/openfhir-hapi-interceptor
# pinned by ARG INTERCEPTOR_VERSION (below). No local file, no mvn build: the
# release asset is the single source of truth. If the pinned version has no
# published .jar asset the build FAILS (curl -f) — pin a version that does
# (releases ≥ 2.0.0 ship the asset; older tags publish none).
#
# HAPI auto-loads any JAR on /app/extra-classes onto the classpath (the base
# image's entrypoint sets -Dloader.path=…,/app/extra-classes), and
# application.yml wires the interceptor beans via
#   hapi.fhir.custom_bean_packages: com.syntaric
#   hapi.fhir.custom_interceptor_classes: com.syntaric.hapi.PatientInterceptor

# ── Global pins (both consumed by scripts/versions.sh) ───────────────────────
# Interceptor release tag. Compiled against a specific HAPI FHIR library version;
# keep compatible with HAPI_BASE (a major HAPI bump may need a newer release).
ARG INTERCEPTOR_VERSION=2.0.0
# The upstream HAPI pin. A major base bump means pinning a newer
# INTERCEPTOR_VERSION built against that generation.
ARG HAPI_BASE=hapiproject/hapi:v8.4.0-3

# ── Fetch stage: download the pinned release asset (fail hard on 404) ─────────
FROM curlimages/curl:8.11.1 AS fetch
ARG INTERCEPTOR_VERSION
RUN curl -fsSL \
      -o /tmp/openfhir-hapi-interceptor.jar \
      "https://github.com/openFHIR/openfhir-hapi-interceptor/releases/download/${INTERCEPTOR_VERSION}/openfhir-hapi-interceptor-${INTERCEPTOR_VERSION}.jar"

# ── HAPI image ───────────────────────────────────────────────────────────────
FROM ${HAPI_BASE}

# Layer the fetched interceptor JAR onto the HAPI classpath.
COPY --from=fetch /tmp/openfhir-hapi-interceptor.jar /app/extra-classes/openfhir-hapi-interceptor.jar

# Enable HAPI's built-in International Patient Summary ($summary) operation.
ENV HAPI_FHIR_IPS_ENABLED=true

# 8080 = FHIR API, 5005 = JVM remote debug (see docker-compose.override.yml).
EXPOSE 8080 5005
