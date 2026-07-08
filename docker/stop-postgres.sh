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

# Tears down the environment started by start-postgres.sh.

set -e

# Resolve the compose files and the DITTO_REPO_DIR default relative to docker/.
cd "$(dirname "$0")"

# Must use the SAME compose file stack as start-postgres.sh — a bare `docker-compose down`
# would not know the `postgres` service and would leave its container (and the extra mounts) running.
export DITTO_REPO_DIR="${DITTO_REPO_DIR:-./../../ditto}"
export DITTO_VERSION="${DITTO_VERSION:-0-SNAPSHOT}"
export DOCKER_REGISTRY_NAMESPACE="${DOCKER_REGISTRY_NAMESPACE:-eclipse}"

COMPOSE_FILES="-f docker-compose.yml"
if [ -f docker-compose.override.yml ]; then
  COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.override.yml"
fi
COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-postgres.yml"
# Always include the search overlay regardless of the SEARCH_BACKEND used at start time: downing a
# service that was never started is a no-op, so one stop script tears down either variant.
COMPOSE_FILES="$COMPOSE_FILES -f docker-compose-postgres-search.yml"

# can be used for debugging purpose
# docker-compose $COMPOSE_FILES logs --no-color &> docker.log

# shellcheck disable=SC2086
docker-compose $COMPOSE_FILES down --volumes --remove-orphans
