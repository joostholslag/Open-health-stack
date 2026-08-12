# openfhir/fhirconnect-ips-mappings — the IPS FHIRConnect mapping bundle.
#
# NOT an openFHIR engine build. This is a data-only image: a versioned bundle of the
# FHIRConnect mapping YAMLs + the IPS operational template (OPT) under /bootstrap.
#
# Why an image at all? The engine loads its mappings from a directory
# (openfhir.bootstrap.dir). Compose bind-mounts ./openfhir/bootstrap straight off the
# host, but Kubernetes has no host directory to mount — so the files have to be
# delivered some other way. The payload is ~3.1 MB (the OPT alone is ~3 MB of XML),
# which is over the ~1 MiB ConfigMap limit, so shipping it as an OCI artifact and
# copying it in via an initContainer is the standard approach. (Once clusters are on
# k8s 1.33+, `volumes[].image` can mount this directly and the initContainer goes away.)
#
# Build + push (see the Makefile targets `images` / `images-push`):
#   docker build -f docker/openfhir/bootstrap.Dockerfile \
#     -t openfhir/fhirconnect-ips-mappings:<tag> docker/openfhir
FROM busybox:1.36
COPY bootstrap/ /bootstrap/
