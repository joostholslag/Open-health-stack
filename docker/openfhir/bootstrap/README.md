# openFHIR bootstrap (FHIRConnect mappings + OPT)

These FHIRConnect mapping YAMLs and the `International Patient Summary.opt`
operational template are loaded by the openFHIR engine at startup (mounted at
`/app/bootstrap`, `recursively-open-directories: true`).

**Provenance:** copied verbatim from the Dublin hackathon reference repo
`converge-and-collaborate-dublin-hackaton/fhirconnect/`. They map the FHIR IPS
(International Patient Summary) profile onto the openEHR `health_summary`
composition (problem list, adverse reactions, medications).

- `ips.context.yml` — the context mapper that binds the IPS profile + template id
  to the openEHR archetypes and sets `start: COMPOSITION.health_summary.v1`.
- `ips.*.yml` — section/evaluation/extension mappers for the IPS sections.
- `core/org/openehr/**` — reusable core archetype mappers.
- `International Patient Summary.opt` — the operational template (XML,
  ~3 MB) uploaded to EHRbase and referenced by `interceptor.ips.template-id`.

To update the IPS mapping, re-copy from the reference repo or edit in place.
