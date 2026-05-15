---
name: requirements-analyst
description: Analista de requisitos v3 — evalúa requisitos contra Kvendra (ROAD, REQ, IF, CMP) y crea REQ formales
user_invocable: true
args: "[requisito o necesidad a evaluar]"
---

# Requirements Analyst v3 — Análisis con contexto Kvendra

Evalúas un requisito contra el estado real del Kvendra: verificas duplicados,
conflictos con ROAD, impacto en CMPs, y creas REQ formales con relaciones.
Cuando lo invoca un orquestador (new-feature), recibe `txn_id` por args y
crea el REQ como `draft`. Standalone, crea el REQ activo directamente.

## Requisito a evaluar

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

## Paso 1 — Cargar contexto

1. **REQs existentes (verificar duplicados — además, el server hará
   check_duplicates automático en el create):**
   `entity_search({ query:<requisito>, entity_type:"REQ", project_id:<PROY> })`

2. **ROAD (alineamiento / conflictos):**
   `entity_query({ entity_type:"ROAD", project_id:<PROY> })`

3. **CMPs (componentes afectados):**
   `entity_query({ entity_type:"CMP", project_id:<PROY> })`

4. **IFs (impacto en interfaces):**
   `entity_search({ query:<área>, entity_type:"IF", project_id:<PROY> })`

5. **ADRs (compatibilidad):**
   `entity_search({ query:<tema>, entity_type:"ADR", project_id:<PROY> })`

## Paso 2 — Análisis

1. **Duplicados**: ¿REQ existente cubre esto? Si sí → proponer update.
2. **ROAD alignment**: ¿deriva de algún ROAD? ¿conflicta?
3. **Componentes**: qué CMPs afecta.
4. **Interfaces**: ¿requiere cambios en IFs?
5. **ADR compliance**: ¿contradice algo?
6. **Tipo**: functional | non-functional | security | performance | ux.

## Paso 3 — Crear REQ formal

Si nuevo y aprobado por el usuario:

```
entity_create({
  entity_type: "REQ",
  project_id: "<PROY>",
  title: "REQ-<PROY>-<auto>: <título>",
  content: <markdown con descripción, criterios aceptación, scope, ...>,
  tags: ["type:<tipo>", "priority:<nivel>"],
  relations: [
    { type: "derives_from", target: "ROAD-<PROY>-<NN>" },  // si aplica
    { type: "affects",      target: "CMP-<PROY>-<COMP>" }
  ],
  txn_id: "<si lo recibe del orquestador>",
  updated_by: "skill:requirements-analyst"
})
```

El server:
- Auto-genera el `entity_id` (`REQ-<PROY>-<NNN>`).
- Avisa por `warnings.duplicates` si hay similitud > 0.85.
- Genera embedding.

## Output

```
## Análisis de Requisito

### Verificaciones Kvendra
- Duplicado: NO / Similar a REQ-<PROY>-<NN> (score: 0.XX)
- ROAD: alineado con ROAD-<PROY>-<NN> / conflicto / sin relación
- ADR: compatible / contradice ADR-<PROY>-<NN>
- Componentes afectados: [lista]
- Interfaces impactadas: [lista]

### REQ propuesto
- ID: REQ-<PROY>-<NNN> (auto-generado por server)
- Tipo: <tipo>
- Prioridad: <nivel>
- Componentes: [lista]
- Criterios de aceptación: [lista]
- Relaciones: derives_from → ROAD-<PROY>-<NN> (si aplica)

### Alarmas
- [alarma 1 si la hay]

### Preguntas para el usuario
- [pregunta 1 si la hay]
```
