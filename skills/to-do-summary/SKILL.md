---
name: to-do-summary
description: Resumen de ISSUEs v3 — muestra estado de work items del Kvendra con filtros por estado, componente, tipo y prioridad
user_invocable: true
args: "[filtros opcionales: componente, tipo, estado, prioridad]"
---

# To-Do Summary v3 — Vista de ISSUEs del Kvendra

Muestras un resumen de los work items (ISSUE) del Kvendra con filtros por
componente, tipo, estado y prioridad.

## Filtros

$ARGUMENTS

## Paso 0 — Inicialización Kvendra

Identifica `project_id` desde el `CLAUDE.md`.

## Reglas Kvendra (resumen)

- Identifícate en cada write: `updated_by: "skill:<este-skill>"`. El header
  `X-Kvendra-Skill` lo añade el cliente MCP automáticamente.
- Orquestador → `txn_create` antes de crear entities, ciérrala con
  `txn_activate` (éxito) o `txn_cancel(reason)` (fallo).
  Subagente → recibe `txn_id` por args y NO abre/cierra TXN.
- Antes de abrir TXN: `txn_check_interrupted(project_id, component_id?)`.
  Si hay TXN in-progress: Retomar / Cancelar / Ignorar.
- IDs los emite el server. Excepción: `PRJ`/`CMP`/`REL` requieren `force_id`.
- Si un error trae `error.help.topic`, llama `help({topic})`. Topics:
  `bootstrap, identity, naming, txn, validation, errors, embeddings,
  tools, examples, entity_types[/<TYPE>]`.

## Paso 1 — Consultar ISSUEs

Aplicar filtros de los argumentos:

```
entity_query({
  entity_type: "ISSUE",
  project_id: <PROY>,
  component_id: <opcional>,
  status: ["new", "in-progress", "analyzing"],   // o array según filtro
  tags_all: ["type:<tipo>", "priority:<nivel>"], // opcional
  archived: false,
  drafts: false,
  order_by: "updated_at_desc",
  limit: 100
})
```

## Paso 2 — Presentar resultados

```
## ISSUEs — <proyecto> <filtros aplicados>
Fecha: <fecha>

### Resumen
- Total: N
- Bugs: N (M critical, K high)
- Tasks: N
- Incidents: N
- Bloqueadores de release: N

### Por estado
| Estado | Count |
|--------|-------|
| new | N |
| in-progress | N |
| analyzing | N |
| fixing | N |
| blocked | N |

### Detalle
| ID | Tipo | Prior. | Estado | Comp. | Título | Release |
|----|------|--------|--------|-------|--------|---------|
| ISSUE-WO-IVR-001 | bug | high | fixing | IVR | Timeout callback | REL-WO-0.1.0 |
| ISSUE-WO-042 | task | medium | new | — | Actualizar docs | — |

### Bloqueadores de release
Para cada ISSUE con relación `blocks → REL-...` activa:
| ISSUE | Bloquea | Motivo |
|-------|---------|--------|
| ISSUE-WO-IVR-050 | REL-WO-0.1.0 | Regresión en TEST-WO-IVR-020 |
```

Para cada ISSUE en bloqueadores, usar `entity_get({ entity_id, include_related: false })` y leer las `relations_outbound` para detectar `blocks`.
