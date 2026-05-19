---
name: release-manager
description: Gestor de releases v3 — crea, gestiona y cierra REL con changelog automático, regression gates y trazabilidad Kvendra
user_invocable: true
args: "[acción: create|status|add|gate-check|close] [argumentos]"
---

# Release Manager v3 — Gestión de releases Kvendra

Gestionas el ciclo de vida de releases (REL): creación, adición de
ISSUEs/componentes, regression gates, changelog automático (poblado por el
server cuando hay REL activa), y cierre.

## Acción

$ARGUMENTS

## Paso 0 — Inicialización Kvendra

Identifica `project_id` desde el `CLAUDE.md`.

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

## Nota sobre IDs de REL — ADR-JRV-008 (regex SemVer)

REL usa **`force_id`** porque su entity_id no es secuencial sino SemVer.

Formato regex (ADR-JRV-008): `^REL-[A-Z]+(-[A-Z0-9]+)?-[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$`

Ejemplos válidos:
- `REL-WO-0.1.0` (project release minor)
- `REL-WO-IVR-0.1.0` (component hotfix)
- `REL-PRM-1.0.0`
- `REL-JRV-1.0.0.1` (4 segmentos para hotfix)

Antes de crear, valida el formato a mano. Si no cumple, el server rechazará
con `INTEGRITY` + constraint `entities_entity_id_format`.

## Acciones disponibles

### CREATE — Crear nueva release

1. Determinar versión (SemVer): leer última REL para calcular siguiente:
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"REL", project_id:<PROY>, order_by:"updated_at_desc", limit:5 })`
2. Tipo: major | minor | patch | hotfix.
3. Si hotfix de componente: `REL-<PROY>-<COMP>-<VER>`.
4. Si release de proyecto: `REL-<PROY>-<VER>`.
5. Validar el id contra regex de ADR-JRV-008. Si OK, crear:

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "REL",
  project_id: "<PROY>",
  component_id: "<si hotfix de componente>",
  force_id: "REL-<PROY>-<VER>",            // o REL-<PROY>-<COMP>-<VER>
  title: "REL-<PROY>-<VER>: <descripción>",
  content: <markdown con descripción, alcance, target_date, regression_gate:pendiente>,
  version: "<VER>",
  tags: ["status:planning", "type:<minor|major|patch|hotfix>"],
  updated_by: "skill:release-manager"
})
```

### STATUS — Ver estado de una release

1. `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"REL-<PROY>-<VER>" })`.
2. Listar ISSUEs incluidos: `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"ISSUE", project_id:<PROY>, tags_all:["REL-<PROY>-<VER>"] })`.
3. Verificar regression gates: para cada componente con ISSUE en la REL,
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"REG", project_id:<PROY>, component_id:"<PROY>-<COMP>" })`.
4. Mostrar changelog (viene en `entity_get` automáticamente — el server pobla
   `entity_changelog` cuando hay REL activa).
5. Mostrar bloqueadores: ISSUEs con `relations_outbound: blocks → REL-<PROY>-<VER>`.

### ADD — Añadir ISSUE/componente a release

1. Leer REL.
2. Verificar que el ISSUE existe y está en status adecuado (`entity_get`).
3. Añadir relación `part_of` desde ISSUE a REL:
   ```
   mcp__plugin_kvendra-skills_kvendra-cloud__entity_update({
     entity_id: "ISSUE-<PROY>-<COMP>-<NN>",
     relations_add: [{ type:"part_of", target:"REL-<PROY>-<VER>" }],
     tags_add: ["REL-<PROY>-<VER>"],
     change_summary: "Añadido a REL-<PROY>-<VER>",
     updated_by: "skill:release-manager"
   })
   ```
4. El server registra automáticamente la entrada en `entity_changelog`
   asociada a la REL.

### GATE-CHECK — Verificar regression gates

Para cada componente incluido:
1. `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"REG", project_id:<PROY>, component_id:"<PROY>-<COMP>" })`.
2. Verificar última ejecución (en `metadata.execution_history` o leer la
   última RUN asociada vía `entity_related`).
3. Resultado por componente: PASS / BLOCKED (listar bugs) / PENDING.
4. Resultado global: READY solo si todos los gates OK.

### CLOSE — Cerrar release

Prerrequisitos:
1. Todos los regression gates PASS.
2. Todos los ISSUEs incluidos cerrados.

Proceso:
1. `mcp__plugin_kvendra-skills_kvendra-cloud__entity_update({ entity_id:"REL-<PROY>-<VER>", status:"closed", change_summary:"Release cerrada", updated_by })`. (REL admite cambio de status directo via update porque NO está en TXN.)
2. **Congelar changelog**: `entity_update` con `metadata.frozen: true` (server respeta `frozen` en `entity_changelog` para evitar edits posteriores).
3. Para cada ISSUE incluido con status `done`/`closed`: verificar que tiene TEST regression-case.
4. Actualizar ROAD si alguno se completó: `entity_update` sobre el ROAD con `status:done`.
5. Set `metadata.deployed_date` en la REL.

## Output (varía por acción)

### CREATE:
```
## Release creada
- ID: REL-<PROY>-<VER>
- Tipo: minor
- Estado: planning
- Target: <fecha>
- Kvendra: creado (force_id, validado contra regex ADR-JRV-008)
```

### STATUS:
```
## Release REL-<PROY>-<VER>
- Estado: <status>
- Target: <fecha>
- ISSUEs incluidos: N (M abiertos, K cerrados)
- Regression gates: N/M pass

### Changelog
| Fecha | Autor | Entidad | Cambio | Trigger |
|-------|-------|---------|--------|---------|

### Gates
| Componente | REG | Última ejecución | Resultado |
|-----------|-----|-----------------|-----------|

### Bloqueadores
- ISSUE-<PROY>-<COMP>-<NN> (bug) bloquea esta release
```

### GATE-CHECK:
```
## Regression Gate Check — REL-<PROY>-<VER>
- Resultado: READY / BLOCKED / PENDING

| Componente | Gate | Estado |
|-----------|------|--------|
```

### CLOSE:
```
## Release cerrada
- ID: REL-<PROY>-<VER>
- Fecha cierre: <fecha>
- ISSUEs cerrados: N
- Tests regression verificados: N
- ROAD actualizados: [lista]
- Changelog: congelado
```
