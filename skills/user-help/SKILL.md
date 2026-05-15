---
name: user-help
description: Asistente de ayuda v3 — explica el sistema de skills v3, flujos de trabajo y como usar cada herramienta sobre Kvendra
user_invocable: true
args: "[tema opcional: skills, to-do, pipelines, kb, projects, all]"
---

# User Help v3 — Guia del sistema Winking Owl Skills (Kvendra)

Actuas como **Asistente de Ayuda**. Explicas como funciona el ecosistema
de skills v3, flujos de trabajo y herramientas disponibles sobre el Kvendra.

## Tema solicitado

$ARGUMENTS

## Paso 0 — Inicialización Kvendra

Identifica `project_id` desde el `CLAUDE.md` si existe.

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

## Comportamiento

Si el usuario indica un tema específico, muestra solo esa sección.
Si indica "all", muestra la guía completa.
Si no indica nada, muestra primero el menú:

```
AYUDA — Winking Owl Skills v3
==============================

Temas disponibles:

  /user-help skills       Catalogo completo de skills v3
  /user-help to-do        Sistema de ISSUE
  /user-help pipelines    Flujos de desarrollo (bug, feature)
  /user-help kb           Kvendra entities (12 tools)
  /user-help projects     Proyectos del ecosistema
  /user-help all          Guia completa

¿Sobre que tema quieres saber mas?
```

---

## SECCION: skills — Catalogo de skills v3

```
SKILLS V3 DISPONIBLES
======================

PUNTO DE ENTRADA
  /consultancy [tema]     Explorar idea, duda o problema con contexto
                             Kvendra completo. 9 opciones cerradas para
                             accionar conclusión.

GESTION DE ISSUE
  /to-do create [desc]              Crear ISSUE (bug | task | incident)
  /to-do update ISSUE-...           Actualizar status, prioridad, asign
  /to-do close ISSUE-...            Cerrar ISSUE
  /to-do list                       Listar con filtros
  /to-do-summary                    Resumen visual con filtros

PIPELINES DE DESARROLLO (orquestadores con TXN)
  /bug [seccion]          Pipeline testing y correccion:
                             plan → test → analisis → fix → validacion → KB
  /new-feature [desc]     Pipeline nueva funcionalidad:
                             requisitos → spec → backend → deploy → frontend
                             + tests → validacion → KB
  /incident-manager       Gestion de incidentes con RCA + postmortem +
                             RUN/REQ/PAT derivados

SUBAGENTES (usados por pipelines, también invocables)
  /requirements-analyst   Analiza requisitos contra REQ/ROAD/IF/CMP/ADR
  /functional-expert      Plan de test detallado
  /planner                Spec técnico contra REQ/IF/ROAD/SLA/COST/ADR
  /implementer            Aplica cambios verificando IF/GLO/STD
  /validator              Verifica cambios (3 niveles)
  /tester                 Ejecuta tests y crea TEST entries (draft)
  /analyzer               Causa raíz + propuesta de fix
  /updater                Coherencia: relaciones, REL changelog, derivadas
  /interface-validator    Naming en código vs IF y GLO
  /doc-validator          Formato + forma + contenido de manuales
  /doc-indexer            Indexa docs como entries DOC

OPERACIONES
  /backend-deploy            Despliega stack SAM en AWS (sin sufijo, intacto)
  /regression             Suite de regresion + auto-genera ISSUE bugs
  /release-manager        Crea/gestiona/cierra REL con SemVer ADR-JRV-008
  /onboard-project        Onboarding: PRJ + CMP + IF + GLO + ENV + REL

DOCUMENTACION
  /manual-writer          Manuales tecnicos y de usuario, multi-idioma
  /translator             Traduce manuales con glosario consistente
  /changelog              Consulta de cambios cross-entidad/REL/fecha

CONFIGURACION
  /env-check                 Verifica entorno (MCP, 14 Kvendra MCP tools, skills)
  /setup [email]             Configura Claude Code para usar el Kvendra
  /user-help [tema]       Esta ayuda
```

## SECCION: to-do — Sistema de ISSUE en Kvendra

```
SISTEMA DE ISSUE (Kvendra)
=========================

Las ISSUE se almacenan en el Kvendra (entity_type=ISSUE). Persisten entre
sesiones y son el nexo entre bugs, features y trabajo pendiente.

TIPOS DE ISSUE
  bug             Bug encontrado
  task            Tarea pendiente
  incident        Incidente operativo (gestion via /incident-manager)

ESTADOS
  new             Pendiente, sin empezar
  in-progress     En curso
  analyzing       En analisis
  fixing          En implementacion
  blocked         Bloqueada
  done            Completada (task)
  closed          Cerrada (bug)
  postmortem-done RCA completado (incident)

PRIORIDADES
  critical | high | medium | low

FORMATO DE ID
  ISSUE-<PROY>-<COMP>-<NNN>   Con componente
  ISSUE-<PROY>-<NNN>          Cross-componente
  El servidor emite el id automaticamente (counter atomico).

FLUJO TIPICO
  1. /to-do-summary                Ver mis ISSUEs activos
  2. /to-do update ISSUE-...       Cambiar status a in-progress
  3. (trabajo)
  4. /to-do close ISSUE-...        Cerrar ISSUE

CREACION AUTOMATICA
  - /bug: crea ISSUE bug por cada hallazgo confirmado
  - /new-feature: crea ISSUE task derivada del SPEC
  - /regression: crea ISSUE bug si regression-case falla
  - /incident-manager: crea ISSUE incident
```

## SECCION: pipelines — Flujos de desarrollo

```
PIPELINES (Kvendra)
==================

PIPELINE DE BUG (/bug)
  TXN: type=bug, 6 fases.
  
  FASE 1  functional-expert      Plan de test
  FASE 2  tester                 Ejecucion + TEST entries (draft)
  FASE 3  analyzer               Causa raiz (paralelo por bug)
  FASE 4  implementer            Aplicar fixes
  FASE 5  validator              Verificar (max 3 iter por bug)
  FASE 6  updater                Coherencia Kvendra + activar TXN

PIPELINE DE FEATURE (/new-feature)
  TXN: type=new-feature, 7 fases.

  FASE 0  requirements-analyst   Analisis (PAUSA)
  FASE 1  planner                Spec (PAUSA)
  FASE 2  implementer (backend)  Aplicar
  FASE 3  backend-deploy            Deploy SAM
  FASE 4  implementer (frontend) Aplicar + tester crea TESTes draft
  FASE 5  validator              Verificar (max 3 iter)
  FASE 6  updater + activar TXN

INCIDENTES (/incident-manager)
  Crea ISSUE type:incident con embedding ON (excepcion ADR-JRV-003).
  Lifecycle: detected → investigating → mitigating → resolved →
             postmortem-done.
  Genera RUN/REQ/PAT derivados como drafts del TXN del incidente.

NIVELES DE VALIDACION (validator)
  basico         Verifica que no rompe (UI/CSS/traducciones)
  profesional    Flujos e2e completos
  exhaustivo     Edge cases, roles, errores
  Auto-determinado segun tipo de cambio.
```

## SECCION: kb — Kvendra entities

```
KNOWLEDGE BASE v3
==================

Kvendra es una BD vectorial centralizada con schema dedicado, accesible
via MCP. Contrato en el servidor (no en prompts) — invariantes
encapsulados en handlers.

ENTITY TYPES (20)
  PRJ, CMP, IF, REQ, TEST, REG, ISSUE, REL, SLA, ROAD, GLO, STD, PAT, ADR,
  RUN, UX, DOC, TXN, ENV, COST

LAS 14 TOOLS DE KVENDRA
  entity_create        Crear entidad (auto-id)
  entity_update        Update atomic (change_summary requerido)
  entity_archive       Soft-archive (reversible)
  entity_get                  Lookup por entity_id
  entity_query                Filtros booleanos (tags_all/any, status, ...)
  entity_search               Busqueda semantica (cosine, ≥3 chars, ≤20)
  check_duplicates     Recomendador advisory pre-create
  entity_related          Top-N semánticamente cercanas
  txn_create           Abrir TXN (orquestadores)
  txn_activate         Cerrar TXN OK (drafts → terminal)
  txn_cancel           Cerrar TXN con reason (drafts → cancelled)
  txn_check_interrupted    Listar TXN in-progress por scope

ERROR ENVELOPE
  { code: 'VALIDATION'|'NOT_FOUND'|'CONFLICT'|'INTEGRITY'|'INTERNAL', ... }

EMBEDDING OPT-OUT (ADR-JRV-003)
  ISSUE, TXN, RUN, ENV, COST: NO embedding por defecto.
  Excepcion: incident-manager fuerza embedding ON en ISSUE incident.

ARCHIVE NO ADMITIDO
  ADR, TXN: no se pueden archivar (registros historicos inmutables).
```

## SECCION: projects — Proyectos del ecosistema

Esta sección es **dinámica**. Para mostrarla:

1. `entity_query({ entity_type:"PRJ", limit:20 })`.
2. Para cada PRJ: el contenido ya tiene la descripción.
3. Presenta:

```
PROYECTOS WINKING OWL
======================

| Proyecto | Descripcion | Componentes |
|----------|-------------|-------------|
| <project_id> | <descripcion del PRJ> | N |

Cada proyecto tiene su CLAUDE.md con project_id, stack, paths y skills
disponibles.
```

Si la query falla, sugiere `/env-check` para verificar conexion.

## Reglas

- Adapta el nivel de detalle al tema solicitado.
- Si el usuario pregunta algo especifico ("como creo una ISSUE?"), responde
  directamente sin mostrar toda la guia.
- Si el usuario parece perdido, sugiere `/consultancy` o
  `/to-do-summary`.
- Menciona siempre que `/user-help [tema]` da mas detalle sobre un tema
  concreto.
