# ACR Replication Report (Ejemplo)

**Fecha:** 2026-01-29 10:30:45  
**Source Registry:** docker.io  
**Source Namespace:** library  
**Destination ACR:** miacrprivado.azurecr.io  
**Copy Method:** acr-import  
**Dry Run:** false  

---

## Resumen

| Métrica | Valor |
|---------|-------|
| Total imágenes | 9 |
| Exitosas | 7 |
| Omitidas | 1 |
| Fallidas | 1 |

---

## Detalle de Imágenes

| Repositorio | Tag | Digest Origen | Digest Destino | Estado | Duración |
|-------------|-----|---------------|----------------|--------|----------|
| nginx | latest | sha256:a8b2f6ce... | sha256:a8b2f6ce... | ✅ SUCCESS | 12s |
| nginx | 1.25-alpine | sha256:3b4c5d6e... | sha256:3b4c5d6e... | ✅ SUCCESS | 8s |
| nginx | 1.24 | sha256:7f8g9h0i... | sha256:7f8g9h0i... | ✅ SUCCESS | 10s |
| redis | 7-alpine | sha256:1a2b3c4d... | sha256:1a2b3c4d... | ✅ SUCCESS | 6s |
| redis | 7.2 | sha256:5e6f7g8h... | sha256:5e6f7g8h... | ✅ SUCCESS | 7s |
| redis | latest | sha256:9i0j1k2l... | sha256:9i0j1k2l... | ⏭️ SKIPPED | 0s |
| postgres | 16-alpine | sha256:3m4n5o6p... | sha256:3m4n5o6p... | ✅ SUCCESS | 15s |
| postgres | 15 | sha256:7q8r9s0t... | sha256:7q8r9s0t... | ✅ SUCCESS | 14s |
| postgres | 14 | pending... | - | ❌ FAILED | 45s |

---

## Imágenes Fallidas

Las siguientes imágenes no pudieron ser copiadas:

```
postgres:14
```

### Errores Detallados

| Imagen | Error | Sugerencia |
|--------|-------|------------|
| postgres:14 | Rate limit exceeded (429) | Reintentar después de 1 hora o autenticar con Docker Hub |

### Sugerencias de Resolución

1. Verificar conectividad al registry origen
2. Verificar credenciales si el registry requiere autenticación
3. Verificar rate limits (especialmente Docker Hub)
4. Reintentar con método alternativo: `--method skopeo`

---

## Comandos de Verificación

```bash
# Listar todos los repositorios en el ACR
az acr repository list --name miacrprivado -o table

# Ver tags de un repositorio específico
az acr repository show-tags --name miacrprivado --repository nginx -o table

# Ver manifest/digest de una imagen
az acr repository show-manifests --name miacrprivado --repository nginx --query "[?tags[?contains(@, 'latest')]]"

# Inspeccionar imagen con skopeo
skopeo inspect docker://miacrprivado.azurecr.io/nginx:latest
```

---

## Estadísticas de Ejecución

| Métrica | Valor |
|---------|-------|
| Tiempo total | 1m 57s |
| Promedio por imagen | 13s |
| Datos transferidos | ~2.3 GB |
| Reintentos realizados | 3 |

---

## Archivos Generados

- Log: `./reports/log_20260129_103045.log`
- CSV: `./reports/report_20260129_103045.csv`
- Report: `./reports/report_20260129_103045.md`

**Generado por ACR Replication Tool v1.0**
