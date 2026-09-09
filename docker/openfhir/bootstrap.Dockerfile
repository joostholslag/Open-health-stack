# ghcr.io/freshehrteam/fhirconnect-eps-mappings — the FHIRConnect mapping bundle.
#
# NOT an openFHIR engine build. This is a data-only image: a versioned bundle of the
# FHIRConnect mapping YAMLs + EVERY operational template (OPT) under /bootstrap.
#
# It carries more than one template — the image name is historical. `make template`
# and `make bootstrap` both work off this same directory, so an OPT added here is
# picked up by EHRbase and by the engine without either being named anywhere else.
#
# Why an image at all? The engine loads its mappings from a directory
# (openfhir.bootstrap.dir). Compose bind-mounts ./openfhir/bootstrap straight off the
# host, but Kubernetes has no host directory to mount — so the files have to be
# delivered some other way. Each OPT is ~1 MB of XML and the payload is several MB,
# far over the ~1 MiB ConfigMap limit either way, so shipping it as an OCI artifact
# and copying it in via an initContainer is the standard approach. (Once clusters are
# on k8s 1.33+, `volumes[].image` can mount this directly and the initContainer goes
# away.)
#
# Build + push (see the Makefile targets `images` / `images-push`):
#   docker build -f docker/openfhir/bootstrap.Dockerfile \
#     -t ghcr.io/freshehrteam/fhirconnect-eps-mappings:<tag> docker/openfhir
FROM busybox:1.36
COPY bootstrap/ /bootstrap/
