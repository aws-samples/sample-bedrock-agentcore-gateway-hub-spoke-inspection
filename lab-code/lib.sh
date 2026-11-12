#!/usr/bin/env bash
# Shared helpers for run-lab.sh, observability.sh, x3-jwks-egress.sh and x8-rate-limit.sh.
# Source this file after setting DIR to the lab-code directory.
#
# Environment contract (same for every script):
#   AWS_REGION   Region to use (default us-east-1; see README: templates use us-east-1 Availability Zone IDs)
#   HUB_PROFILE  AWS CLI profile for the network account      (default lab-hub)
#   S1_PROFILE   AWS CLI profile for the AgentCore account    (default lab-spoke1)
#   S2_PROFILE   AWS CLI profile for the tool/API account     (default lab-spoke2)
#   LAB_PY       Python with boto3 >= 1.43.106 for the Python scripts (default lab-code/.venv/bin/python, created on demand)

REGION=${AWS_REGION:-us-east-1}
HUB=${HUB_PROFILE:-lab-hub}
S1=${S1_PROFILE:-lab-spoke1}
S2=${S2_PROFILE:-lab-spoke2}
LAB_STATE="$DIR/.lab-state.env"

# Everything that holds a secret (tokens, client secrets, API keys) goes into a private temp dir, removed on exit.
umask 077
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/agentcore-lab.XXXXXX")
LAB_EXIT_HOOKS=()
_lab_exit() {
  local rc=$?
  local h
  for h in ${LAB_EXIT_HOOKS[@]+"${LAB_EXIT_HOOKS[@]}"}; do eval "$h" || true; done
  rm -rf "$TMPD"
  exit $rc
}
trap _lab_exit EXIT
trap 'exit 130' INT TERM

say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
acct() { aws sts get-caller-identity --profile "$1" --query Account --output text; }

# Load the state written by run-lab.sh (resource IDs only; no secrets are stored there).
lab_load_state() {
  [ -f "$LAB_STATE" ] || die "no $LAB_STATE; run ./run-lab.sh deploy first"
  # shellcheck disable=SC1090
  source "$LAB_STATE"
}

# Cognito client_credentials token for the Gateway inbound authorizer.
# The client secret is passed to curl on stdin (-K -), not on the command line.
lab_token() {
  local secret
  secret=$(aws cognito-idp describe-user-pool-client --profile "$S1" --region "$REGION" \
    --user-pool-id "$USER_POOL_ID" --client-id "$CLIENT_ID" --query UserPoolClient.ClientSecret --output text)
  printf 'user = "%s:%s"\n' "$CLIENT_ID" "$secret" | curl -sf -K - -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=client_credentials&scope=lab-gateway/invoke' "$TOKEN_URL" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])' \
    || die "could not get an inbound token from $TOKEN_URL"
}

# Print the path of a Python with boto3 >= 1.43.106, creating lab-code/.venv if needed.
lab_py() {
  local py=${LAB_PY:-$DIR/.venv/bin/python}
  if [ ! -x "$py" ]; then
    python3 -m venv "$DIR/.venv" >&2 && "$DIR/.venv/bin/pip" install -q 'boto3==1.43.108' >&2 || die "could not create $DIR/.venv"
    py="$DIR/.venv/bin/python"
  fi
  "$py" -c 'import boto3,sys; sys.exit(0 if tuple(int(x) for x in boto3.__version__.split(".")[:3]) >= (1,43,106) else 1)' >&2 \
    || die "$py needs boto3 >= 1.43.106 (certificateConfigurations). Set LAB_PY or delete $DIR/.venv"
  echo "$py"
}
