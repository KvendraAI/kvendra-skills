---
name: interface-validator
description: Validador de interfaces v3 — verifica naming de campos en código contra IF y GLO del Kvendra
user_invocable: false
args: "[componente a validar o 'all' para todos]"
---

# Interface Validator v3 — Verificar naming contra Kvendra

Escaneas el código fuente de un componente y verificas que los nombres de
campos usados coinciden con los contratos de interface (IF) y el glosario
(GLO) del Kvendra. Detectas discrepancias de naming que causan bugs de
integración. Subagente — NO abre TXN.

## Componente a validar

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

## Paso 1 — Cargar contratos de referencia

1. **GLO global del proyecto (fuente de verdad para naming):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"GLO", project_id:<PROY>, tags_all:["domain-terms"] })`
   → cada término con sus formas canónicas (camelCase, snake_case) y never_use

2. **Tabla de códigos de componentes (si existe GLO con component-codes):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"GLO", project_id:<PROY>, tags_all:["component-codes"] })`

3. **CMP del componente (interfaces_defined / interfaces_consumed):**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"CMP", project_id:<PROY>, tags_all:["CMP-<PROY>-<COMP>"] })`

4. **IFs definidas e IFs consumidas:**
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"IF", project_id:<PROY>, component_id:"<PROY>-<COMP>" })`
   Para cada IF consumida desde otro componente, `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"IF-<...>" })`.

## Paso 2 — Escanear código fuente

Para el directorio del componente (de CMP.implementation_paths o GLO):

1. **Buscar `never_use` del glosario** en el código (Grep).
   - Match → VIOLATION
2. **Verificar naming canónico de cada IF.field**:
   - Python: snake_case (`route_id`)
   - TypeScript: camelCase (`routeId`)
   - Match incorrecto → VIOLATION
3. **Buscar campos hardcoded** que parecen field names sospechosos:
   - Strings literales (ej `"rutaId"`, `"session_ID"`)
   - Comparar contra GLO e IF

## Paso 3 — Clasificar resultados

- **VIOLATION**: nombre incorrecto que DEBE corregirse.
- **WARNING**: posible inconsistencia que debe revisarse.
- **INFO**: observación sobre naming sin error.

## Output requerido

```
## Interface Validation Report
Componente: CMP-<PROY>-<COMP>
Fecha: <fecha>

### Resumen
- Ficheros escaneados: N
- Violations: N
- Warnings: N
- Info: N

### VIOLATIONS

**V-001: <fichero>:<línea>**
- Encontrado: `rutaId`
- Canónico: `routeId` (camelCase) / `route_id` (snake_case)
- Referencia: GLO-<PROY>-001 (route), IF-<PROY>-<COMP>-001
- Impacto: campo no será reconocido por adapter consumidor

### WARNINGS
... (mismo formato)

### INTERFACES VERIFICADAS
| IF ID | Campos verificados | Violations | Estado |
|-------|-------------------|------------|--------|
| IF-WO-FLW-001 | 7/7 | 0 | OK |
| IF-WO-BE-002 | 12/12 | 1 | FAIL |

### GLO TERMS VERIFICADOS
| Término | Formas canónicas | Violations never_use | Estado |
|---------|------------------|----------------------|--------|
| route | routeId/route_id | 0 | OK |

### RECOMENDACIONES
1. Corregir V-001 ...
```

---
Devuelve el reporte. NO sugieras llamar a otros skills — el orquestador o el
usuario decide si invoca implementer para corregir.
