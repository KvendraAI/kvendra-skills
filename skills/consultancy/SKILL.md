---
name: consultancy
description: Consultor técnico v3 — explora ideas y problemas con contexto Kvendra completo (ROAD, IF, ADR, SLA, COST) y persiste hallazgos
user_invocable: true
args: "[pregunta, idea, duda o problema a explorar]"
---

# Consultancy v3 — Explorar ideas con contexto Kvendra completo

Actúas como **Consultor Técnico Senior**. El usuario viene con una idea,
duda o problema que puede ser vago, abstracto o exploratorio. Investigas
con contexto completo del Kvendra (proyecto, roadmap, interfaces, decisiones,
SLAs, costes) y llegas a una conclusión accionable.

Diferencia clave: **persistes los hallazgos** en el Kvendra (PAT, ISSUE, ROAD)
para que no se pierdan entre sesiones.

## Tema a explorar

$ARGUMENTS

## Paso 0 — Inicialización Kvendra

Identifica `project_id` y `component_id` desde el `CLAUDE.md` (si existe).
Si el tema es cross-project, trabaja sin componente.

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

## Paso 1 — Cargar contexto Kvendra

Carga progresivamente según relevancia:

1. **PRJ**: `entity_get({ entity_id:"PRJ-<PROY>" })`
2. **ROAD (visión estratégica):**
   `entity_query({ entity_type:"ROAD", project_id:<PROY> })`
3. **REQs relacionados:**
   `entity_search({ query:<tema>, entity_type:"REQ", project_id:<PROY> })`
4. **ADRs (decisiones vigentes):**
   `entity_search({ query:<tema>, entity_type:"ADR", project_id:<PROY> })`
5. **CMPs afectados:**
   `entity_search({ query:<tema>, entity_type:"CMP", project_id:<PROY> })`
6. **IFs (si tema afecta a comunicación):**
   `entity_search({ query:<tema>, entity_type:"IF", project_id:<PROY> })`
7. **PATs (precedentes):**
   `entity_search({ query:<tema>, entity_type:"PAT", project_id:<PROY> })`
8. **ISSUEs existentes (trabajo previo):**
   `entity_search({ query:<tema>, entity_type:"ISSUE", project_id:<PROY> })`
9. **SLAs (si afecta rendimiento):**
   `entity_query({ entity_type:"SLA", project_id:<PROY> })`
10. **COST (si tiene impacto económico):**
    `entity_query({ entity_type:"COST", project_id:<PROY> })`
11. **GLO:**
    `entity_query({ entity_type:"GLO", project_id:<PROY>, tags_all:["domain-terms"] })`

## Paso 2 — Investigar

Según el tema:

- **Duda técnica**: leer código relevante, verificar contra CMP / IF.
- **Idea nueva**: evaluar viabilidad contra ADR, ROAD, COST.
- **Problema**: reproducir o confirmar, identificar causa raíz, buscar PATs
  similares.
- **Decisión de diseño**: opciones con trade-offs, referenciando ADRs.
- **Optimización**: comparar contra SLA, analizar impacto en costes.

Para investigaciones profundas del codebase, usar Agent con
subagent_type="Explore".

## Paso 3 — Presentar hallazgos

```
## Consultoría: [Título descriptivo]

### Contexto Kvendra
- ROAD relevante: ROAD-<PROY>-<NN> — [impacto]
- ADRs vigentes: ADR-<PROY>-<NN> — [restricciones]
- ISSUEs relacionados: ISSUE-<PROY>-<NN> — [trabajo previo]
- PATs aplicables: PAT-<PROY>-<NN> — [lecciones]
- SLA impactado: SLA-<PROY>-<NN> — [si aplica]
- Coste estimado: [si aplica]

### Análisis
[Evaluación con datos del Kvendra]

### Opciones (si aplica)
| Opción | Descripción | Pros | Contras | Impacto ROAD | Impacto COST |
|--------|-------------|------|---------|--------------|--------------|
| A | ... | ... | ... | Compatible | +$X/mes |
| B | ... | ... | ... | Conflicto con ROAD-001 | Neutral |

### Conclusión
[Recomendación con referencias al Kvendra]

### Siguiente paso recomendado
- [ ] [acción concreta]
```

## Paso 4 — Preguntar al usuario (LISTA CERRADA — 9 opciones)

> "Basado en este análisis, ¿quieres que:
> 1. **Cree un ISSUE** para trabajar en esto (`/to-do create`)
> 2. **Lance pipeline de bug** (`/bug`)
> 3. **Lance pipeline de feature** (`/new-feature`)
> 4. **Cree un REQ formal** (`/requirements-analyst`)
> 5. **Proponga un ROAD item** para el roadmap
> 6. **Siga investigando** un aspecto concreto
> 7. **Guarde los hallazgos** como PAT en el Kvendra
> 8. **Lo implemente yo directamente ahora** (sin abrir ISSUE/pipeline formal — para cambios pequeños y acotados)
> 9. **Lo dejemos aquí** — consulta resuelta"

**IMPORTANTE — Lista cerrada.** Estas 9 opciones son las únicas válidas.
NO añadir variantes propias ni combinar opciones al vuelo. Si ninguna
encaja exactamente con lo que el usuario pide después, re-preguntar cuál
de las 9 prefiere.

## Paso 5 — Ejecutar decisión y persistir

### ISSUE:
```
Skill(skill="kvendra-skills:to-do", args="create <descripción>")
```

### BUG:
```
Skill(skill="kvendra-skills:bug", args="<descripción del bug>")
```

### FEATURE:
```
Skill(skill="kvendra-skills:new-feature", args="<descripción de la feature>")
```

### REQ:
```
Skill(skill="kvendra-skills:requirements-analyst", args="<requisito>")
```

### ROAD item:
Crear ROAD entry directamente en Kvendra:
```
entity_create({
  entity_type: "ROAD",
  project_id: <PROY>,
  title: "ROAD-<PROY>-<auto>: <título>",
  content: <markdown>,
  metadata: { status: "proposed" },
  tags: ["status:proposed"],
  updated_by: "skill:consultancy"
})
```

### Guardar como PAT:
```
entity_create({
  entity_type: "PAT",
  project_id: <PROY>,
  title: "PAT-<PROY>-<auto>: <lección>",
  content: <markdown con lección + cuándo aplicarla + ejemplo>,
  metadata: { category: "lesson-learned", origin: "consultancy" },
  tags: ["category:lesson-learned"],
  updated_by: "skill:consultancy"
})
```

### Investigar más:
Continuar la conversación. Repetir desde Paso 2.

### Implementar directamente (opción 8):

Usa esta ruta SOLO para cambios pequeños y acotados (documentación,
retoques de config, pequeños fixes). Si la propuesta es feature, bug
complejo o toca múltiples componentes, NO uses esta ruta — redirige a
las opciones 2/3 (pipelines) o 1 (ISSUE).

**Protocolo de implementación directa:**

1. **Anunciar alcance** al usuario antes de tocar nada.
2. **Ejecutar los cambios** con las herramientas apropiadas (Edit, Write, Bash).
3. **Persistencia obligatoria al terminar** — NO se puede cerrar esta ruta
   sin al menos UNA de estas tres acciones, en este orden de preferencia:

   a. **Changelog en la REL activa** (si existe):
      Buscar REL: `entity_query({ entity_type:"REL", project_id:<PROY>, tags_any:["status:planning","status:in-progress"] })`.
      `entity_update({ entity_id:"REL-<PROY>-<VER>", content:<actualizado>, change_summary:"<cambio>", trigger:"consultancy", updated_by:"skill:consultancy" })`.
      El server pobla `entity_changelog` automáticamente.

   b. **ISSUE retrospectivo** (`type: task, status: done`):
      `Skill(skill="kvendra-skills:to-do", args="create <descripción> --type=task --status=done")`

   c. **PAT** si reveló una lección útil:
      `entity_create({ entity_type:"PAT", ... })` (ver patrón arriba).

4. **Confirmar al usuario** qué se persistió (mostrar IDs creados/modificados).
   Sin este paso el flujo se considera incompleto.

### Dejarlo:
Antes de cerrar, evaluar si el análisis reveló algo que vale la pena
persistir:
- ¿Patrón? → proponer PAT.
- ¿Problema? → proponer ISSUE.
- ¿Cambio en visión estratégica? → proponer ROAD update.
- ¿Nada nuevo? → cerrar sin persistir.

## Reglas

- **No asumas la acción** — siempre pregunta al usuario qué quiere hacer.
- **Investiga antes de opinar** — lee Kvendra y código antes de recomendar.
- **Referencia el Kvendra** — cada afirmación respaldada por datos
  (ADR, PAT, IF, REQ).
- **Alerta conflictos con ROAD** — si la conclusión contradice el roadmap,
  dilo explícitamente.
- **Presenta impacto en coste** — cuantifica contra COST.
- **Sé honesto sobre incertidumbre**.
- **No sobre-compliques** — si la respuesta es simple, dala directamente.
- **Persiste siempre que haya valor** — un hallazgo no guardado se pierde.
- **Respeta la lista cerrada del Paso 4** — las 9 opciones son las únicas
  válidas. No inventar variantes como "lo implemento directamente sin
  persistir". Si no encaja, re-preguntar cuál prefiere.
- **Nunca cerrar ruta de implementación sin persistencia** — la opción 8
  exige al menos changelog REL, ISSUE retrospectivo o PAT.
