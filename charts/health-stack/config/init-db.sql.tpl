-- Runs inside the single shared Postgres (image ehrbase/ehrbase-v2-postgres),
-- mounted at /docker-entrypoint-initdb.d/02-tenants.sql so it executes AFTER the
-- image's own ehrbase bootstrap (01-*).
--
-- Purpose: carve out the HAPI and openFHIR databases alongside EHRbase's, so all
-- three services share ONE Postgres instance. Each gets its own database + owner
-- role, so their schemas never collide (both HAPI's JPA tables and openFHIR's
-- Flyway migrations target `public` inside their own database).
--
-- The instance must stay on the ehrbase vendor image: EHRbase needs the
-- extensions and role layout that image pre-provisions; HAPI and openFHIR are
-- schema-agnostic and just need an empty database to build into.
--
-- Passwords are injected by the chart from Secret values (see configmaps.yaml).
-- NOTE: this is a non-production topology — see the "Database topology" section
-- in README.md for why, and what production should do instead.

-- ── HAPI FHIR (JPA store) ───────────────────────────────────────────────────
CREATE DATABASE hapi;
CREATE USER hapi WITH ENCRYPTED PASSWORD '__HAPI_DB_PASS__';
GRANT ALL PRIVILEGES ON DATABASE hapi TO hapi;
ALTER DATABASE hapi OWNER TO hapi;
ALTER ROLE hapi SET search_path TO public;

-- ── openFHIR engine (FHIRConnect mappings, contexts, insights) ──────────────
CREATE USER openfhir WITH ENCRYPTED PASSWORD '__OPENFHIR_DB_PASS__';
CREATE DATABASE openfhir OWNER openfhir;
GRANT ALL PRIVILEGES ON DATABASE openfhir TO openfhir;
ALTER ROLE openfhir SET search_path TO public;

-- ── Keycloak (realm + session store) ────────────────────────────────────────
-- MUST stay the LAST database this script creates (mirrors docker/ehrbase/
-- init-db.sql, whose postgres healthcheck greps for it there).
-- ⚠ Init scripts only run on FIRST boot of an empty PVC. On a cluster that was
-- deployed BEFORE this block existed, create the role/DB manually instead:
--   kubectl -n health-stack exec postgres-0 -- psql -U postgres -c "CREATE USER keycloak ..."
CREATE USER keycloak WITH ENCRYPTED PASSWORD '__KEYCLOAK_DB_PASS__';
CREATE DATABASE keycloak OWNER keycloak;
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
ALTER ROLE keycloak SET search_path TO public;
