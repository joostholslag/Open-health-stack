# ghcr.io/freshehrteam/hapi-openfhir = stock HAPI FHIR + the openFHIR interceptor JAR.
#
# That is the entire delta over hapiproject/hapi: the interceptor on the classpath
# and the IPS operation enabled. Nothing else is customised.
#
# The interceptor JAR is a build input from
#   https://github.com/openFHIR/openfhir-hapi-interceptor
# Build that repo (`mvn clean package -DskipTests`) and drop the resulting
# target/*.jar into ./extra-classes/ before `docker compose build hapi`.
# (extra-classes/*.jar is gitignored — see repo .gitignore.)
#
# HAPI auto-loads any JAR in /app/extra-classes onto the classpath, and
# application.yml wires the interceptor beans via
#   hapi.fhir.custom_bean_packages: com.syntaric
#   hapi.fhir.custom_interceptor_classes: com.syntaric.hapi.PatientInterceptor
#
# Alternative: build the interceptor repo's own multi-stage Dockerfile directly
# and reference that image instead of this one.

# The upstream HAPI pin. The interceptor JAR is compiled against this HAPI
# generation — a major base bump means recompiling the JAR too.
ARG HAPI_BASE=hapiproject/hapi:v8.2.0-2
FROM ${HAPI_BASE}

# Layer the pre-built interceptor JAR onto the HAPI classpath.
COPY extra-classes/ /app/extra-classes/

# Enable HAPI's built-in International Patient Summary ($summary) operation.
ENV HAPI_FHIR_IPS_ENABLED=true

# 8080 = FHIR API, 5005 = JVM remote debug (see docker-compose.override.yml).
EXPOSE 8080 5005
