---
name: onboard-project
description: Onboarding de proyecto v3 — crea PRJ, CMP, IF, ENV y estructura completa en Kvendra
user_invocable: true
args: "[nombre del proyecto o componente a onboardear]"
---

# Onboard Project v3 — Crear estructura Kvendra

Creas la estructura completa de un proyecto o componente nuevo en el Kvendra:
PRJ, CMP, IF, GLO, ENV, REL baseline y las relaciones iniciales. Validas
naming contra GLO. Orquestador soft — abre TXN para agrupar las creaciones,
pero no delega a otros subagentes v3.

## Proyecto / Componente

$ARGUMENTS

## Paso 0 — Inicialización Kvendra

Identifica `project_id` desde el `CLAUDE.md` (si existe). Si es proyecto
nuevo, `project_id` lo provee el usuario en args.

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

## Paso 1 — Determinar scope

¿Proyecto nuevo o componente nuevo de proyecto existente?

- **Proyecto nuevo**: PRJ + GLO + REL baseline + ENV + CMPs + IFs.
- **Componente nuevo**: CMP + IFs (PRJ ya existe).

## Paso 2 — Explorar repositorio

1. Leer raíz: `ls`, `package.json`, `template.yaml`, `requirements.txt`, etc.
2. Determinar `tech_stack` (python-lambda, angular, nodejs, ...).
3. Determinar `component_type` (backend, frontend, adapter, infra, docs).
4. Identificar interfaces: endpoints, SQS, DynamoDB, webhooks.
5. Identificar dependencias externas.

## Paso 3 — Verificar contra GLO

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"GLO", project_id:<PROY> })
```

- Si proyecto nuevo: crear `GLO-<PROY>-001` con términos de dominio
  (`force_id`, ya que GLO los pasa).
- Si componente: verificar que el código corto no entra en conflicto con
  los `component-codes` del GLO.

## Paso 4 — Abrir TXN

```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_check_interrupted({ project_id:<PROY> })
mcp__plugin_kvendra-skills_kvendra-cloud__txn_create({
  type: "onboarding",
  project_id: "<PROY>",
  component_id: "<PROY>-<COMP>",       // si componente
  trigger: "Onboarding <nombre>",
  pipeline: [
    { step:1, name:"create-prj-or-cmp" },
    { step:2, name:"create-ifs" },
    { step:3, name:"create-env-rel" }
  ],
  started_by: "skill:onboard-project"
})
```

## Paso 5 — Crear entidades (todas en draft del TXN)

### Para proyecto nuevo

1. **PRJ-<PROY>**: `mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({ entity_type:"PRJ", project_id:<PROY>, force_id:"PRJ-<PROY>", title, content, txn_id, updated_by })`. PRJ usa `force_id` (no counter).

2. **GLO-<PROY>-001**: con domain-terms y component-codes.
   `force_id:"GLO-<PROY>-001"`.

3. **ENV-<PROY>-<auto>**: entornos del proyecto (dev/test/prod).
   `mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({ entity_type:"ENV", ... })`.

4. **REL-<PROY>-0.1.0**: baseline (status:planning).
   `force_id:"REL-<PROY>-0.1.0"` (validado contra regex ADR-JRV-008).

5. Para cada componente identificado: ejecutar pasos de "componente nuevo".

### Para componente nuevo

1. **CMP-<PROY>-<COMP>** (force_id: `"CMP-<PROY>-<COMP>"`):
   ```
   mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
     entity_type: "CMP",
     project_id: "<PROY>",
     component_id: "<PROY>-<COMP>",
     force_id: "CMP-<PROY>-<COMP>",
     title: "<nombre>",
     content: <markdown completo>,
     metadata: {
       component_type, tech_stack, standards: ["STD-<PROY>-<NN>"],
       deploy: { method, region }, security_controls, observability,
       config, dependencies, fulfills, interfaces_defined,
       interfaces_consumed, implementation_paths
     },
     relations: [
       { type:"part_of", target:"PRJ-<PROY>" }
     ],
     txn_id: "<txn_id>",
     updated_by: "skill:onboard-project"
   })
   ```

2. **IF-<PROY>-<COMP>-<NNN>** para cada interface identificada:
   ```
   mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
     entity_type: "IF",
     project_id: "<PROY>",
     component_id: "<PROY>-<COMP>",
     title: "<nombre IF>",
     content: <markdown con campos: name, type, direction, required>,
     relations: [
       { type:"part_of", target:"CMP-<PROY>-<COMP>" }
     ],
     txn_id: "<txn_id>",
     updated_by: "skill:onboard-project"
   })
   ```
   El server emite el id (`IF-<PROY>-<COMP>-<NNN>`).

## Paso 6 — Verificar completitud y activar TXN

Verificar perfil de componente (component_type → entidades obligatorias):
- `backend` / `adapter`: CMP + IF (interfaces_defined).
- `frontend`: CMP + IF (interfaces_consumed).
- `infra` / `docs`: CMP.

Si todo OK:
```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_activate({ txn_id, updated_by:"skill:onboard-project" })
```

Si fallo o usuario cancela:
```
mcp__plugin_kvendra-skills_kvendra-cloud__txn_cancel({ txn_id, reason:"<motivo>", updated_by })
```

## Output

```
## Onboarding completado: <nombre>

### TXN
TXN-<PROY>-<YYYYMMDD>-<NNN>: COMPLETED

### Entidades creadas
| Entity ID | Tipo | Título |
|-----------|------|--------|
| PRJ-<PROY> | PRJ | ... |
| GLO-<PROY>-001 | GLO | ... |
| ENV-<PROY>-<NN> | ENV | ... |
| REL-<PROY>-0.1.0 | REL | ... |
| CMP-<PROY>-<COMP> | CMP | ... |
| IF-<PROY>-<COMP>-001 | IF | ... |

### Perfil de componente: <tipo>
- Obligatorias creadas: N/M
- Pendientes: [lista]

### Naming verificado contra GLO
- Nuevos términos: N
- Conflictos: 0/N

### Siguiente paso
- Crear REQ para el proyecto/componente: `/requirements-analyst <REQ>`
- Verificar código existente: `/interface-validator <COMP>`
```
