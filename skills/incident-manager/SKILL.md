---
name: incident-manager
description: Gestor de incidentes v3 — crea ISSUE type:incident con RCA y postmortem en Kvendra, y genera RUN/REQ/PAT derivados
user_invocable: true
args: "[descripción del incidente o 'postmortem' para cerrar uno existente]"
---

# Incident Manager v3 — Gestión de incidentes Kvendra

Gestionas incidentes operativos (caídas, degradación, errores en producción).
Creas ISSUE type:incident con impacto, duración, RCA y postmortem. Generas
entidades derivadas: RUN (runbooks nuevos), REQ (mejoras), PAT (lecciones).

Orquestador soft — abre TXN para agrupar las creaciones del postmortem,
pero no delega a subagentes v3.

## Incidente

$ARGUMENTS

## Paso 0 — Inicialización Kvendra

Identifica `project_id` y `component_id` desde el `CLAUDE.md`.

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

## Paso 1 — Buscar incidentes y runbooks similares

**IMPORTANTE — opt-in de embedding para ISSUE de incidentes**: para que la
búsqueda semántica encuentre incidentes pasados, este skill crea ISSUE
con `generate_embedding: true`. Es la excepción justificada al opt-out.

```
entity_search({ query:<descripción del problema>, entity_type:"ISSUE", project_id:<PROY>, limit:5 })
entity_search({ query:<componente o síntoma>, entity_type:"RUN", project_id:<PROY>, limit:3 })
```

Si hay un RUN que cubre este escenario → mostrar como guía de resolución.
Si hay incidente pasado similar → mostrar para contexto.

## Paso 2 — Abrir TXN del incidente

```
txn_check_interrupted({ project_id:<PROY>, component_id:"<PROY>-<COMP>" })
# si hay TXN in-progress: Retomar / Cancelar / Ignorar
```

```
txn_create({
  type: "incident",
  project_id: "<PROY>",
  component_id: "<PROY>-<COMP>",
  trigger: "<descripción breve>",
  pipeline: [
    { step: 1, name: "create-issue" },
    { step: 2, name: "lifecycle-updates" },
    { step: 3, name: "postmortem-derived-entities" }
  ],
  started_by: "skill:incident-manager"
})
```

Captura `txn_id`.

## Paso 3 — Crear ISSUE type:incident

```
entity_create({
  entity_type: "ISSUE",
  project_id: "<PROY>",
  component_id: "<PROY>-<COMP>",
  title: "<descripción breve>",
  content: <markdown ver formato abajo>,
  metadata: {
    type: "incident",
    severity: "critical|major|minor",
    detection_method: "alarm|user|monitoring",
    started_at: "<ISO>"
  },
  tags: ["type:incident", "severity:<...>"],
  txn_id: "<txn_id>",
  generate_embedding: true,
  updated_by: "skill:incident-manager"
})
```

### Formato del content

```markdown
# <título>

## Tipo: incident
## Estado: detected → investigating → mitigating → resolved → postmortem-done
## Severidad: critical | major | minor

## Impacto
- Qué se afectó: [servicios, usuarios, funcionalidades]
- Alcance: [% usuarios afectados, volumen perdido]
- Duración: [desde — hasta]

## Timeline
| Hora | Evento |
|------|--------|
| HH:MM | Detectado: [cómo] |
| HH:MM | Investigando: [primeras acciones] |
| HH:MM | Causa identificada |
| HH:MM | Mitigación aplicada |
| HH:MM | Resuelto |

## Detección
- Método: ...
- Tiempo de detección: ...

## RCA (cuando se identifica)
[Causa raíz]

## Resolución
[Qué se hizo]

## Postmortem
### Qué salió bien
### Qué salió mal
### Acciones derivadas
- RUN: ...
- REQ: ...
- PAT: ...
```

## Paso 4 — Gestionar lifecycle

Conforme avanza, `entity_update` con tags actualizados y `change_summary`:
1. `detected` → primer estado.
2. `investigating` → analizando causa.
3. `mitigating` → solución temporal.
4. `resolved` → servicio restaurado.
5. `postmortem-done` → RCA completado, derivadas creadas.

## Paso 5 — Generar entidades derivadas (al postmortem)

### 5a — RUN (si procede)

Si no existe runbook que cubra este escenario:

```
entity_create({
  entity_type: "RUN",
  project_id: "<PROY>",
  component_id: "<PROY>-<COMP>",
  title: "RUN-<PROY>-<COMP>-<auto>: <descripción>",
  content: <pasos de resolución>,
  metadata: { origin_issue: "ISSUE-<PROY>-<COMP>-<NN>" },
  txn_id: "<txn_id>",
  updated_by: "skill:incident-manager"
})
```

(RUN no admite relations en Kvendra — la trazabilidad va en metadata.)

### 5b — REQ (si procede)

Si revela necesidad de mejora (alerting, monitoring, redundancia):

```
entity_create({
  entity_type: "REQ",
  project_id: "<PROY>",
  title: "REQ-<PROY>-<auto>: <mejora>",
  content: <descripción + criterios de aceptación>,
  relations: [
    { type: "derives_from", target: "ISSUE-<PROY>-<COMP>-<NN>" }
  ],
  txn_id: "<txn_id>",
  updated_by: "skill:incident-manager"
})
```

### 5c — PAT (si procede)

Si hay lección generalizable:

```
entity_create({
  entity_type: "PAT",
  project_id: "<PROY>",
  title: "PAT-<PROY>-<auto>: <lección>",
  content: <markdown con la lección + cuándo aplicarla + ejemplo>,
  relations: [
    { type: "derives_from", target: "ISSUE-<PROY>-<COMP>-<NN>" }
  ],
  txn_id: "<txn_id>",
  updated_by: "skill:incident-manager"
})
```

## Paso 6 — Cerrar TXN

```
txn_activate({ txn_id, updated_by:"skill:incident-manager" })
```

Las entidades pasan de `draft` a `active`/`postmortem-done` según corresponda.

## Output

```
## Incidente: ISSUE-<PROY>-<COMP>-<NNN>
- Estado: <status>
- Severidad: <severidad>
- Impacto: <resumen>
- Duración: <tiempo>
- RCA: <resumen>
- TXN: TXN-<PROY>-<YYYYMMDD>-<NNN>

### Entidades derivadas
- RUN-<PROY>-<COMP>-<NNN>: runbook creado
- REQ-<PROY>-<NNN>: mejora propuesta
- PAT-<PROY>-<NNN>: lección aprendida

### Kvendra actualizado
- ISSUE creada (con embedding)
- TXN activada (drafts → active)
```
