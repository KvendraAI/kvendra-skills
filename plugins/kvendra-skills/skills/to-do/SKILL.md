---
name: to-do
description: Gestor de tareas v3 — crea y gestiona ISSUEs en Kvendra con nomenclatura, relaciones y trazabilidad
user_invocable: true
args: "[acción: create|update|close|list] [argumentos]"
---

# To-Do v3 — Gestión de ISSUEs en Kvendra

Gestionas work items (ISSUE) en el Kvendra: bugs, tasks e incidents con
nomenclatura estandarizada, relaciones y trazabilidad a REQ/REL.

## Acción

$ARGUMENTS

## Paso 0 — Inicialización Kvendra

Identifica `project_id` y `component_id` desde el `CLAUDE.md`.

## Reglas Kvendra (resumen)

- Identifícate en cada write: `updated_by: "skill:<este-skill>"`. El header
  `X-Kvendra-Skill` lo añade el cliente MCP automáticamente.
- Orquestador → `txn_create` antes de crear entities, ciérrala con
  `txn_activate` (éxito) o `mcp__plugin_kvendra-skills_kvendra-cloud__txn_cancel(reason)` (fallo).
  Subagente → recibe `txn_id` por args y NO abre/cierra TXN.
- Antes de abrir TXN: `mcp__plugin_kvendra-skills_kvendra-cloud__txn_check_interrupted(project_id, component_id?)`.
  Si hay TXN in-progress: Retomar / Cancelar / Ignorar.
- IDs los emite el server. Excepción: `PRJ`/`CMP`/`REL` requieren `force_id`.
- Si un error trae `error.help.topic`, llama `mcp__plugin_kvendra-skills_kvendra-cloud__help({topic})`. Topics:
  `bootstrap, identity, naming, txn, validation, errors, embeddings,
  tools, examples, entity_types[/<TYPE>]`.


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

## Acciones

### CREATE — Crear ISSUE

1. Determinar `type`: `bug | task | incident`.
2. Determinar componente (o cross-componente).
3. **No generes el ID manualmente** — el server lo emite.
4. Construir `content` con campos según tipo (referencia: schema en
   `docs/kb-v3/02-schema-reference.md`).
5. Determinar relaciones: `implements → REQ`, `fixes → ISSUE`, `blocks → REL`.
6. Llamar:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "ISSUE",
  project_id: "<PROY>",
  component_id: "<PROY>-<COMP>",   // opcional
  title: "<título>",
  content: <markdown>,
  metadata: { severity, priority },
  tags: ["type:<tipo>", "priority:<prio>"],
  relations: [
    { type:"implements", target:"REQ-<PROY>-<NN>" },
    { type:"blocks",     target:"REL-<PROY>-<VER>" }
  ],
  updated_by: "skill:to-do"
})
```

### UPDATE — Actualizar ISSUE

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_update({
  entity_id: "ISSUE-<PROY>-<COMP>-<NN>",
  content: <opcional>,
  tags_add: ["status:in-progress"],     // si cambia estado
  tags_remove: ["status:new"],
  change_summary: "Asignado a @user, estado in-progress",
  updated_by: "skill:to-do"
})
```

Si tiene REL activa, el server pobla `entity_changelog` automáticamente.

### CLOSE — Cerrar ISSUE

1. Leer ISSUE: `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id })`.
2. Cambiar status según tipo:
   - bug: `closed`
   - task: `done`
   - incident: `postmortem-done`
3. Si es bug: verificar que existe TEST regression-case que lo cubre
   (`mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"TEST", tags_all:["type:regression-case", "ISSUE-..."] })`).
4. `entity_update` con tags actualizados y `change_summary`.

### LIST — Listar ISSUEs

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({
  entity_type: "ISSUE",
  project_id: "<PROY>",
  component_id: "<si filtra>",
  tags_all: ["type:<tipo>"],     // opcional
  status: "<status>",            // opcional
  order_by: "updated_at_desc"
})
```

## Output

### Para CREATE:
```
ISSUE creada: ISSUE-<PROY>-<COMP>-<NNN> (auto-generado)
- Tipo: bug | task | incident
- Prioridad: critical | high | medium | low
- Componente: <COMP>
- Relaciones: implements REQ-..., blocks REL-...
```

### Para LIST:
```
| ID | Tipo | Prioridad | Estado | Componente | Título |
|----|------|-----------|--------|-----------|--------|
| ISSUE-WO-IVR-001 | bug | high | new | IVR | Timeout en callback |
| ISSUE-WO-042 | task | medium | in-progress | (cross) | Actualizar docs |
```
