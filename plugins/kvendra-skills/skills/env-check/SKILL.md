---
name: env-check
description: Verifica que el entorno está correctamente configurado — MCPs (kvendra-cloud KB + kvendra broker), tools, skills v3, CLAUDE.md, marker workspace, hook PreToolUse
user_invocable: true
---

# Env Check — Verificar y reparar entorno (Kvendra)

## Reglas de ejecución externa (OBLIGATORIO)

Cualquier operación que use credenciales o salga de la máquina (git, github,
aws, npm, pypi, http con auth, comandos shell) DEBE invocarse vía primitives
del broker `kvendra` (MCP local stdio). NO hacer Bash directo.

| Op deseada | Primitive |
|---|---|
| git clone/push/pull/commit/tag | `kvendra.git` |
| GitHub REST/GraphQL | `kvendra.github` |
| AWS s3/cloudfront/lambda | `kvendra.aws` |
| npm publish/deprecate/read_metadata | `kvendra.npm` |
| PyPI upload/read_metadata | `kvendra.pypi` |
| HTTP con auth | `kvendra.http` |
| Shell con binario allowlisted (NO `sh -c`) | `kvendra.shell` |

Cada call requiere `profile_id` (credencial vault workspace-bound). No improvisar.

**PROHIBIDO via Bash**: `git commit/push/tag/merge/reset --hard/checkout --`,
`gh release/pr create/api`, `aws s3 (sync|cp)/cloudfront/lambda`, `npm publish`,
`cargo publish`, `pip upload`/`twine upload`. Lecturas read-only (`git status`,
`git log`, `gh issue view`, `aws sts get-caller-identity`) sí están permitidas
via Bash — el agente puede inspeccionar pero no escribir/desplegar.

Si el broker `kvendra` no está disponible (failed to connect): PARAR. Reportar
al usuario que arranque el broker. NO fallback a Bash.

Enforzado adicionalmente por hook PreToolUse del plugin (activo solo dentro de
workspaces con marker `.kvendra-workspace`).

---

Verificas que todo está configurado correctamente para usar los skills v3 + el
KB hosted Kvendra + el broker de capabilities. Si algo falta, diagnostica y
guía al usuario al fix concreto.

## Verificaciones (en orden)

### 1. MCP `kvendra-cloud` (KB hosted) conectado

```bash
claude mcp list 2>&1 | grep -E '^kvendra-cloud:|plugin.*kvendra-cloud'
```

Estados esperables:
- `✓ Connected` → OK.
- `! Needs authentication` → ejecutar `/mcp` desde Claude Code y completar el flujo OAuth.
- `✗ Failed to connect` → revisar https://api.kvendra.cloud accesible + token TTL.

### 2. Las 14 tools KB del `kvendra-cloud` disponibles

Buscar en la lista de tools registradas el prefijo
`mcp__plugin_kvendra-skills_kvendra-cloud__*`. Tools esperadas (14):

`entity_create, entity_update, entity_get, entity_query, entity_search,
entity_archive, entity_related, txn_create, txn_activate, txn_cancel,
txn_check_interrupted, whoami, config_get, help`

Si aparecen `authenticate` / `complete_authentication` en lugar de las 14: el
MCP no está autenticado. Resolver con `/mcp` desde Claude Code.

### 3. Test real del KB

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"PRJ", limit: 5 })
```

- Si funciona → mostrar count de proyectos visibles.
- Si falla → revisar el JWT (Cognito access_token, no id_token — ver `PAT-KVD-ENTERPRISE-015`).

### 4. MCP `kvendra` (broker local de capabilities) conectado

```bash
claude mcp list 2>&1 | grep -E '^kvendra:'
```

Estados:
- `✓ Connected` → OK, broker live.
- `✗ Failed to connect` → posibles causas:
  - **Master password no disponible**: la config MCP debe pasar `--use-keychain` (recomendado, macOS) o env var `KVENDRA_MCP_PASSWORD`. Stdio MCP no puede prompt interactivo.
  - **Bug `session token store error: decode`** en versiones 0.4.0-alpha.x: el fichero `~/.kvendra/sessions/<workspace>.token` está escrito como JWT pero leído como JSON. Workaround: mover `pro.token` a `.bak`, reintentar.
  - **Vault corrupto**: ejecutar `kvendra unlock` interactivo desde una terminal; si falla, recovery con BIP-39 mnemonic.

### 5. Las 7 primitives del broker disponibles

Tools esperadas (prefijo `mcp__kvendra__*`):

`kvendra.git, kvendra.github, kvendra.aws, kvendra.npm, kvendra.pypi,
kvendra.http, kvendra.shell` (+ `kvendra.unsafe.raw_token` flag UNSAFE).

NOTA sobre sanitización: Claude Code puede transformar el punto a guión bajo
en el nombre de la tool (e.g. `mcp__kvendra__kvendra_git`). Verificar con `/mcp`
qué nombres exactos están registrados localmente — el bloque de "Reglas de
ejecución externa" usa el nombre canónico con punto, el agente debe resolver
el prefijo MCP exacto contra la deferred tools list.

Si falta alguna primitive: el binario `kvendra` está desactualizado. Reinstalar
con `cargo install kvendra-cli` o actualizar via el flujo de releases del
proyecto.

### 6. `CLAUDE.md` con Project Identity y routing KB declarado

Leer el `CLAUDE.md` del directorio actual (si existe). Verificar:

```yaml
project_id: <valor>
kb_operacional:
  mcp: kvendra-cloud
```

- Sin `project_id`: skills v3 no funcionarán. Sugerir `/onboard-project`.
- Sin `kb_operacional.mcp: kvendra-cloud`: ambigüedad de routing. Sugerir
  añadir el bloque (ver el `CLAUDE.md` del repo Kvendra como referencia).

Si todo OK, validar que el PRJ existe en el KB:
```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"PRJ-<valor>" })
```

### 7. Marker `.kvendra-workspace` en CWD o ancestro

```bash
DIR="$PWD"; while [[ "$DIR" != "/" ]]; do
  [[ -f "$DIR/.kvendra-workspace" ]] && echo "FOUND: $DIR/.kvendra-workspace" && break
  DIR="$(dirname "$DIR")"
done
```

- **FOUND** → hook PreToolUse activo, bloqueará Bash con ops externas.
- **NOT FOUND** → hook no se activa en este directorio. Si esto es intencional
  (proyecto fuera de Kvendra), OK. Si no, crear el marker manualmente:
  `printf 'workspace: <nombre>\n' > .kvendra-workspace`.

### 8. Hook `PreToolUse` del plugin instalado

```bash
# Buscar el script del hook en las localizaciones de plugin instalado
find ~/.claude/plugins -name block-unsafe-ops.sh -path '*kvendra-skills*' 2>/dev/null
```

- **Encontrado y ejecutable** → hook activo.
- **No encontrado** → el plugin `kvendra-skills` no está instalado o está incompleto.
  Reinstalar con `/plugin install kvendra-skills` o equivalente.

### 9. Skills v3 disponibles

Listar skills del plugin. Mínimos:
`/consultancy, /to-do, /bug, /new-feature, /implementer, /updater, /validator,
/release-manager, /tester, /analyzer, /onboard-project`.

Si faltan: el plugin no está habilitado o no se ha refrescado tras instalar.
Pedir al usuario `/plugin list` y validar que `kvendra-skills` aparece como
enabled.

## Output requerido

```
## Estado del entorno

| # | Componente | Estado | Detalle |
|---|------------|--------|---------|
| 1 | MCP kvendra-cloud (KB) | OK / NEEDS_AUTH / FAIL | <estado> |
| 2 | 14 tools KB | OK / N/14 / N/A | <lista de faltantes> |
| 3 | KB accesible (read test) | OK / FAIL | <N proyectos / error> |
| 4 | MCP kvendra (broker) | OK / FAIL | <causa> |
| 5 | 7 primitives broker | OK / N/7 / N/A | <lista de faltantes> |
| 6 | CLAUDE.md + Project Identity | OK / PARTIAL / NONE | project_id: X |
| 7 | Marker .kvendra-workspace | FOUND / NOT_FOUND | <path o NOT_FOUND> |
| 8 | Hook PreToolUse | INSTALLED / MISSING | <path> |
| 9 | Skills v3 | OK / N skills | <lista o faltantes> |

### Problemas detectados
- [lista priorizada]

### Acciones recomendadas
- [<acción concreta>]
```

## Reglas

- **No modifiques nada sin preguntar** — solo diagnostica e informa.
- **Si todo OK**, di: "Entorno OK — listo para usar /consultancy, /bug, /new-feature, etc."
- **Sé específico** en los errores: cita el comando que falló y cómo arreglarlo.
- **Distingue las 3 conexiones**: KB hosted (writes operacionales) vs broker
  local (ops externas con audit) vs skills (los archivos en local).
