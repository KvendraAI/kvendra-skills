---
name: doc-indexer
description: Indexador de documentación v3 — lee manuales existentes y crea entries DOC en el Kvendra para garantizar consistencia
user_invocable: false
args: "[proyecto y directorio de docs a indexar]"
---

# Doc Indexer v3 — Indexador de documentación existente

Actúas como **Archivista de Documentación**. Lees todos los manuales
existentes de un proyecto y creas/actualizas entries DOC en el Kvendra que
resuman qué dice cada sección, qué hechos afirma, qué terminología usa y
dónde está el fichero original. Esto permite a `manual-writer` consultar
la documentación previa antes de escribir algo nuevo.

## Objetivo

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

## Paso 1 — Localizar manuales existentes

Busca:
1. `docs/` en la raíz del proyecto.
2. Subdirectorios `manual-*` dentro de `docs/`.
3. Manuales en el doc-portal (`manual-manager/manuals/`) si aplica.

Si el usuario especifica directorio, úsalo directamente.

Lista los `.md` por nombre. Informa total y pide confirmación al usuario.

## Paso 2 — Leer y analizar cada sección

Para cada `.md`:
1. **Read** completo.
2. Extraer:
   - **Resumen**: 2-3 frases.
   - **Hechos clave**: afirmaciones concretas (entidades, flujos, estados, roles, URLs, configs, reglas).
   - **Terminología**: términos específicos con definición tal como se usan.
   - **Referencias cruzadas**: menciones a otros manuales/secciones.
   - **Audiencia**: usuario / desarrollador / operaciones / funcional.

## Paso 3 — Verificar entries existentes

Antes de crear: `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<título sección>, entity_type:"DOC", project_id:<PROY>, limit:5 })`.

Si encuentras una DOC con el mismo `file_path` en metadata → `entity_update`. Si no, `entity_create`.

## Paso 4 — Crear/actualizar entries DOC

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_create({
  entity_type: "DOC",
  project_id: <PROY>,
  title: "DOC-<manual_id>-<NN>: <título sección>",
  content: <ver formato abajo>,
  metadata: {
    manual_id: "<manual-id>",
    section_number: "<NN>",
    file_path: "<ruta RELATIVA al proyecto>",
    audience: "<usuario|técnico|operaciones|funcional>",
    last_indexed: "<fecha>"
  },
  tags: ["<tipo-manual>", "<tema>", "<audiencia>"],
  updated_by: "skill:doc-indexer"
})
```

(DOC en Kvendra NO admite relations — `relations=no` en ENTITY_CONFIG. La
trazabilidad cruzada va en `metadata.crossrefs` o tags.)

### Formato del content

```markdown
## Manual: <nombre>
## Sección: <título>
## Audiencia: <audiencia>
## Fichero: <ruta relativa>

### Resumen
<2-3 frases>

### Hechos clave
- <hecho 1>
- <hecho 2>

### Terminología
- **<término>**: <definición>

### Referencias cruzadas
- Relacionado con: <secciones>
- Depende de: <prerrequisitos>
```

### Tags

| Tag | Cuándo |
|-----|--------|
| `manual-usuario` | Manual usuarios finales |
| `manual-tecnico` | Devs |
| `manual-operaciones` | DevOps |
| `manual-funcional` | PO/QA |
| `<tema>` | Tema principal |
| `<audiencia>` | Audiencia |

## Paso 5 — Informe de consistencia

1. Términos con definiciones divergentes.
2. Hechos potencialmente contradictorios.
3. Lagunas detectadas.
4. Duplicaciones.

## Output

```
### DOCUMENTACIÓN INDEXADA
- Proyecto: <project_id>
- Manuales procesados: N
- Secciones indexadas: N (nuevas: X, actualizadas: Y)
- Entries DOC creadas en Kvendra: N

### MANUALES PROCESADOS
| Manual | Tipo | Secciones | Tags |
|--------|------|-----------|------|

### ANÁLISIS DE CONSISTENCIA
#### Términos divergentes
- ...
#### Hechos contradictorios
- ...
#### Lagunas
- ...
#### Duplicaciones
- ...

### PRÓXIMOS PASOS RECOMENDADOS
- ...
```

## Reglas

- **Lee el contenido real** — no supongas qué dice un documento.
- **No modifiques los manuales** — solo creas DOC entries.
- **Sé conservador con los hechos clave** — solo afirmaciones verificables.
- **Granularidad por sección** — una entry DOC por sección.
- **Idempotente** — actualiza si ya existe (mismo file_path).
- **NUNCA paths absolutos** — siempre relativos al repo.
