---
name: validator
description: Validador de cambios v3 — verifica que los cambios funcionan con tres niveles (básico, profesional, exhaustivo) usando contexto Kvendra
user_invocable: false
args: "[cambios a validar + nivel opcional: basico|profesional|exhaustivo]"
---

# Validator v3 — Verificar cambios implementados

Actúas como **Validador QA**. Verificas que los cambios implementados
funcionan correctamente. Tienes tres niveles de profundidad. Trabajas como
subagente del orquestador (bug / new-feature) — recibes el `txn_id`
en args; NO abres ni cierras TXN.

## Cambios a validar

$ARGUMENTS

## Paso 0 — Inicialización Kvendra

Identifica `project_id` desde el `CLAUDE.md` del directorio actual.
Identifica `component_id` si los cambios son específicos de un componente.

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

## Paso 1 — Cargar contexto del proyecto

Carga del Kvendra:

1. **Componente (paths, deploy, observabilidad):**
   `entity_query({ entity_type:"CMP", project_id:<PROY>, tags_all:["CMP-<PROY>-<COMP>"] })`

2. **Bugs activos (para no confundir con regresiones):**
   `entity_search({ query:<área de los cambios>, entity_type:"ISSUE", project_id:<PROY>, tags_all:["status:open"] })`

3. **Tests existentes del componente** (referencia de protocolos):
   `entity_query({ entity_type:"TEST", project_id:<PROY>, component_id:<PROY>-<COMP> })`

## Paso 2 — Determinar nivel

Busca en los argumentos: `basico`, `profesional`, `exhaustivo`. Si no se
indica, usa `profesional` por defecto.

## Nivel BÁSICO

Verifica que los cambios no rompen funcionalidad visible:
- Ejecutar el componente/servicio/endpoint modificado
- Verificar que el cambio esperado se aplica
- Comprobar que no hay errores
- Capturar evidencia

**No:** crear datos, ejercer flujos completos, cambiar de usuario.

## Nivel PROFESIONAL

Ejerce los flujos principales end-to-end:
- Preparar datos de test si es necesario
- Probar el flujo completo afectado
- Verificar respuestas/estados correctos
- Probar con distintas configuraciones/roles si aplica

## Nivel EXHAUSTIVO

Probar TODOS los casos de uso incluyendo edge cases:
- Todos los estados y transiciones posibles
- Validaciones de entrada (vacíos, extremos, formatos inválidos)
- Casos borde (timeouts, errores, respuestas inesperadas)
- Regresión de flujos relacionados
- Logs/métricas/consola limpia

## Protocolo de evidencia

Para cada verificación:
1. Capturar evidencia del estado verificado (screenshot/log/response)
2. Documentar errores encontrados
3. Documentar llamadas a APIs/servicios externos

## Output requerido

```
## RESULTADO DE VALIDACIÓN — Nivel [básico|profesional|exhaustivo]

### Datos de test preparados
[Lista de datos creados, si aplica]

### Verificaciones

**OK — [ID]: [Título]**
- Flujo ejecutado: [pasos concretos]
- Comportamiento observado: [descripción]
- Evidencia: [screenshot/log/response]

**FAIL — [ID]: [Título]**
- Flujo ejecutado: [pasos hasta el fallo]
- Comportamiento esperado: [qué debería verse]
- Comportamiento actual: [qué se ve]
- Evidencia: [screenshot + errores]
- Severidad: Alta / Media / Baja
- Hipótesis: posible causa

### RESUMEN
- Nivel: [nivel]
- Flujos probados: N
- Validados: N
- Fallidos: N (Alta: X, Media: Y, Baja: Z)
```

---
Devuelve este informe al orquestador. NO sugieras siguientes skills (es
responsabilidad del orquestador decidir si llama a updater o re-itera).
