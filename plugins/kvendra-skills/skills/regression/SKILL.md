---
name: regression
description: Suite de regresión v3 — ejecuta REG suites del Kvendra, persiste resultados como RUN, compara vs SLA, auto-genera ISSUEs
user_invocable: true
args: "[componente o REG suite a ejecutar]"
---

# Regression v3 — Ejecutar suites de regresión Kvendra

Ejecutas suites de regresión (REG) definidas en el Kvendra. Respetas orden y
dependencias entre tests, persistes resultados como entries RUN, comparas
contra SLA targets, y auto-generas ISSUE type:bug si algún test blocking
falla.

## Componente o suite

$ARGUMENTS

## Paso 0 — Inicialización Kvendra

Identifica `project_id` y `component_id` desde el `CLAUDE.md` o args.

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

## Paso 1 — Cargar REG suite

1. **REG del componente:**
   `entity_query({ entity_type:"REG", project_id:<PROY>, component_id:"<PROY>-<COMP>" })`

   Si se especifica un REG ID concreto:
   `entity_get({ entity_id:"REG-<PROY>-<COMP>-<SEQ>" })`

2. Si no existe REG → informar y preguntar si crear una.

3. **Tests incluidos (vía `entity_related` o relations_outbound `part_of`):**
   Para cada `test_id` referenciado: `entity_get({ entity_id })`.

4. **SLA targets:**
   `entity_query({ entity_type:"SLA", project_id:<PROY>, component_id:"<PROY>-<COMP>" })`

5. **REL activa (asociar resultados):**
   `entity_query({ entity_type:"REL", project_id:<PROY>, tags_all:["status:planning"] })`

## Paso 2 — Verificar precondiciones

Verificar que se cumplen:
- Componente desplegado en el entorno target.
- Dependencias accesibles.
- Datos de test disponibles.

Si alguna falla → resultado BLOCKED, no ejecutar.

## Paso 3 — Ejecutar tests en orden

Reglas:
1. **Orden**: por campo `order` de cada test.
2. **Blocking**: si test con `blocking: true` falla → suite falla.
3. **Parallel groups**: tests con mismo `order` y `parallel_group` en paralelo.
4. **Smoke gate**: si test order:1 (smoke) falla, ABORTAR la suite.

Para cada test:
1. `entity_get({ entity_id:"TEST-..." })` — leer entrada completa.
2. Verificar precondiciones del test.
3. Ejecutar pasos según el proceso definido.
4. Evaluar cada validación.
5. Registrar resultado: pass | warning | fail | blocked.

## Paso 4 — Evaluar resultado global

Aplicar `success_criteria` de la REG:
- **Pass**: todos los blocking pasan.
- **Warning**: pass pero algún no-blocking falla.
- **Fail**: cualquier blocking falla.
- **Blocked**: smoke (order:1) falla.

Comparar contra SLA si disponible:
- Tests `performance` → contra SLA targets.
- Si excede SLA → warning (no fail, salvo que blocking).

## Paso 5 — Persistir RUN

Crear entry RUN (no embedding por defecto):

```
entity_create({
  entity_type: "RUN",
  project_id: "<PROY>",
  component_id: "<PROY>-<COMP>",
  title: "RUN-<PROY>-<COMP>-<auto>: regression <REG-id> <fecha>",
  content: <markdown con resultado por test, tiempos, evidencia, SLA compliance>,
  metadata: {
    reg_id: "REG-<PROY>-<COMP>-<SEQ>",
    started_at: "<ISO>",
    completed_at: "<ISO>",
    overall_result: "pass|warning|fail|blocked",
    test_results: [
      { test_id, result, duration_ms, validations: [...] }
    ],
    rel_id: "REL-<PROY>-<VER>"   // si activa
  },
  tags: ["result:<resultado>"],
  updated_by: "skill:regression"
})
```

(RUN no admite relations en Kvendra — `relations=no`. La trazabilidad va en
`metadata.reg_id` / `metadata.rel_id` y en tags.)

## Paso 6 — Auto-generar ISSUE si falla blocking

Para cada test blocking que falló:

```
entity_create({
  entity_type: "ISSUE",
  project_id: "<PROY>",
  component_id: "<PROY>-<COMP>",
  title: "ISSUE-<PROY>-<COMP>-<auto>: Regresión en <test_name>",
  content: <descripción con steps to reproduce del TEST>,
  metadata: {
    type: "bug",
    severity: "major",
    priority: "high",
    found_in: "REG-<PROY>-<COMP>-<SEQ>",
    test_id: "TEST-<PROY>-<COMP>-<SEQ>"
  },
  tags: ["type:bug", "priority:high", "found-in:regression"],
  relations: [
    { type:"blocks", target:"REL-<PROY>-<VER>" },     // si REL activa
    { type:"affects", target:"CMP-<PROY>-<COMP>" }
  ],
  updated_by: "skill:regression"
})
```

## Paso 7 — Output

```
## Suite de regresión — REG-<PROY>-<COMP>-<SEQ>
Fecha: <fecha ISO>
Componente: CMP-<PROY>-<COMP>
Release: REL-<PROY>-<VER> (si activa)

### Resultado global: PASS / WARNING / FAIL / BLOCKED

### Duración: <tiempo total>

### Tests ejecutados
| # | Test ID | Tipo | Blocking | Resultado | Duración | Notas |
|---|---------|------|----------|-----------|----------|-------|
| 1 | TEST-...-050 | smoke | sí | pass | 2s | |
| 2 | TEST-...-001 | functional | sí | pass | 45s | |
| 3 | TEST-...-020 | regression | sí | fail | 30s | V3 falló |
| 4 | TEST-...-060 | performance | no | warning | 120s | p95=33s, SLA=30s |

### SLA compliance
| Métrica | Target | Actual | Estado |
|---------|--------|--------|--------|
| latency_e2e | < 120s | 95s | OK |
| error_rate | < 5% | 0% | OK |

### RUN persistido
- RUN-<PROY>-<COMP>-<NNN> (overall_result: <resultado>)

### Bugs auto-generados
- ISSUE-<PROY>-<COMP>-<NNN> (type: bug): Regresión en TEST-...-020
  - Severidad: major
  - Bloquea: REL-<PROY>-<VER>

### Impacto en release
- REL-<PROY>-<VER>: BLOQUEADA por ISSUE-<PROY>-<COMP>-<NNN>
  (o: gate OK — todos los blocking pasan)
```
