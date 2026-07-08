#!/usr/bin/env bash

# Copyright (c) 2026 Contributors to the Eclipse Foundation
#
# See the NOTICE file(s) distributed with this work for additional
# information regarding copyright ownership.
#
# This program and the accompanying materials are made available under the
# terms of the Eclipse Public License 2.0 which is available at
# http://www.eclipse.org/legal/epl-2.0
#
# SPDX-License-Identifier: EPL-2.0

# Sibling of start.sh: starts the system-test docker environment with Ditto persisting
# things/policies/connectivity journals + snapshots to PostgreSQL. things-search's backend is
# selectable via SEARCH_BACKEND (default: postgres). See README-postgres.md.
#
# Environment:
#   DITTO_REPO_DIR    ditto worktree providing the service images + the three Postgres extension JARs
#                     (default: ./../../ditto). MUST be the search-branch worktree (contains
#                     internal/utils/postgres-persistence-extension).
#   SEARCH_BACKEND    "postgres" (default) runs things-search on PostgreSQL (adds the
#                     docker-compose-postgres-search.yml overlay); "mongodb" keeps it on MongoDB.
#   SKIP_IMAGE_BUILD  set to 1 to skip rebuilding the service images and the extension JARs.

set -e

# Resolve everything (compose files, log files, the DITTO_REPO_DIR default) relative to docker/.
cd "$(dirname "$0")"

DITTO_REPO_DIR="${DITTO_REPO_DIR:-./../../ditto}"
export DITTO_REPO_DIR

# Use the locally built images (ditto/build-images.sh tags eclipse/ditto-<svc>:0-SNAPSHOT).
export DITTO_VERSION="${DITTO_VERSION:-0-SNAPSHOT}"
export DOCKER_REGISTRY_NAMESPACE="${DOCKER_REGISTRY_NAMESPACE:-eclipse}"

# Three-JAR layout (all 0-SNAPSHOT, all must come from the same build): the shaded client base plus
# two thin extensions. postgres-persistence-extension is the new-layout marker used by the preflight.
CLIENT_EXTENSION_MODULE_DIR="$DITTO_REPO_DIR/internal/utils/postgres-client-extension"
PERSISTENCE_EXTENSION_MODULE_DIR="$DITTO_REPO_DIR/internal/utils/postgres-persistence-extension"
SEARCH_EXTENSION_MODULE_DIR="$DITTO_REPO_DIR/internal/utils/postgres-search-extension"
CLIENT_EXTENSION_JAR="$CLIENT_EXTENSION_MODULE_DIR/target/ditto-postgres-client-extension-0-SNAPSHOT.jar"
PERSISTENCE_EXTENSION_JAR="$PERSISTENCE_EXTENSION_MODULE_DIR/target/ditto-postgres-persistence-extension-0-SNAPSHOT.jar"
SEARCH_EXTENSION_JAR="$SEARCH_EXTENSION_MODULE_DIR/target/ditto-postgres-search-extension-0-SNAPSHOT.jar"

# Fail fast on a wrong ditto worktree: multiple ditto checkouts/worktrees exist side-by-side. Both a
# Mongo-era checkout and an OLD single-JAR (pre-search-branch) worktree lack this marker directory and
# would otherwise silently build the wrong (or no) images.
if [ ! -d "$PERSISTENCE_EXTENSION_MODULE_DIR" ]; then
  printf "ERROR: <%s> does not exist.\n" "$PERSISTENCE_EXTENSION_MODULE_DIR" >&2
  printf "DITTO_REPO_DIR=<%s> does not point at a ditto worktree with the three-JAR Postgres layout\n" "$DITTO_REPO_DIR" >&2
  printf "(internal/utils/postgres-persistence-extension). Point DITTO_REPO_DIR at the search-branch worktree.\n" >&2
  exit 1
fi

# Explicit -f flags disable compose's auto-loading of docker-compose.override.yml (the file that
# publishes gateway 8080 / mongodb 27017 to the host and fixes Kafka's advertised listeners; CI
# deletes it on purpose), so build the stack explicitly and keep the override when present.
COMPOSE_FILES="-f docker-compose.yml"
if [ -f docker-compose.override.yml ]; then
  COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.override.yml"
fi
COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-postgres.yml"

# things-search backend selection: postgres (default) adds the search overlay so things-search runs on
# PostgreSQL; mongodb omits it so things-search keeps indexing in MongoDB.
SEARCH_BACKEND="${SEARCH_BACKEND:-postgres}"
case "$SEARCH_BACKEND" in
  postgres)
    COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-postgres-search.yml"
    ;;
  mongodb)
    ;;
  *)
    printf "ERROR: SEARCH_BACKEND=<%s> is invalid; expected 'postgres' or 'mongodb'.\n" "$SEARCH_BACKEND" >&2
    exit 1
    ;;
esac
printf "Using SEARCH_BACKEND=%s for things-search.\n" "$SEARCH_BACKEND"

function compose {
  # shellcheck disable=SC2086
  docker-compose $COMPOSE_FILES "$@"
}

function assert_success {
  local status=$?
  if [ $status -ne 0 ] ; then
    echo "Unsuccessful exit code <$status>. Downing docker-compose."
    compose down
    exit $status
  fi
}

function cleanup() {
  printf "Cleanup ...\n\n"
  compose down
}
trap cleanup SIGHUP SIGINT SIGQUIT SIGABRT SIGALRM SIGTERM

{
  (cleanup)
  assert_success $?

  if [ "${SKIP_IMAGE_BUILD:-0}" != "1" ]; then
    # build-images.sh only wraps already-built allinone JARs into images — require a built worktree.
    if [ ! -f "$DITTO_REPO_DIR/policies/service/target/ditto-policies-service-0-SNAPSHOT-allinone.jar" ]; then
      printf "ERROR: no allinone JARs found in <%s>.\n" "$DITTO_REPO_DIR" >&2
      printf "Build the ditto worktree first: (cd %s && mvn install -DskipTests)\n" "$DITTO_REPO_DIR" >&2
      exit 1
    fi

    printf "\nBuilding Ditto service images from <%s> ...\n\n" "$DITTO_REPO_DIR"
    (cd "$DITTO_REPO_DIR" && ./build-images.sh)
    assert_success $?

    # Build all three Postgres extension JARs in ONE reactor invocation (the shaded client base + the
    # two thin extensions). The search extension is built even under SEARCH_BACKEND=mongodb — it is
    # cheap and keeps this script branch-free until compose-file assembly. -am pulls a ~64-module
    # reactor and the client shade makes a real `package` take minutes, so this runs only when
    # SKIP_IMAGE_BUILD is unset.
    printf "\nBuilding the three Postgres extension JARs ...\n\n"
    (cd "$DITTO_REPO_DIR" && mvn -pl :ditto-postgres-client-extension,:ditto-postgres-persistence-extension,:ditto-postgres-search-extension -am -DskipTests package)
    assert_success $?
  fi

  # Each is the main shaded JAR (ditto-postgres-<x>-extension-0-SNAPSHOT.jar), NOT the original-* sibling.
  for EXTENSION_JAR in "$CLIENT_EXTENSION_JAR" "$PERSISTENCE_EXTENSION_JAR" "$SEARCH_EXTENSION_JAR"; do
    if [ ! -f "$EXTENSION_JAR" ]; then
      printf "ERROR: extension JAR <%s> not found. Build it (unset SKIP_IMAGE_BUILD) and retry.\n" "$EXTENSION_JAR" >&2
      exit 1
    fi
  done

  printf "\nPulling newest versions of third-party images ...\n\n"
  (compose pull postgres mongodb oauth ssh mqtt kafka rabbitmq artemis fluentbit)
  assert_success $?

  printf "\n"
  read -r -p "Waiting for 10 seconds ..." -t 10
  printf "\n"

  printf "\nStarting OAuth Mock ...\n\n"
  (compose up -d oauth)
  assert_success $?

  printf "\nStarting PostgreSQL and MongoDB ...\n\n"
  (compose up -d postgres mongodb)
  assert_success $?

  printf "\nStarting OpenSSH ...\n\n"
  (compose up -d ssh)
  assert_success $?

  printf "\nStarting Message Brokers ...\n\n"
  (compose up -d mqtt kafka rabbitmq artemis)
  assert_success $?

  printf "\nWaiting for 10 seconds ...\n\n"
  sleep 10

  printf "\nStarting Fluent Bit ...\n\n"
  (compose up -d fluentbit)
  assert_success $?

  printf "\nWaiting for PostgreSQL to become healthy ...\n\n"
  POSTGRES_HEALTHY=""
  for _ in $(seq 1 30); do
    POSTGRES_HEALTH="$(docker inspect -f '{{.State.Health.Status}}' "$(compose ps -q postgres)" 2>/dev/null || true)"
    if [ "$POSTGRES_HEALTH" = "healthy" ]; then
      POSTGRES_HEALTHY="true"
      break
    fi
    sleep 2
  done
  if [ "$POSTGRES_HEALTHY" != "true" ]; then
    echo "PostgreSQL did not become healthy in time. Downing docker-compose." >&2
    compose down
    exit 1
  fi

  printf "\nStarting Ditto (Postgres persistence) ...\n\n"
  (compose up -d policies &&
  compose up -d things &&
  compose up -d things-search &&
  compose up -d connectivity &&
  compose up -d gateway)
  assert_success $?

  TAG="${TAG:-$(date -Iseconds)}"
  printf "\nAppend container logs to files...\n\n"
  compose logs -f oauth &> "oauth-$TAG.log" &
  compose logs -f postgres &> "postgres-$TAG.log" &
  compose logs -f mongodb &> "mongodb-$TAG.log" &
  compose logs -f ssh &> "ssh-$TAG.log" &
  compose logs -f mqtt &> "mqtt-$TAG.log" &
  compose logs -f kafka &> "kafka-$TAG.log" &
  compose logs -f rabbitmq &> "rabbitmq-$TAG.log" &
  compose logs -f artemis &> "artemis-$TAG.log" &
  compose logs -f fluentbit &> "fluentbit-$TAG.log" &
  compose logs -f policies &> "policies-$TAG.log" &
  compose logs -f things &> "things-$TAG.log" &
  compose logs -f things-search &> "things-search-$TAG.log" &
  compose logs -f connectivity &> "connectivity-$TAG.log" &
  compose logs -f gateway &> "gateway-$TAG.log" &

  printf "\n"
  read -r -p "Waiting for 20 seconds ..." -t 20
  printf "\n"

  EXPECTED_CONTAINERS="postgres mongodb mqtt kafka rabbitmq artemis policies things \
  things-search connectivity gateway"
  for CONTAINER in $EXPECTED_CONTAINERS
  do
    # check all expected containers exist, or break build.
    printf "Checking %s ...\n" $CONTAINER
    compose exec -T $CONTAINER echo -n || exit 1
  done

  # check if fluentbit is running, or break build.
  # fluentbit container can not run any commands inside the container
  compose ps fluentbit
  assert_success $?

  printf "Done."

  exit 0
} || {
  export RETURN_VALUE=$? && echo "Cleanup after error $RETURN_VALUE" && compose down && exit $RETURN_VALUE
}
