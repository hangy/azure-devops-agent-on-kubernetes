#!/bin/bash

if [ -x "$(command -v sudo)" ]; then
  {
        sudo chown -R ubuntu /azp
    # Docker socket permissions and group membership are now expected to be managed externally.
    # If you need Docker CLI support, mount the socket with correct permissions from the host.
  } || true
fi

set -e

# -----------------------------------------------------------------------------
# Optional Docker socket group mapping
# We no longer try to change permissions during image build (that never worked
# for a runtime-mounted host socket). Instead, if /var/run/docker.sock is
# mounted, we dynamically create (or reuse) a group with the same GID and add
# the agent user to it. This avoids chmod 666 on the socket and keeps least
# privilege.
#
# If the group membership changes, the current process won't automatically see
# it; we re-exec the script via 'sg' once (guarded by an env flag) to pick up
# the new supplementary group. This is safe because we do it early before the
# agent config starts.
# -----------------------------------------------------------------------------
if [ -z "$DOCKER_GROUP_REFRESHED" ] && [ -S /var/run/docker.sock ]; then
  USER_NAME="ubuntu"
  DOCKER_GID="$(stat -c %g /var/run/docker.sock 2>/dev/null)"
  if [ -S /var/run/docker.sock ] && [ -z "$DOCKER_GID" ]; then
    echo 1>&2 "warning: failed to get GID for /var/run/docker.sock (stat failed or insufficient permissions)"
  fi
  if [ -n "$DOCKER_GID" ]; then
    EXISTING_GROUP="$(getent group "$DOCKER_GID" | cut -d: -f1 || true)"
    TARGET_GROUP="${EXISTING_GROUP:-docker}"
    if [ -x "$(command -v sudo)" ]; then
      if [ -z "$EXISTING_GROUP" ]; then
        sudo groupadd -g "$DOCKER_GID" "$TARGET_GROUP" 2>/dev/null || true
      fi
      if ! id -nG "$USER_NAME" | grep -qw "$TARGET_GROUP"; then
        sudo usermod -aG "$TARGET_GROUP" "$USER_NAME" 2>/dev/null || true
        # Re-exec to apply new group membership to current shell/session.
        if [ "$(id -un)" = "$USER_NAME" ]; then
          export DOCKER_GROUP_REFRESHED=1
          exec sg "$TARGET_GROUP" "$0" "$@"
        fi
      fi
    fi
  fi
fi

if [ -z "$AZP_URL" ]; then
  echo 1>&2 "error: missing AZP_URL environment variable"
  exit 1
fi

if [ -z "$AZP_TOKEN_FILE" ]; then
  if [ -z "$AZP_TOKEN" ]; then
    echo 1>&2 "error: missing AZP_TOKEN environment variable"
    exit 1
  fi

  AZP_TOKEN_FILE=/azp/.token
  echo -n $AZP_TOKEN > "$AZP_TOKEN_FILE"
fi

unset AZP_TOKEN

if [ -n "$AZP_WORK" ]; then
  mkdir -p "$AZP_WORK"
fi

export AGENT_ALLOW_RUNASROOT="1"

cleanup() {
  if [ -e config.sh ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."

    # If the agent has some running jobs, the configuration removal process will fail.
    # So, give it some time to finish the job.
    while true; do
      ./config.sh remove --unattended --auth PAT --token $(cat "$AZP_TOKEN_FILE") && break

      echo "Retrying in 10 seconds..."
      sleep 10
    done
  fi
}

print_header() {
  lightcyan='\033[1;36m'
  nocolor='\033[0m'
  echo -e "${lightcyan}$1${nocolor}"
}

# Let the agent ignore the token env variables
export VSO_AGENT_IGNORE=AZP_TOKEN,AZP_TOKEN_FILE

source ./env.sh

print_header "Configuring Azure Pipelines agent..."

./config.sh --unattended \
  --agent "${AZP_AGENT_NAME:-$(hostname)}" \
  --url "$AZP_URL" \
  --auth PAT \
  --token $(cat "$AZP_TOKEN_FILE") \
  --pool "${AZP_POOL:-Default}" \
  --work "${AZP_WORK:-_work}" \
  --replace \
  --acceptTeeEula & wait $!

print_header "Running Azure Pipelines agent..."

trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

chmod +x ./run-docker.sh

# To be aware of TERM and INT signals call run.sh
# Running it with the --once flag at the end will shut down the agent after the build is executed
./run-docker.sh "$@" & wait $!