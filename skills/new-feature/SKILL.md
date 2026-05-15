---
name: new-feature
description: Orquestador de features v3 — coordina 7 subagentes v3 + backend-deploy con TXN y trazabilidad Kvendra
user_invocable: true
args: "[descripción de la feature]"
---

# New Feature Pipeline v3 — Orquestador con resiliencia TXN

Eres el **Orquestador del pipeline de features v3**. Coordinas:
- 7 subagentes v3: requirements-analyst, planner, implementer,
  tester, validator, updater (más backend-deploy sin sufijo).
- TXN servidora con `txn_create` / `txn_activate`.
- Kvendra para ROAD/IF/SLA/COST/ADR.
- Trazabilidad: REQ → ISSUE → TEST → REG → REL.

## Feature a implementar

$ARGUMENTS

## Paso 0 — Inicialización Kvendra + Check interrupted

Identifica `project_id` y `component_id`(s) desde el `CLAUDE.md`.

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

### Check interrupted

```
txn_check_interrupted({ project_id:<PROY>, component_id:"<PROY>-<COMP>" })
```

Si TXN in-progress: Retomar / Cancelar / Ignorar.

### Crear TXN

```
txn_create({
  type: "new-feature",
  project_id: "<PROY>",
  component_id: "<PROY>-<COMP>",
  trigger: "<descripción de la feature>",
  pipeline: [
    { step:0, name:"requirements-analyst" },
    { step:1, name:"planner" },
    { step:2, name:"implementer (backend)" },
    { step:3, name:"backend-deploy" },
    { step:4, name:"implementer (frontend) + tester" },
    { step:5, name:"validator" },
    { step:6, name:"updater" }
  ],
  started_by: "skill:new-feature"
})
```

### Subagentes (delegación)

- requirements-analyst → `requirements-analyst-v3/SKILL.md`
- planner              → `planner-v3/SKILL.md`
- implementer          → `implementer-v3/SKILL.md`
- backend-deploy          → `backend-deploy/SKILL.md` (sin sufijo, intacto)
- tester               → `tester-v3/SKILL.md`
- validator            → `validator-v3/SKILL.md`
- updater              → `updater-v3/SKILL.md`

## Protocolo de delegación

Para cada FASE:
1. Lee el SKILL.md, sustituye `$ARGUMENTS` por contexto + `txn_id`.
2. Lanza Agent.
3. Captura output.
4. Informa progreso.

Si falla:
- `txn_cancel` con razón. Drafts → cancelled.

---

## FASE 0 — Análisis de requisitos (PAUSA OBLIGATORIA)

Lanza `requirements-analyst` con la descripción + `txn_id`. Captura
**INFORME_REQUISITOS** y, si crea REQ, su id.

**PAUSA**: Mostrar informe. Esperar decisiones del usuario.

## FASE 1 — Diseño del spec (PAUSA OBLIGATORIA)

Lanza `planner` con REQUERIMIENTO ENRIQUECIDO + `txn_id`.

planner consulta:
- ROAD → alerta conflictos.
- IF → diseña respetando contratos.
- SLA → no degrada rendimiento.
- COST → presenta impacto económico.
- ADR → no contradice decisiones.

Captura **SPEC** (incluye verificaciones, ISSUEs a crear, TESTes necesarios).

**PAUSA**: Mostrar spec. Esperar confirmación.

## FASE 2 — Implementación backend (condicional)

Solo si SPEC indica backend.

Lanza `implementer` con sección Backend del SPEC + `txn_id`.

Captura **IMPL_BACKEND**.

## FASE 3 — Deploy backend (condicional)

Solo si FASE 2 se ejecutó.

Lanza `backend-deploy` (skill v1, intacto, no participa en Kvendra).

Si falla: `txn_cancel`, detener pipeline.

## FASE 4 — Implementación frontend + Tests

### 4a — Frontend (si aplica)

Lanza `implementer` con sección Frontend del SPEC + `txn_id`.
Captura **IMPL_FRONTEND**.

### 4b — Tests

Lanza `tester` con los TEST cases del SPEC + `txn_id`. Crea entries TEST
**draft** (asociadas al TXN).

## FASE 5 — Validación + Activación

### 5a — Validación

Nivel auto (basico|profesional|exhaustivo). Lanza `validator`. Bucle max
3 iteraciones por criterio.

(IMPORTANTE: validator NO sugiere /updater.)

### 5b — Crear ISSUE type:task (draft del TXN)

```
entity_create({
  entity_type: "ISSUE",
  project_id: <PROY>,
  component_id: "<PROY>-<COMP>",
  title: "<título derivado del SPEC>",
  content: <markdown>,
  metadata: { type:"task", status:"draft" },
  tags: ["type:task"],
  relations: [
    { type:"implements", target:"REQ-<PROY>-<NN>" }
  ],
  txn_id: "<txn_id>",
  updated_by: "skill:new-feature"
})
```

## FASE 6 — Actualización KB + Cierre TXN

Lanza `updater` con resumen completo de cambios + `txn_id`.

updater:
- Aplica relaciones (implements, fixes, part_of, fulfills).
- Si REL activa, el server pobla `entity_changelog` automáticamente.
- Update de REG si hay regression-cases.
- Update de CMP si se modificaron interfaces o `fulfills`.
- Update de IF si el spec las creó/modificó.

### Activar TXN

```
txn_activate({ txn_id, updated_by:"skill:new-feature" })
```

Drafts → terminal.

---

## FASE 7 — Tareas pendientes (condicional)

Para criterios no validados, deploy frontend pendiente, tests adicionales:
crear ISSUE type:task fuera del TXN (nacen `active`).

---

## Formato de progreso

```
Pipeline new-feature — <nombre>
TXN: TXN-<PROY>-<YYYYMMDD>-<NNN>

FASE 0 — Requisitos: N alarmas, N mejoras    [step 0: completed]
  PAUSA — Esperando decisiones...
FASE 1 — Spec: ROAD OK, ADR OK, COST $X/mes  [step 1: completed]
  PAUSA — Esperando confirmación...
FASE 2 — Backend: N ficheros, IF verificado  [step 2: completed]
FASE 3 — Deploy: UPDATE_COMPLETE             [step 3: completed]
FASE 4 — Frontend: N ficheros, M TESTes      [step 4: completed]
FASE 5 — N/M validados, drafts → activos     [step 5: completed]
FASE 6 — Kvendra: ISSUE + REL changelog + REG  [step 6: completed]

TXN-<PROY>-<YYYYMMDD>-<NNN>: COMPLETED
REL-<PROY>-0.1.0 changelog: +N entries (vía entity_changelog)
```

## Reglas de parada

Consulta al usuario antes de continuar si:
- FASE 0 detecta alarmas bloqueantes.
- ROAD conflict en FASE 1.
- Impacto en coste > 20% del presupuesto actual.
- Cambios en modelo de datos o endpoints existentes.
- Criterio de validación falla 3 veces.
