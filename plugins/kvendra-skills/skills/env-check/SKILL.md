---
name: env-check
description: Verifica que el entorno está correctamente configurado — MCP conectado, las 14 Kvendra MCP tools, skills v3 disponibles, CLAUDE.md con Project Identity, Kvendra accesible
user_invocable: true
---

# Env Check — Verificar y reparar entorno (Kvendra)

Verificas que todo está configurado correctamente para usar los skills v3
y el Kvendra centralizado. Si algo falta, lo reparas o guías al usuario.

## Verificaciones (en orden)

### 1. MCP Kvendra entities conectado

```bash
claude mcp list 2>&1 | grep kvendra
```

**Si no existe:** ejecutar `/setup <email>` primero.

**Si existe pero no conecta:**
- Credenciales correctas.
- Servicio disponible: `curl -s https://mbk2kz1rz7.execute-api.eu-west-1.amazonaws.com/health`.
- Usuario Cognito CONFIRMED.

### 2. Las 12 tools `kvendra MCP tools` disponibles

Lista las tools del MCP kvendra. Deben aparecer las 14:

- `entity_create`
- `entity_update`
- `entity_get`
- `entity_query`
- `entity_search`
- `entity_archive`
- `check_duplicates`
- `entity_related`
- `txn_create`
- `txn_activate`
- `txn_cancel`
- `txn_check_interrupted`

Si falta alguna, el MCP stdio binario está desactualizado. Recompilar
(`reinstalar el plugin kvendra-skills via `/plugin install kvendra-skills``) y reiniciar Claude
Code.

### 3. Kvendra accesible — test real

Ejecutar un read real:

```
entity_query({ entity_type:"PRJ", limit: 5 })
```

**Si funciona:** mostrar los proyectos.
**Si falla:** MCP registrado pero no funciona — revisar credenciales/conexión.

### 4. CLAUDE.md tiene Project Identity

Leer el CLAUDE.md del directorio actual (si existe).

Verificar bloque:
```markdown
## Project Identity
- **project_id:** <valor>
- **project_name:** <valor>
```

**Si no tiene:**
- Skills v3 no funcionarán sin él.
- Sugerir `/onboard-project <nombre>` o añadirlo manual.

**Si tiene:**
- `entity_get({ entity_id:"PRJ-<valor>" })`.
- Si NOT_FOUND → proyecto no en Kvendra, sugerir `/onboard-project`.

### 5. Skills v3 disponibles

Verificar que están accesibles. Mínimos:
- `/analyzer`
- `/implementer`
- `/updater`
- `/bug`
- `/new-feature`
- `/consultancy`

Localizaciones posibles:
- `~/.claude/plugins/marketplaces/kvendra-marketplace/plugins/kvendra-skills/skills/`
- Org-level (subidos por admin).
- `.claude/skills/` del proyecto.

**Si no hay skills:** pedir al admin que los suba o instalar localmente.

### 6. Conectividad al conector de organización (claude.ai web)

Si el usuario también usa Claude.ai web, verificar que el conector está
disponible (no se puede verificar desde CLI — informar al usuario que vaya
a Settings > Connectors).

## Output requerido

```
## Estado del entorno

| Componente | Estado | Detalle |
|------------|--------|---------|
| MCP Kvendra entities | OK/FAIL | Conectado / No configurado / Error |
| 14 Kvendra MCP tools | OK/FAIL | N/12 disponibles |
| Kvendra accesible | OK/FAIL | N proyectos / Error |
| CLAUDE.md | OK/FAIL | project_id: X / Sin Project Identity / Sin CLAUDE.md |
| Proyecto en Kvendra | OK/FAIL | PRJ-<X> existe / no encontrado |
| Skills v3 | OK/FAIL | N skills disponibles |

### Problemas detectados
- [lista]

### Acciones recomendadas
- `/setup <email>` — si falta MCP
- `/onboard-project <nombre>` — si falta Project Identity o PRJ en KB
- Recompilar MCP stdio — si faltan tools kvendra MCP tools
- Contactar al admin — si faltan skills org-level
```

## Reglas

- **No modifiques nada sin preguntar** — solo diagnostica e informa.
- **Si todo OK**, di: "Entorno OK — listo para usar /analyzer, /bug, /new-feature, etc."
- **Sé específico** en los errores — no digas "algo falló", di qué falló y cómo arreglarlo.
