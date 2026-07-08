# Run the system tests against Ditto on PostgreSQL persistence

Ditto's persistence layer is pluggable: MongoDB is the bundled default, PostgreSQL is a drop-in
extension. The compose override [`docker-compose-postgres.yml`](docker-compose-postgres.yml) starts
the regular system-test environment with **policies, things and connectivity persisting journals and
snapshots to PostgreSQL 16**. things-search's backend is **selectable** via `SEARCH_BACKEND`
(default `postgres`): with `SEARCH_BACKEND=postgres` the
[`docker-compose-postgres-search.yml`](docker-compose-postgres-search.yml) overlay also runs
**things-search on PostgreSQL**; with `SEARCH_BACKEND=mongodb` things-search keeps its index in MongoDB
(the proven persistence-on-PG / search-on-Mongo split). Either way the `mongodb` container stays defined
— do not remove it or the `MONGO_DB_*` variables from `docker-compose.env`; it is required for
`SEARCH_BACKEND=mongodb` and harmless otherwise.

The Postgres backend is activated per service by

* **two extension JARs** mounted into `/opt/ditto/extensions/` (on the images' default classpath) — the
  shaded base `ditto-postgres-client-extension-0-SNAPSHOT.jar` (postgres-client infra + all third-party
  deps) plus a thin JAR per role: `ditto-postgres-persistence-extension-0-SNAPSHOT.jar` for
  policies/things/connectivity, `ditto-postgres-search-extension-0-SNAPSHOT.jar` for things-search. All
  three are `0-SNAPSHOT` and **must come from the same build** — a boot self-check fails fast on mismatch
  or on a thin JAR mounted without its base,
* an overlay config from [`postgres/`](postgres/) mounted into `/opt/ditto/` and selected via
  `HOSTING_ENVIRONMENT=filebased` + `HOSTING_ENVIRONMENT_FILE_LOCATION`,
* `POSTGRES_*` connection environment variables (`POSTGRES_SSL_MODE=disable` is mandatory locally).

> **pg_trgm:** things-search-on-PostgreSQL needs the DDL role to
> `CREATE EXTENSION IF NOT EXISTS pg_trgm` at boot. The local `ditto` superuser in `postgres:16`
> satisfies this automatically; against a restricted/managed Postgres, pre-create the extension or grant
> the DDL role the privilege.

## Prerequisites

1. A sibling **ditto worktree on the Postgres persistence + search branch** — it must contain
   `internal/utils/postgres-persistence-extension` (the three-JAR-layout marker; old single-extension
   and Mongo-era checkouts both fail the preflight). The scripts default to `./../../ditto` (relative
   to `docker/`); point `DITTO_REPO_DIR` at the search-branch worktree if it lives elsewhere.
   `start-postgres.sh` aborts early if the directory does not look like this worktree.
2. That worktree built once (`mvn install -DskipTests`) so the `*-allinone.jar` files exist —
   `ditto/build-images.sh` only wraps them into images.
3. Docker + docker-compose, Maven, JDK — same toolchain as for `start.sh`.

## One-command run

```bash
cd docker
./start-postgres.sh                       # full-Postgres stack (SEARCH_BACKEND=postgres, the default)
# or:
SEARCH_BACKEND=mongodb ./start-postgres.sh # persistence on PG, things-search on Mongo
# or point at a specific worktree:
DITTO_REPO_DIR=/path/to/ditto-search-worktree ./start-postgres.sh
```

The script builds the Ditto service images (`eclipse/ditto-<svc>:0-SNAPSHOT`) and the **three** Postgres
extension JARs (the shaded client base + the two thin extensions, one reactor build) from
`DITTO_REPO_DIR` (skip both with `SKIP_IMAGE_BUILD=1`), then brings everything up in dependency order,
waiting for the Postgres healthcheck before starting the Ditto services. With `SEARCH_BACKEND=postgres`
it additionally layers `docker-compose-postgres-search.yml` so things-search runs on PostgreSQL.

Because the local `docker-compose.override.yml` stays in the stack, the gateway is published on
`localhost:8080` as usual; Postgres is additionally published on `localhost:5432` for debugging:

```bash
PGPASSWORD=ditto psql -h localhost -U ditto -d ditto -c '\dt'    # expect *_journal/*_snaps tables
```

With `SEARCH_BACKEND=postgres` the same database also holds the things-search schema tables — their
presence (plus the things-search log) is what actually proves the search overlay booted on PostgreSQL.

The Postgres container has **no persistent volume** on purpose: a fresh container means a fresh
database, which the cleanup tests (`CleanupIT`) rely on.

## Teardown

```bash
cd docker
./stop-postgres.sh
```

(Uses the same compose file stack — a plain `docker-compose down` would not know the `postgres`
service.)

## Running the tests (in-network, CI-style)

The `docker-compose-postgres` test environment — like its parent `docker-compose` — addresses all
services by their **container hostnames** (`gateway`, `mongodb`, `postgres`, `oauth`, ...). Running
the suite from the bare host does **not** work; run Maven in a container attached to the compose
network (named `test` by default, or `$DOCKER_NETWORK`) under the alias `system-test-container`,
mirroring `jenkins/Jenkinsfile_system`. From the repository root:

```bash
docker run --rm --network test --network-alias system-test-container \
  -v "$PWD":/ws -v "$HOME/.m2":/root/.m2 -w /ws maven:3.9-eclipse-temurin-25 \
  mvn verify -am --projects=:system -Dtest.environment=docker-compose-postgres
```

(Adjust the Maven image tag to the Java toolchain in use — the repo currently compiles with
Java 25.)

To run a focused pair (note `-Dit.test`, failsafe — `-Dtest` would select nothing) — `CleanupIT`
exercises the DB-direct `docker-compose` arm, `QueryThingsIT` exercises search CRUD/RQL over the PG
backend; both in one invocation to avoid two ~64-module `-am` builds:

```bash
docker run --rm --network test --network-alias system-test-container \
  -v "$PWD":/ws -v "$HOME/.m2":/root/.m2 -w /ws maven:3.9-eclipse-temurin-25 \
  mvn verify -am --projects=:system -Dit.test=CleanupIT,QueryThingsIT -Dtest.environment=docker-compose-postgres
```

`mvn verify` here does **not** fail the build on IT failures (`system/pom.xml` binds only failsafe's
`integration-test` goal), so read the result from the report, not the exit code:
`grep -h "Tests run" system/target/failsafe-reports/*.txt` and require
`Tests run: N, Failures: 0, Errors: 0, Skipped: 0`. **`Skipped: 0` is load-bearing** — a
`@RunIf(DockerEnvironment)` miss surfaces as a silent skip.

## IntelliJ mode (docker optional)

To run the Ditto services from IntelliJ (as the Mongo-based `intelliJRunConfigurations/*.run.xml` flow
does) with only infrastructure in docker, and point the system tests at them:

1. **Infrastructure only** in docker: `postgres` (via the `Postgres for test` run config, or
   `docker-compose -f docker-compose.yml -f docker-compose-postgres.yml up -d postgres` — the `postgres`
   service is defined **only** in `docker-compose-postgres.yml`), plus `oauth` and the brokers as in the
   main README's IntelliJ section. Start `mongodb` only if you run ThingsSearch on Mongo. Postgres is
   published on `localhost:5432`; do **not** also run ditto's own `deployment/postgres-local` stack (it
   binds the same port).
2. **Ditto from IntelliJ**: launch the `(Postgres)` run configs (`Policies`, `Things`, `ThingsSearch`,
   `Connectivity` — all `for test (Postgres)` — plus the unchanged `Gateway for test`), or the
   `Ditto for test (Postgres)` compound (needs the **Multirun** plugin). They are imported into the ditto
   project and put the r2dbc modules on the classpath via the `ditto-ide-postgres-launcher` module.
   Search backend = which ThingsSearch config you launch (Mongo `ThingsSearch for test` vs
   `ThingsSearch for test (Postgres)`).
3. **Run the tests from the host** against `-Dtest.environment=local-postgres` (a real host-run `mvn`
   works here — unlike the in-network docker mode, everything is on `localhost`):
   ```bash
   mvn verify -am --projects=:system -Dit.test=CleanupIT,QueryThingsIT -Dtest.environment=local-postgres
   ```
   Assert per the report block above (`Skipped: 0`).

The default MongoDB path is untouched: `./start.sh` + `-Dtest.environment=docker-compose` behave
exactly as before.
