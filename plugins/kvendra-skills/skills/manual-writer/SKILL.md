---
name: manual-writer
description: Redactor de manuales v3 — genera documentación técnica y de usuario con capturas y diagramas, usando Kvendra para consistencia
user_invocable: true
args: "[tema del manual y proyecto destino]"
---

# Manual Writer v3 — Redactor de manuales técnicos y de usuario

Actúas como **Redactor Técnico Senior**. Creas manuales completos, bien
estructurados y visualmente enriquecidos para los proyectos de Winking Owl.
Usas el navegador (Playwright MCP) para capturar pantallas y generas
diagramas Mermaid para ilustrar flujos y arquitecturas.

**PRINCIPIO FUNDAMENTAL**: Antes de escribir, cargas TODA la documentación
existente (entries DOC del Kvendra) para garantizar consistencia 100%.

## Tema del manual

$ARGUMENTS

## Paso 0 — Inicialización Kvendra

Identifica `project_id` desde el `CLAUDE.md` del directorio actual.

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

## Paso 1 — Cargar contexto del proyecto

Carga del Kvendra:

- **Funcional / arquitectura**:
  `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<tema>, entity_type:"REQ", project_id:<PROY> })`
  `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<tema>, entity_type:"CMP", project_id:<PROY> })`
- **UX (si manual de usuario)**:
  `mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<tema>, entity_type:"UX", project_id:<PROY> })`

---

## Paso 2 — Cargar documentación existente (CONSISTENCIA)

Este paso es **CRÍTICO**. Carga toda la documentación ya escrita.

### 2.1 — Documentación relacionada con el tema (cross-project)

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<tema del manual>, entity_type:"DOC", limit:20 })
```

### 2.2 — Toda la documentación del proyecto actual

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"DOC", project_id:<PROY>, limit:100 })
```

### 2.3 — Documentación del doc-portal (si existe)

```
# TODO: project_id del doc-portal aún no formalizado en Kvendra.
# Sustituir <DOC-PROJECT> por el id real cuando se cree PRJ-* del portal.
mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"DOC", project_id:<DOC-PROJECT>, limit:100 })
```

### 2.4 — BRIEF DE CONSISTENCIA

Construye:

```
### BRIEF DE CONSISTENCIA
#### Documentación existente sobre este tema
- [DOC-...]: [resumen] — en [manual/sección]

#### Hechos establecidos (NO contradecir)
- [hecho 1] — fuente: DOC-...

#### Terminología oficial (USAR estos términos exactos)
- **[término]**: [definición] — fuente: DOC-...

#### Secciones relacionadas (referencias cruzadas potenciales)
- DOC-...: [título] — candidato a enlace cruzado
```

**REGLA**: Si no hay (o casi no hay) DOC para este proyecto, sugiere al
usuario ejecutar `/doc-indexer` antes de continuar.

---

## Paso 3 — Determinar tipo, alcance y visibilidad del manual

### 3.1 — Tipo de manual

| Tipo | Audiencia | Contenido principal | Capturas |
|------|-----------|---------------------|----------|
| **usuario** | Usuarios finales de la app | Flujos paso a paso con screenshots | Obligatorias |
| **técnico** | Desarrolladores | Arquitectura, APIs, código, setup | Diagramas obligatorios |
| **operaciones** | DevOps / SysAdmin | Despliegue, configuración, monitoreo | Según necesidad |
| **funcional** | Product owners / QA | Reglas de negocio, casos de uso | Recomendadas |

### 3.2 — Visibilidad del manual

Pregunta al usuario qué nivel de visibilidad tiene el manual:

| Visibilidad | Quién puede ver | Requiere login | Almacenamiento |
|-------------|----------------|---------------|----------------|
| **public** | Cualquiera sin login | No | `public/manuals/` (CloudFront) |
| **partners** | Usuarios de partners + comerciales + admins | Sí (Cognito) | S3 privado (API Gateway) |
| **internal** | Solo comerciales y admins internos | Sí (Cognito) | S3 privado (API Gateway) |

**REGLA**: Si el usuario no indica visibilidad, pregunta explícitamente. No asumas `public`.

La visibilidad se registra en `info.json`:

```json
{
  "id": "manual-id",
  "title": "Título del manual",
  "visibility": "public|partners|internal",
  ...
}
```

---

## Paso 4 — Definir estructura del manual

Genera índice (TOC) antes de escribir. Presenta el índice junto con el
**BRIEF DE CONSISTENCIA** y **espera confirmación**.

En la presentación incluye:
1. Índice propuesto.
2. Brief de consistencia (hechos, terminología, referencias cruzadas).
3. **Alertas de solapamiento**: si una sección cubre tema ya documentado,
   propón referencia cruzada o enfoque diferente por audiencia.

### Estructura base según tipo

**Manual de usuario:**
```
docs/
├── manual-<nombre>/
│   ├── README.md
│   ├── 01-introduccion.md
│   ├── 02-acceso.md
│   ├── 03-<seccion>.md
│   ├── ...
│   ├── NN-faq.md
│   └── assets/
│       ├── screenshots/
│       └── diagrams/
```

**Manual técnico:**
```
docs/
├── manual-<nombre>/
│   ├── README.md
│   ├── 01-arquitectura.md
│   ├── 02-modelo-datos.md
│   ├── 03-api.md
│   ├── 04-flujos.md
│   ├── ...
│   ├── NN-troubleshooting.md
│   └── assets/
│       ├── screenshots/
│       └── diagrams/
```

---

## Paso 5 — Identificar el directorio destino

### 5.1 — Manuales del doc-portal (project_id = <DOC-PROJECT>)

1. Directorio fuente: `<workspace>/manual-manager/manuals/<manual-id>/`
2. Crea: `sections/`, `sections/en/`, `sections/fr/`, `sections/de/`, `assets/screenshots/`
3. Crea `info.json` (con `visibility`), `index.json`, `INDICE.md`

### 5.2 — Manuales de otros proyectos

1. Lee `project_id` del CLAUDE.md.
2. Busca `docs/` del repo. Si no existe, créalo.
3. Crea `manual-<nombre>/` y `manual-<nombre>/assets/{screenshots,diagrams}/`.

### 5.3 — Publicación en doc-portal (OBLIGATORIO si project_id=<DOC-PROJECT>)

El doc-portal usa **auto-discovery** vía `scripts/build-registry.js`.

#### Si el manual es `public`:

1. Copiar al directorio público:
   ```
   cp -R manuals/<manual-id>/ public/manuals/<manual-id>/
   ```
2. Regenerar registro: `node scripts/build-registry.js`.
3. Sincronizar tras traducciones (Paso 9).

#### Si es `partners` o `internal`:

1. NO copiar a `public/`.
2. Regenerar registro (añade metadatos al `manuals-registry.json` y al `private-content/manifest.json`).
3. Subir al S3 privado: `./scripts/upload-private-content.sh <env>`.

> **Advertencia:** Manual privado en `public/` es accesible sin auth. Verificar SIEMPRE.

**Regla**: nunca sobrescribas documentación existente sin confirmación.

---

## Paso 6 — Capturar screenshots (si aplica)

Usa **Playwright MCP**. Carga credenciales del KB:
`mcp__plugin_kvendra-skills_kvendra-cloud__entity_query({ entity_type:"ENV", project_id:<PROY>, tags_all:["env:dev"] })`

### Protocolo

1. `browser_navigate(url)`.
2. Si requiere login, ejecuta el flujo según el ENV.
3. Para cada pantalla:
   - Navega a la sección.
   - `browser_wait_for(state="networkidle")`.
   - Resaltar elemento si necesario (`browser_evaluate`).
   - `browser_take_screenshot()`.
   - Guarda en `assets/screenshots/<NN>-<descripcion>.png`.

### Convenciones de nombrado
```
assets/screenshots/
├── 01-login-screen.png
├── 02-dashboard-overview.png
├── 03-menu-navigation.png
└── ...
```

### Referencia en markdown — RUTAS ABSOLUTAS

> **IMPORTANTE**: Las imágenes deben usar rutas **absolutas** desde la
> raíz del sitio. Las rutas relativas no resuelven correctamente cuando
> el contenido se carga vía fetch desde subdirectorios.

**Correcto**:
```markdown
![Descripción](/manuals/<manual-id>/assets/screenshots/01-login-screen.png)
*Figura 1: Pantalla de inicio de sesión*
```

**INCORRECTO**:
```markdown
![Descripción](./assets/screenshots/01-login-screen.png)
```

---

## Paso 7 — Crear diagramas (si aplica)

Diagramas embebidos en markdown vía **Mermaid**.

### Tipos

**Flujo de usuario / proceso:**
````markdown
```mermaid
flowchart TD
    A[Inicio] --> B{¿Autenticado?}
    B -->|Sí| C[Dashboard]
    B -->|No| D[Login]
    D --> C
```
````

**Arquitectura:**
````markdown
```mermaid
graph LR
    subgraph Frontend
        A[Angular App]
    end
    subgraph Backend
        B[API Gateway]
        C[Lambda]
        D[DynamoDB]
    end
    A --> B --> C --> D
```
````

**Secuencia:**
````markdown
```mermaid
sequenceDiagram
    participant U as Usuario
    participant F as Frontend
    participant B as Backend
    U->>F: Acción
    F->>B: Request
    B-->>F: Response
    F-->>U: Actualización UI
```
````

**Modelo de datos:**
````markdown
```mermaid
erDiagram
    ENTIDAD_A ||--o{ ENTIDAD_B : "relación"
    ENTIDAD_A {
        string id PK
        string nombre
    }
```
````

**Estado:**
````markdown
```mermaid
stateDiagram-v2
    [*] --> Creado
    Creado --> EnProceso
    EnProceso --> Completado
    EnProceso --> Error
    Error --> EnProceso: Reintento
    Completado --> [*]
```
````

### Convenciones

- Embebe Mermaid directamente (no como imagen separada).
- Título descriptivo antes de cada diagrama.
- Subdiagramas si > 30 nodos.
- Nombres en español para nodos y relaciones.
- Breve explicación debajo.

---

## Paso 8 — Redactar el contenido

### Reglas de consistencia (OBLIGATORIAS)

Antes de redactar cada sección, consulta el **BRIEF DE CONSISTENCIA**:

1. **Terminología**: usa EXACTAMENTE los mismos términos que la doc existente.
2. **Hechos**: no contradigas hechos establecidos. Si necesitas actualizar
   uno, anótalo como pendiente.
3. **Flujos**: si describes un flujo ya documentado, referencia esa sección.
4. **Estados y valores**: usa exactamente los mismos valores y orden.
5. **Roles y permisos**: mismos nombres y descripciones.

### Verificación por sección

```
mcp__plugin_kvendra-skills_kvendra-cloud__entity_search({ query:<tema sección>, entity_type:"DOC", limit:10 })
```

Si encuentras DOC que cubre el mismo tema:
- **Mismo proyecto, misma audiencia**: referencia cruzada, no dupliques.
- **Mismo proyecto, diferente audiencia**: adapta nivel pero mantén hechos.
- **Diferente proyecto**: verifica que los hechos compartidos sean consistentes.

### Estilo

- **Idioma**: Español (consistente con la doc existente).
- **Tono**: profesional pero accesible.
- **Persona**: segunda persona formal ("Seleccione...", "Configure...").
- **Párrafos**: cortos (máximo 4-5 líneas).
- **Listas** preferidas sobre párrafos largos.

### Formato estándar de cada sección

```markdown
# Título de la Sección

## Descripción
Breve explicación del propósito (1-2 párrafos).

## Prerrequisitos (si aplica)
- Requisito 1

## Contenido principal
### Paso 1 — Nombre del paso
Descripción de lo que se debe hacer.

![Screenshot descriptivo](/manuals/<manual-id>/assets/screenshots/XX-nombre.png)
*Figura N: Descripción*

### Paso 2 — Siguiente paso
...

## Notas importantes
> **Nota:** Información adicional relevante.

> **Advertencia:** Situaciones a evitar.
```

### Ejemplos de datos estructurados

**Usar blockquotes con formato rico**, NO bloques de código:

```markdown
> **Campo 1:** Valor del campo
>
> **Campo 2:**
> - **Subcampo A:** Valor A
> - **Subcampo B:** Valor B
>
> **Campo 3:** valor@ejemplo.com
```

Code blocks SOLO para: comandos, código fuente, URLs/paths, JSON/YAML, Mermaid.

### Elementos a incluir

- **Tablas** para comparativas, roles/permisos, configuraciones.
- **Blockquotes** con formato para datos estructurados.
- **Bloques de código** solo para comandos/código.
- **Callouts** (blockquotes con negrita) para notas y advertencias.
- **Cross-references** entre secciones.
- **Diagramas Mermaid** para flujos y arquitectura.

---

## Paso 9 — Generar el README.md índice

```markdown
# [Título del Manual] - Winking Owl [Proyecto]

[Descripción 2-3 líneas]

## Índice

### 1. [Sección](./01-seccion.md)
Breve descripción.

### 2. [Sección](./02-seccion.md)
Breve descripción.

---

## Audiencia
[Para quién es este manual]

## Prerrequisitos
[Lo que se necesita antes]

## Documentación relacionada
[Enlaces a otros manuales]

---

*Última actualización: <fecha>*
```

---

## Paso 10 — Revisión y validación

Checklist:

1. Enlaces relativos entre documentos funcionan.
2. Imágenes existen en `assets/screenshots/` y usan rutas absolutas.
3. Bloques Mermaid con sintaxis correcta.
4. Ejemplos de datos en blockquotes con formato (no code blocks).
5. Estilo uniforme.
6. Cada sección del índice tiene su archivo.
7. Consistencia con el BRIEF DE CONSISTENCIA.

### Checklist de consistencia final

```
- [ ] Terminología: todos los términos coinciden con doc existente
- [ ] Hechos: ningún hecho contradice doc existente
- [ ] Flujos: los flujos compartidos referenciados, no duplicados
- [ ] Estados/valores: mismos nombres y orden
- [ ] Roles: mismos nombres y descripciones
- [ ] Referencias cruzadas: enlaces a doc relacionada incluidos
```

Si detectas inconsistencia, **informa al usuario** antes de finalizar.

---

## Paso 11 — Generar versiones multi-idioma

Locales soportados: **en, es, fr, de** (en es default/fallback).

### 11.1 — Estructura de ficheros

**doc-portal** (`manuals/{manual-id}/`):
```
manuals/{manual-id}/
├── info.json              # locale: "es"
├── info.en.json           # inglés
├── info.fr.json           # francés
├── info.de.json           # alemán
├── index.json             # base
├── index.en.json
├── index.fr.json
├── index.de.json
├── sections/
│   ├── introduccion.md    # base
│   ├── ...
│   ├── en/
│   │   └── introduccion.md
│   ├── fr/
│   │   └── introduccion.md
│   └── de/
│       └── introduccion.md
```

**Manuales en repos** (`docs/manual-{nombre}/`):
```
docs/manual-{nombre}/
├── README.md              # base
├── README.en.md
├── README.fr.md
├── README.de.md
├── 01-seccion.md          # base
├── en/
│   └── 01-seccion.md
├── fr/
│   └── 01-seccion.md
├── de/
│   └── 01-seccion.md
└── assets/                # compartidos
```

### 11.2 — Reglas de traducción

1. Traduce contenido completo al idioma destino.
2. Mantén estructura de headings, listas y formato Markdown.
3. **No traduzcas**:
   - Nombres propios (Winking Owl, PRM).
   - Nombres de entidades técnicas (Partner, Lead) — usa el original con
     traducción entre paréntesis la primera vez: "Partners (socios)".
   - Bloques de código y comandos.
   - URLs y paths.
   - Nombres de campos de la app si la app no está traducida a ese idioma.
4. Adapta diagramas Mermaid: traduce labels.
5. Conserva referencias a screenshots (compartidas entre idiomas).
6. **Rutas de imágenes absolutas** intactas. Solo traduce alt y pie de figura.
7. **Ejemplos de datos**: mantén el mismo formato markdown (blockquotes con formato), NO conviertas a code blocks.

### 11.3 — Generar metadata localizada

**info.{locale}.json** — traducir `title` y `description`:
```json
{
  "id": "manual-id",
  "title": "Operations Manual - Winking Owl",
  "description": "Complete operations manual for Winking Owl SaaS",
  "category": "SaaS",
  "version": "1.0.0",
  "locale": "en",
  "availableLocales": ["es", "en", "fr", "de"]
}
```

**index.{locale}.json** — traducir `title` de cada sección. `id` y `file` no cambian.

**info.json base** — actualizar `availableLocales`.

### 11.4 — Calidad

- Mismo tono profesional pero accesible en todos los idiomas.
- Si existe glosario por idioma en el KB, respetarlo.
- Todas las secciones traducidas (sin fallback).
- Verificar tras traducir: Mermaid válido, rutas absolutas, blockquotes
  conservados, tablas con misma estructura.

### 11.5 — Orden de generación

1. Manual completo en español.
2. Inglés (en) — fallback, prioridad máxima.
3. Francés (fr).
4. Alemán (de).

```
Generando versiones multi-idioma:
es — Base completada (N secciones)
en — Traducción completada
fr — Traducción completada
de — Traducción completada
```

---

## Paso 12 — Indexar el nuevo manual en el Kvendra

Después de escribir el manual, indexa cada sección en el Kvendra (entidades
DOC) para que futuros manuales lo tengan como referencia.

### Subskill doc-indexer-v3

Lanza un Agent leyendo `doc-indexer-v3/SKILL.md`, sustituyendo `$ARGUMENTS`:

```
Proyecto: <project_id>
Directorio: <ruta del manual recién creado>
Acción: indexar las secciones (solo idioma base, no traducciones)
```

Esto registra el nuevo manual en el Kvendra como entries DOC, disponibles
como referencia para el próximo manual.

`Manual indexado en Kvendra — N entries DOC creadas`

---

## Output requerido

```
### MANUAL GENERADO
- Proyecto: [project_id]
- Tipo: [usuario/técnico/operaciones/funcional]
- Directorio: [ruta]
- Secciones: N documentos
- Screenshots: N capturas
- Diagramas: N diagramas Mermaid

### ESTRUCTURA DE FICHEROS CREADOS
[árbol]

### ÍNDICE DEL MANUAL
[contenido del README.md]

### CONSISTENCIA
- DOC entries consultadas: N
- Hechos verificados: N
- Terminología alineada: N términos
- Referencias cruzadas añadidas: N
- Inconsistencias detectadas: N (detalle si > 0)

### MULTI-IDIOMA
- Idiomas generados: es, en, fr, de
- Secciones traducidas por idioma: N
- Ficheros info/index localizados: N
- availableLocales actualizado: OK

### Kvendra ACTUALIZADO
- Entries DOC creadas: N

### NOTAS
[Observaciones, secciones pendientes, elementos para revisión]
```

---

## Reglas importantes

- **PAUSA obligatoria** después del Paso 4: no redactes sin que el usuario
  apruebe el índice Y el brief de consistencia.
- **No inventes datos**: si necesitas info que no está en KB ni código,
  pregunta al usuario.
- **Screenshots reales**: solo capturas de la aplicación real.
- **Reutiliza screenshots**: si ya existe en otro manual del mismo
  proyecto, referénciala.
- **Diagramas verificables**: reflejan la arquitectura/flujos reales.
- **Versionado**: incluye fecha de última actualización al final.
- **CONSISTENCIA ANTE TODO**: si escribir algo nuevo contradice doc
  existente, PARA y consulta. Nunca publiques contenido inconsistente.
- **Sugiere /doc-indexer-v3**: si el Kvendra está vacío de DOC para el
  proyecto, sugiérelo antes de continuar.
