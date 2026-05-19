---
name: bug
description: Orquestador de testing v3 — coordina 6 subagentes v3 con TXN, entities draft/active, y trazabilidad Kvendra
user_invocable: true
args: "[sección o funcionalidad a probar]"
---

# Bug Pipeline v3 — Orquestador con resiliencia TXN

Eres el **Orquestador del pipeline de testing v3**. Coordinas 6 subagentes
v3 (functional-expert, tester, analyzer, implementer,
validator, updater) con:
- **TXN servidora**: `txn_create` + `txn_activate`/`txn_cancel`.
- **Draft → Active automático** al activar TXN.
- **Kvendra**: trazabilidad estructurada via 12 tools.

## Objetivo a probar

$ARGUMENTS

## Paso 0 — Inicialización Kvendra + Check interrupted

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

### Check interrupted

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_check_interrupted({ project_id:<PROY>, component_id:"<PROY>-<COMP>" })
```

Si hay TXN in-progress:
- Mostrar al usuario: txn_id, type, started_at, pipeline (status por step).
- Opciones: **Retomar** / **Cancelar** / **Ignorar**.
  - Retomar: leer la TXN, deducir el último step completed, continuar.
  - Cancelar: `txn_cancel` con razón.
  - Ignorar: dejar la TXN viva (no aconsejable — habría conflicto al abrir
    otra para el mismo scope).

### Crear TXN

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_create({
  type: "bug",
  project_id: "<PROY>",
  component_id: "<PROY>-<COMP>",
  trigger: "<objetivo a probar>",
  pipeline: [
    { step:1, name:"functional-expert" },
    { step:2, name:"tester" },
    { step:3, name:"analyzer" },
    { step:4, name:"implementer" },
    { step:5, name:"validator" },
    { step:6, name:"updater" }
  ],
  started_by: "skill:bug"
})
```

Captura `txn_id`.

### Subagentes v3 (delegación)

Directorio: `~/.claude/plugins/marketplaces/kvendra-marketplace/plugins/kvendra-skills/skills/`
- functional-expert → `functional-expert-v3/SKILL.md`
- tester            → `tester-v3/SKILL.md`
- analyzer          → `analyzer-v3/SKILL.md`
- implementer       → `implementer-v3/SKILL.md`
- validator         → `validator-v3/SKILL.md`
- updater           → `updater-v3/SKILL.md`


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

## Protocolo de delegación

Para cada FASE:
1. Lee el `SKILL.md` del subagente.
2. Sustituye `$ARGUMENTS` por el contexto + `txn_id`.
3. Lanza Agent.
4. Captura output.
5. Informa progreso al usuario.

Si una fase falla:
- `mcp__plugin_kvendra-skills_kvendra-cloud__txn_cancel({ txn_id, reason, updated_by })`.
- Drafts → cancelled automáticamente.
- Informa al usuario.

---

## FASE 1 — Plan de test

Lanza `functional-expert` con el objetivo. Captura **PLAN_DE_TEST**.

Si 0 flujos a probar → `txn_activate` (caso degenerate sin drafts).

## FASE 2 — Ejecución y creación de TEST entries

Lanza `tester` con el PLAN_DE_TEST + `txn_id`. Crea entries TEST como
**draft** (asociadas al TXN).

Captura **INFORME_BUGS** + lista de TEST IDs creados.

Si 0 bugs → saltar a FASE 5b (sin nuevos ISSUE), luego activar TXN.

## FASE 3 — Análisis por bug (paralelo)

Para cada bug, lanza `analyzer` independiente en paralelo. Consolida
en **ANALISIS_BUGS**.

## FASE 4 — Corrección

Lanza `implementer` con ANALISIS_BUGS + `txn_id`. El skill verifica
naming contra IF y GLO. Captura **RESUMEN_FIXES**.

## FASE 5 — Validación en bucle

### 5a — Validación

Nivel automático (basico/profesional/exhaustivo) según severidad.

Lanza `validator`. Bucle max 3 iteraciones por bug. Si validation falla,
re-iterar con analyzer + implementer.

Captura **BUGS_VALIDADOS** y **BUGS_BLOQUEADOS**.

(IMPORTANTE: validator NO sugiere /updater — ese paso lo decide ESTE
orquestador.)

### 5b — Crear ISSUEs por bug encontrado (drafts en el TXN)

Para cada bug confirmado, `mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({ entity_type:"ISSUE", ..., txn_id })`. Lo emite el server con id auto.

## FASE 6 — Actualización del KB + Activación TXN

Lanza `updater` con BUGS_VALIDADOS + RESUMEN_FIXES + lista de TEST IDs.

updater aplica:
- Relaciones: ISSUE→implements REQ, TEST→fixes ISSUE, IF/CMP→part_of, etc.
- CMP.fulfills update si es feature.
- REG.tests update si hay regression-cases.

### Activar TXN

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_activate({ txn_id, updated_by:"skill:bug" })
```

Drafts → terminal automáticamente. El server pobla `entity_changelog` por
cada entidad activada que tenga REL activa.

---

## FASE 7 — Crear tareas pendientes (condicional)

Si hay bugs bloqueados (3 iteraciones sin éxito) o trabajo pendiente:
`mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({ entity_type:"ISSUE", ... })` con `status:open` o
`status:blocked`. NOTA: estos ISSUE se crean sin TXN porque la TXN del
pipeline ya se activó. Crearlos AHORA significa que nacen `active`.

---

## Formato de progreso

```
Pipeline bug iniciado — Objetivo: <objetivo>
TXN: TXN-<PROY>-<YYYYMMDD>-<NNN>

FASE 1 — Plan: N flujos                    [step 1: completed]
FASE 2 — N bugs, M TEST entries (draft)    [step 2: completed]
FASE 3 — N análisis (paralelo)             [step 3: completed]
FASE 4 — N fixes (IF/GLO verificados)      [step 4: completed]
FASE 5 — N/M validados, K bloqueados       [step 5: completed]
         Drafts del TXN → activos
FASE 6 — KB actualizado                    [step 6: completed]

TXN-<PROY>-<YYYYMMDD>-<NNN>: COMPLETED
```

## Reglas de parada

Consulta al usuario antes de continuar si:
- Cambio requiere infraestructura (template.yaml).
- Fix afecta múltiples componentes críticos.
- Bug nuevo durante validación no previsto.
