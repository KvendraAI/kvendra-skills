---
name: changelog
description: Consulta de cambios v3 — muestra qué cambió, quién, cuándo y por qué, leyendo entity_history y entity_changelog del Kvendra
user_invocable: true
args: "[filtros: proyecto, componente, fecha, release, autor, entidad]"
---

# Changelog v3 — Consulta transversal de cambios

Consultas y presentas los cambios realizados en el Kvendra filtrando por
múltiples criterios. El server mantiene `entity_history` (audit por entidad)
y `entity_changelog` (per-REL) automáticamente. Aquí los presentas.

## Filtros

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

## Paso 1 — Interpretar filtros

Parsea argumentos:
- **Proyecto**: WO, PRM, JRV (default: del CLAUDE.md).
- **Componente**: código corto.
- **Fecha**: rango (últimos N días, desde-hasta).
- **Release**: REL ID específica.
- **Autor**: nombre o `skill:<name>`.
- **Entidad**: tipo (IF, CMP, TEST...) o ID específico.

Ejemplos:
- `/changelog WO IVR últimos 7 días`
- `/changelog REL-WO-0.1.0`
- `/changelog IF últimos 30 días`
- `/changelog` (resumen general reciente)

## Paso 2 — Recopilar datos

### Fuente 1: entity_history (per entity)

`mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id, include_related: false })` devuelve `history` (últimas 5).

Si filtramos por entidad concreta, basta con esto. Si filtramos por
componente o tipo: primero `mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type, project_id, component_id, order_by: "updated_at_desc" })` y luego `entity_get` por cada uno.

### Fuente 2: entity_changelog (per REL)

Para cada REL del filtro, `mcp__plugin_kvendra-skills_kvendra-cloud__entity_get({ entity_id:"REL-..." })` — el server
devuelve el changelog asociado en el bundle.

### Fuente 3: TXN recientes

`mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"TXN", project_id:<PROY>, order_by:"updated_at_desc", limit:10 })`

→ pasos completados / cancelados, pipelines, tiempos.

## Paso 3 — Presentar resultados

Ordenar cronológicamente (más reciente primero).

## Output

```
## Changelog — <descripción del filtro>
Período: <rango de fechas>

### Resumen
- Total cambios: N
- Entidades modificadas: N
- Autores: [lista]
- Releases afectadas: [lista]

### Timeline

#### <fecha>
| Hora | Autor | Entidad | Cambio | Trigger | Release |
|------|-------|---------|--------|---------|---------|
| 16:30 | skill:implementer | IF-WO-IVR-001 | +campo timeoutMs | ISSUE-WO-IVR-019 | REL-WO-0.1.0 |
| 16:15 | skill:tester      | TEST-WO-IVR-001 | v1.1→1.2, +V5 | ISSUE-WO-IVR-019 | REL-WO-0.1.0 |
| 15:00 | juan@wo              | REQ-WO-006 | Creación inicial | feature request | REL-WO-0.1.0 |

### Por componente
| Componente | Cambios | Último cambio |
|-----------|---------|--------------|
| IVR | 5 | 2026-04-16 |

### Por tipo de entidad
| Tipo | Cambios |
|------|---------|
| IF | 3 |
| TEST | 4 |
| ISSUE | 2 |
| REQ | 1 |
```
