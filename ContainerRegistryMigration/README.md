# ACR Image Replication - Plan de Migración

## Objetivo
Replicar todas las imágenes y tags desde un registry público (Docker Hub, GHCR, Quay, Harbor) hacia Azure Container Registry (ACR) privado.

---

## 1. Arquitectura y Enfoques

### Opción A: `az acr import` (Recomendado para Azure)

```bash
az acr import --name <dest-acr> --source docker.io/library/nginx:latest
```

| Pros | Contras |
|------|---------|
| ✅ Nativo de Azure, sin cliente local | ❌ No enumera repos/tags automáticamente |
| ✅ Soporta autenticación integrada | ❌ Requiere conocer imagen+tag de antemano |
| ✅ Rápido (server-side copy cuando es posible) | ❌ Rate limits de Docker Hub aplican |
| ✅ Preserva manifest lists (multi-arch) | ❌ No soporta todos los registries |
| ✅ Idempotente por defecto | |

**Mejor para:** Copias puntuales o listas conocidas de imágenes.

---

### Opción B: `oras` (OCI Artifacts)

```bash
oras copy docker.io/library/nginx:latest miacr.azurecr.io/nginx:latest
```

| Pros | Contras |
|------|---------|
| ✅ Estándar OCI, soporta artifacts | ❌ Requiere instalación local |
| ✅ Preserva digests y manifests | ❌ No enumera repos automáticamente |
| ✅ Soporta autenticación moderna | ❌ Menos maduro que skopeo |

**Mejor para:** OCI artifacts (Helm charts, WASM, etc.) y registries modernos.

---

### Opción C: `skopeo copy` (⭐ Recomendado para migración masiva)

```bash
skopeo copy --all docker://docker.io/nginx:latest docker://miacr.azurecr.io/nginx:latest
```

| Pros | Contras |
|------|---------|
| ✅ No requiere Docker daemon | ❌ Requiere instalación |
| ✅ `--all` copia todas las arquitecturas | ❌ No enumera repos de Docker Hub |
| ✅ Preserva digests exactos | |
| ✅ Soporta autenticación flexible | |
| ✅ Dry-run nativo | |
| ✅ Eficiente (no extrae capas localmente) | |

**Mejor para:** Migración masiva de imágenes multi-arch.

---

### Opción D: `docker pull/tag/push` (Fallback)

```bash
docker pull nginx:latest
docker tag nginx:latest miacr.azurecr.io/nginx:latest
docker push miacr.azurecr.io/nginx:latest
```

| Pros | Contras |
|------|---------|
| ✅ Universal, siempre disponible | ❌ Muy lento (descarga local) |
| ✅ Familiar para todos | ❌ No preserva multi-arch por defecto |
| | ❌ Consume disco local |
| | ❌ No idempotente |

**Mejor para:** Fallback cuando otras opciones fallan.

---

## 2. Recomendación Final

| Escenario | Herramienta Recomendada |
|-----------|------------------------|
| Imágenes conocidas desde Docker Hub/GHCR | `az acr import` |
| Migración masiva con lista de tags | `skopeo copy --all` |
| OCI artifacts (Helm, WASM) | `oras copy` |
| Debugging o casos especiales | `docker pull/tag/push` |

### Estrategia Híbrida (Implementada)

1. **Primario:** `az acr import` (más rápido, server-side)
2. **Fallback:** `skopeo copy` (cuando import falla)
3. **Último recurso:** `docker pull/tag/push`

---

## 3. Archivos del Proyecto

| Archivo | Descripción |
|---------|-------------|
| `config.env` | Variables de configuración |
| `acr_replicate.sh` | Script principal de replicación |
| `discover_images.sh` | Descubrimiento de repos y tags |
| `validate_replication.sh` | Validación post-migración |
| `reports/` | Directorio de reportes generados |

---

## 4. Ejecución Rápida

```bash
# 1. Configurar variables
cp config.env.example config.env
vim config.env

# 2. Login a Azure
az login
az acr login --name <tu-acr>

# 3. Ejecutar en modo dry-run
./acr_replicate.sh --dry-run

# 4. Ejecutar migración real
./acr_replicate.sh

# 5. Validar
./validate_replication.sh
```

---

## 5. Riesgos y Mitigaciones

| Riesgo | Mitigación |
|--------|------------|
| **Rate limits Docker Hub** | Autenticación + backoff exponencial + caché |
| **Imágenes muy grandes** | Paralelismo controlado, reintentos |
| **Tags mutables (latest)** | Comparar digest antes de copiar |
| **Multi-arch images** | Usar `--all` en skopeo o import nativo |
| **Credenciales expuestas** | Variables de entorno + Key Vault |
| **Falta de permisos** | Validar acceso antes de iniciar |

---

## 6. Prerequisitos

```bash
# Azure CLI
az version

# Skopeo (recomendado)
brew install skopeo  # macOS
# apt-get install skopeo  # Ubuntu/Debian

# ORAS (opcional)
brew install oras

# jq (requerido)
brew install jq
```
