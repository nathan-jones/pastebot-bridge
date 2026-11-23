# Sourced by the build scripts: sets TEAM_ID from $DEVELOPMENT_TEAM or Config/Local.xcconfig.
TEAM_ID=${DEVELOPMENT_TEAM:-$(awk -F'=' '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2}' Config/Local.xcconfig 2>/dev/null | tail -1)}
if [[ -z "$TEAM_ID" ]]; then
  echo "No team ID: set DEVELOPMENT_TEAM or create Config/Local.xcconfig (see Config/Local.xcconfig.example)." >&2
  exit 1
fi
