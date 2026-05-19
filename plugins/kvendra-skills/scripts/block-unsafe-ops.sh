#!/usr/bin/env bash
#
# block-unsafe-ops.sh — Plugin kvendra-skills, hook PreToolUse
#
# Bloquea operaciones Bash que tocan credenciales o sistemas externos
# (git writes, gh writes, aws deploys, npm/pypi/cargo publish) DENTRO de
# workspaces Kvendra (marker: .kvendra-workspace). Fuerza el uso de las
# primitives del broker MCP `kvendra` que llevan audit + allowlist + identidad
# workspace-bound.
#
# Fuera de un workspace Kvendra el hook es no-op — Bash queda libre.
#
# Protocolo:
# - Recibe JSON del hook por stdin (tool_name, tool_input.command, cwd).
# - exit 0 → allow. exit 2 → block (stderr visible al usuario).
#
# Lecturas read-only (status/log/diff/issue view/get-caller-identity) NO se bloquean.

set -euo pipefail

INPUT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  # Sin jq no podemos parsear el JSON con seguridad. No bloquear (fail-open)
  # para no romper sesiones; avisar al stderr por si el owner lo nota.
  echo "[kvendra-skills hook] jq no disponible — hook deshabilitado (fail-open)." >&2
  exit 0
fi

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
[[ -z "$CWD" ]] && CWD="$PWD"

# Buscar marker .kvendra-workspace subiendo desde CWD
DIR="$CWD"
MARKER_DIR=""
while :; do
  if [[ -f "$DIR/.kvendra-workspace" ]]; then
    MARKER_DIR="$DIR"
    break
  fi
  PARENT="$(dirname "$DIR")"
  [[ "$PARENT" == "$DIR" ]] && break  # raíz alcanzada
  DIR="$PARENT"
done

# Sin marker → fuera de workspace Kvendra → allow
[[ -z "$MARKER_DIR" ]] && exit 0

# Dentro de workspace Kvendra: aplicar blocklist sobre $COMMAND
#
# Reglas (extended regex):
#   git: writes/destructive (commit/push/tag/merge/reset --hard/checkout -- file/branch -D/rebase/cherry-pick/stash drop/filter-branch/am)
#   gh:  writes (release create/delete/edit, pr create/close/merge/edit/comment, issue create/close/edit/comment, api con --method que no sea GET)
#   aws: deploys (s3 sync/cp/rm/mv/mb/rb, s3api put*/delete*/create*, cloudfront create/update/delete, lambda invoke/update/delete/create, cloudformation deploy/create/update/delete)
#   sam deploy
#   npm: publish/deprecate/unpublish/owner
#   cargo: publish/yank/owner
#   pip/twine: upload/publish

BLOCK_RE='(^|[[:space:];&|]|/)((git[[:space:]]+(commit|push|tag|merge|reset[[:space:]]+--hard|checkout[[:space:]]+--|branch[[:space:]]+-D|rebase|cherry-pick|am|filter-branch)([[:space:]]|$))|(git[[:space:]]+stash[[:space:]]+drop([[:space:]]|$))|(gh[[:space:]]+(release[[:space:]]+(create|delete|edit)|pr[[:space:]]+(create|close|merge|edit|comment)|issue[[:space:]]+(create|close|edit|comment))([[:space:]]|$))|(aws[[:space:]]+(s3[[:space:]]+(sync|cp|rm|mv|mb|rb)|s3api[[:space:]]+(put|delete|create)[[:alnum:]_-]*|cloudfront[[:space:]]+(create|update|delete)[[:alnum:]_-]*|lambda[[:space:]]+(invoke|update|delete|create)([[:alnum:]_-]*)?|cloudformation[[:space:]]+(deploy|create|update|delete)[[:alnum:]_-]*)([[:space:]]|$))|(sam[[:space:]]+deploy([[:space:]]|$))|(npm[[:space:]]+(publish|deprecate|unpublish|owner)([[:space:]]|$))|(cargo[[:space:]]+(publish|yank|owner)([[:space:]]|$))|((pip|twine)[[:space:]]+(upload|publish)([[:space:]]|$)))'

# Caso especial: gh api con --method != GET (writes via REST genérica)
if printf '%s' "$COMMAND" | grep -qE '\bgh[[:space:]]+api\b' && \
   printf '%s' "$COMMAND" | grep -qE '(\-\-method[[:space:]]+|-X[[:space:]]+)(POST|PUT|PATCH|DELETE)'; then
  MATCH="gh api con method write (POST/PUT/PATCH/DELETE)"
elif printf '%s' "$COMMAND" | grep -qE "$BLOCK_RE"; then
  MATCH="$(printf '%s' "$COMMAND" | grep -oE "$BLOCK_RE" | head -1 | tr -d '\n' | sed 's/^[[:space:];&|/]*//')"
else
  exit 0
fi

cat >&2 <<EOF
❌ Bash op BLOQUEADA por kvendra-skills hook
   Workspace Kvendra detectado: ${MARKER_DIR}
   Patrón disparador: ${MATCH}

Comando completo:
   ${COMMAND}

Las operaciones que tocan credenciales o sistemas externos deben usar las
primitives del broker MCP \`kvendra\` (audit + allowlist + identidad workspace-bound):

  git commit/push/tag           →  mcp tool kvendra.git (op: commit|push|tag|...)
  gh release/pr/api write       →  mcp tool kvendra.github
  aws s3/cloudfront/lambda/sam  →  mcp tool kvendra.aws
  npm publish                   →  mcp tool kvendra.npm
  pip/twine upload              →  mcp tool kvendra.pypi
  cargo publish / sh allowlisted →  mcp tool kvendra.shell

Lecturas read-only (git status/log/diff, gh issue view, aws sts get-caller-identity)
SÍ están permitidas via Bash — este hook solo bloquea writes/deploys.

Si el broker \`kvendra\` no está disponible: arrancar con \`kvendra unlock\` +
restart de Claude Code. NO eliminar .kvendra-workspace para saltarse el hook.
EOF

exit 2
