#!/bin/bash
#######################################################
# Script: acr_replicate.sh
# Descripción: Replica imágenes desde un registry público
#              hacia Azure Container Registry (ACR)
# 
# Uso: ./acr_replicate.sh [--dry-run] [--config <file>]
#
# Autor: ACR Migration Tool
# Fecha: 2026-01
#######################################################

set -euo pipefail

#======================================================
# COLORES Y FORMATO
#======================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

#======================================================
# VARIABLES GLOBALES
#======================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEMP_DIR="/tmp/acr_replicate_${TIMESTAMP}"
REPORT_FILE=""
CSV_FILE=""
LOG_FILE=""

# Contadores
TOTAL_IMAGES=0
SUCCESS_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

# Arrays para tracking
declare -a FAILED_IMAGES=()
declare -a SKIPPED_IMAGES=()

#======================================================
# FUNCIONES DE LOGGING
#======================================================
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        DEBUG) [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]] && echo -e "${CYAN}[DEBUG]${NC} ${timestamp} - ${message}" ;;
        INFO)  echo -e "${GREEN}[INFO]${NC}  ${timestamp} - ${message}" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC}  ${timestamp} - ${message}" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} ${timestamp} - ${message}" ;;
    esac
    
    # Escribir a log file si existe
    if [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE}" ]]; then
        echo "[${level}] ${timestamp} - ${message}" >> "${LOG_FILE}"
    fi
}

log_debug() { log DEBUG "$@"; }
log_info()  { log INFO "$@"; }
log_warn()  { log WARN "$@"; }
log_error() { log ERROR "$@"; }

#======================================================
# FUNCIONES DE AYUDA
#======================================================
show_banner() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║           ACR IMAGE REPLICATION TOOL v1.0                  ║"
    echo "║     Migrate images from public registries to ACR          ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_usage() {
    cat << EOF
Uso: $0 [opciones]

Opciones:
    -c, --config <file>    Archivo de configuración (default: config.env)
    -d, --dry-run          Modo simulación, no realiza cambios
    -i, --images <file>    Archivo con lista de imágenes
    -p, --parallel <n>     Número de copias en paralelo
    -m, --method <method>  Método de copia: acr-import|skopeo|oras|docker
    -v, --verbose          Modo verbose (DEBUG)
    -h, --help             Mostrar esta ayuda

Ejemplos:
    $0                                    # Usar config.env
    $0 --dry-run                          # Simular sin copiar
    $0 --images myimages.txt --parallel 8 # Lista personalizada
    $0 --method skopeo                    # Forzar skopeo

EOF
}

#======================================================
# VALIDACIÓN DE PREREQUISITOS
#======================================================
check_prerequisites() {
    log_info "Verificando prerequisitos..."
    
    local missing=()
    
    # Azure CLI
    if ! command -v az &> /dev/null; then
        missing+=("az (Azure CLI)")
    fi
    
    # jq
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    # Verificar herramienta de copia según método
    case "${COPY_METHOD:-acr-import}" in
        skopeo)
            if ! command -v skopeo &> /dev/null; then
                missing+=("skopeo")
            fi
            ;;
        oras)
            if ! command -v oras &> /dev/null; then
                missing+=("oras")
            fi
            ;;
        docker)
            if ! command -v docker &> /dev/null; then
                missing+=("docker")
            fi
            ;;
    esac
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Faltan las siguientes herramientas: ${missing[*]}"
        log_error "Por favor instálalas antes de continuar."
        exit 1
    fi
    
    log_info "✓ Todos los prerequisitos están instalados"
}

check_azure_login() {
    log_info "Verificando autenticación de Azure..."
    
    if ! az account show &> /dev/null; then
        log_error "No estás autenticado en Azure. Ejecuta: az login"
        exit 1
    fi
    
    local current_sub=$(az account show --query name -o tsv)
    log_info "✓ Autenticado en Azure. Subscription: ${current_sub}"
}

check_acr_access() {
    log_info "Verificando acceso al ACR destino: ${DEST_ACR_NAME}..."
    
    if ! az acr show --name "${DEST_ACR_NAME}" &> /dev/null; then
        log_error "No se puede acceder al ACR: ${DEST_ACR_NAME}"
        log_error "Verifica que existe y tienes permisos."
        exit 1
    fi
    
    # Intentar login al ACR
    if ! az acr login --name "${DEST_ACR_NAME}" 2>/dev/null; then
        log_warn "No se pudo hacer login automático al ACR. Intentando con token..."
    fi
    
    log_info "✓ Acceso verificado al ACR: ${DEST_ACR_NAME}"
}

#======================================================
# CARGA DE CONFIGURACIÓN
#======================================================
load_config() {
    local config_file="${1:-${CONFIG_FILE}}"
    
    if [[ -f "${config_file}" ]]; then
        log_info "Cargando configuración desde: ${config_file}"
        # shellcheck source=/dev/null
        source "${config_file}"
    else
        log_warn "Archivo de configuración no encontrado: ${config_file}"
        log_warn "Usando valores por defecto..."
    fi
    
    # Valores por defecto
    SOURCE_REGISTRY="${SOURCE_REGISTRY:-docker.io}"
    SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-library}"
    DEST_ACR_NAME="${DEST_ACR_NAME:-}"
    DEST_ACR_LOGIN_SERVER="${DEST_ACR_LOGIN_SERVER:-${DEST_ACR_NAME}.azurecr.io}"
    DRY_RUN="${DRY_RUN:-false}"
    MAX_PARALLEL="${MAX_PARALLEL:-4}"
    MAX_RETRIES="${MAX_RETRIES:-3}"
    BACKOFF_INITIAL="${BACKOFF_INITIAL:-5}"
    COPY_METHOD="${COPY_METHOD:-acr-import}"
    COPY_ALL_PLATFORMS="${COPY_ALL_PLATFORMS:-true}"
    SKIP_EXISTING="${SKIP_EXISTING:-true}"
    VERIFY_DIGEST="${VERIFY_DIGEST:-true}"
    REPORTS_DIR="${REPORTS_DIR:-./reports}"
    LOG_LEVEL="${LOG_LEVEL:-INFO}"
    REPORT_FORMAT="${REPORT_FORMAT:-both}"
    REQUEST_DELAY="${REQUEST_DELAY:-1}"
    
    # Validar configuración mínima
    if [[ -z "${DEST_ACR_NAME}" ]]; then
        log_error "DEST_ACR_NAME no está configurado"
        exit 1
    fi
}

#======================================================
# INICIALIZACIÓN
#======================================================
initialize() {
    # Crear directorios
    mkdir -p "${TEMP_DIR}"
    mkdir -p "${REPORTS_DIR}"
    
    # Inicializar archivos de reporte
    REPORT_FILE="${REPORTS_DIR}/report_${TIMESTAMP}.md"
    CSV_FILE="${REPORTS_DIR}/report_${TIMESTAMP}.csv"
    LOG_FILE="${REPORTS_DIR}/log_${TIMESTAMP}.log"
    
    touch "${LOG_FILE}"
    
    # Inicializar CSV
    echo "repository,tag,source_digest,dest_digest,status,error,duration_seconds" > "${CSV_FILE}"
    
    # Inicializar Markdown report
    cat > "${REPORT_FILE}" << EOF
# ACR Replication Report

**Fecha:** $(date '+%Y-%m-%d %H:%M:%S')  
**Source Registry:** ${SOURCE_REGISTRY}  
**Source Namespace:** ${SOURCE_NAMESPACE}  
**Destination ACR:** ${DEST_ACR_LOGIN_SERVER}  
**Copy Method:** ${COPY_METHOD}  
**Dry Run:** ${DRY_RUN}  

---

## Resumen

| Métrica | Valor |
|---------|-------|
| Total imágenes | - |
| Exitosas | - |
| Omitidas | - |
| Fallidas | - |

---

## Detalle de Imágenes

| Repositorio | Tag | Digest Origen | Digest Destino | Estado | Duración |
|-------------|-----|---------------|----------------|--------|----------|
EOF

    log_info "Inicializado. Reportes en: ${REPORTS_DIR}"
}

#======================================================
# DESCUBRIMIENTO DE IMÁGENES
#======================================================
load_images_from_file() {
    local images_file="${1:-${SOURCE_IMAGES_FILE:-}}"
    
    if [[ -z "${images_file}" || ! -f "${images_file}" ]]; then
        log_error "Archivo de imágenes no encontrado: ${images_file}"
        return 1
    fi
    
    log_info "Cargando imágenes desde: ${images_file}"
    
    # Leer líneas, ignorar comentarios y líneas vacías
    grep -v '^#' "${images_file}" | grep -v '^$' | while read -r line; do
        echo "${line}"
    done
}

discover_tags_dockerhub() {
    local image="$1"
    local namespace="${SOURCE_NAMESPACE}"
    
    # Docker Hub API v2
    local url="https://hub.docker.com/v2/repositories/${namespace}/${image}/tags?page_size=100"
    
    log_debug "Consultando tags de Docker Hub: ${url}"
    
    local tags=""
    local page=1
    local next_url="${url}"
    
    while [[ -n "${next_url}" && "${next_url}" != "null" ]]; do
        local response
        response=$(curl -s "${next_url}")
        
        local page_tags
        page_tags=$(echo "${response}" | jq -r '.results[].name' 2>/dev/null)
        
        if [[ -n "${page_tags}" ]]; then
            tags="${tags}${page_tags}"$'\n'
        fi
        
        next_url=$(echo "${response}" | jq -r '.next // empty' 2>/dev/null)
        ((page++))
        
        # Rate limit protection
        sleep "${REQUEST_DELAY}"
    done
    
    echo "${tags}" | grep -v '^$' | sort -u
}

discover_tags_generic() {
    local image="$1"
    local registry="${SOURCE_REGISTRY}"
    
    # Usar skopeo para listar tags
    if command -v skopeo &> /dev/null; then
        log_debug "Usando skopeo para listar tags de: ${registry}/${image}"
        skopeo list-tags "docker://${registry}/${image}" 2>/dev/null | jq -r '.Tags[]' 2>/dev/null
    else
        log_warn "skopeo no disponible para descubrir tags de ${registry}"
        return 1
    fi
}

get_source_digest() {
    local full_image="$1"
    
    case "${COPY_METHOD}" in
        skopeo)
            skopeo inspect --raw "docker://${full_image}" 2>/dev/null | sha256sum | awk '{print "sha256:"$1}'
            ;;
        docker)
            docker manifest inspect "${full_image}" 2>/dev/null | sha256sum | awk '{print "sha256:"$1}'
            ;;
        *)
            # Para az acr import, obtener después de copiar
            echo "pending"
            ;;
    esac
}

get_dest_digest() {
    local repo="$1"
    local tag="$2"
    
    az acr repository show-manifests \
        --name "${DEST_ACR_NAME}" \
        --repository "${repo}" \
        --query "[?tags[?contains(@, '${tag}')]].digest | [0]" \
        -o tsv 2>/dev/null || echo ""
}

#======================================================
# FUNCIONES DE COPIA
#======================================================
copy_with_acr_import() {
    local source_image="$1"
    local dest_repo="$2"
    local dest_tag="$3"
    
    local source_full="${SOURCE_REGISTRY}/${source_image}"
    local dest_full="${dest_repo}:${dest_tag}"
    
    log_debug "az acr import: ${source_full} -> ${dest_full}"
    
    local cmd="az acr import --name ${DEST_ACR_NAME} --source ${source_full} --image ${dest_full}"
    
    # Agregar credenciales si existen
    if [[ -n "${SOURCE_USERNAME:-}" && -n "${SOURCE_PASSWORD:-}" ]]; then
        cmd="${cmd} --username ${SOURCE_USERNAME} --password ${SOURCE_PASSWORD}"
    fi
    
    # Forzar si ya existe
    cmd="${cmd} --force"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] ${cmd}"
        return 0
    fi
    
    eval "${cmd}" 2>&1
}

copy_with_skopeo() {
    local source_image="$1"
    local dest_repo="$2"
    local dest_tag="$3"
    
    local source_full="docker://${SOURCE_REGISTRY}/${source_image}"
    local dest_full="docker://${DEST_ACR_LOGIN_SERVER}/${dest_repo}:${dest_tag}"
    
    log_debug "skopeo copy: ${source_full} -> ${dest_full}"
    
    local cmd="skopeo copy"
    
    # Copiar todas las plataformas si está habilitado
    if [[ "${COPY_ALL_PLATFORMS}" == "true" ]]; then
        cmd="${cmd} --all"
    fi
    
    # Agregar credenciales de origen si existen
    if [[ -n "${SOURCE_USERNAME:-}" && -n "${SOURCE_PASSWORD:-}" ]]; then
        cmd="${cmd} --src-creds ${SOURCE_USERNAME}:${SOURCE_PASSWORD}"
    fi
    
    cmd="${cmd} ${source_full} ${dest_full}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] ${cmd}"
        return 0
    fi
    
    eval "${cmd}" 2>&1
}

copy_with_oras() {
    local source_image="$1"
    local dest_repo="$2"
    local dest_tag="$3"
    
    local source_full="${SOURCE_REGISTRY}/${source_image}"
    local dest_full="${DEST_ACR_LOGIN_SERVER}/${dest_repo}:${dest_tag}"
    
    log_debug "oras copy: ${source_full} -> ${dest_full}"
    
    local cmd="oras copy ${source_full} ${dest_full}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] ${cmd}"
        return 0
    fi
    
    eval "${cmd}" 2>&1
}

copy_with_docker() {
    local source_image="$1"
    local dest_repo="$2"
    local dest_tag="$3"
    
    local source_full="${SOURCE_REGISTRY}/${source_image}"
    local dest_full="${DEST_ACR_LOGIN_SERVER}/${dest_repo}:${dest_tag}"
    
    log_debug "docker pull/tag/push: ${source_full} -> ${dest_full}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] docker pull ${source_full} && docker tag ... && docker push ${dest_full}"
        return 0
    fi
    
    docker pull "${source_full}" 2>&1 && \
    docker tag "${source_full}" "${dest_full}" 2>&1 && \
    docker push "${dest_full}" 2>&1
}

copy_image() {
    local source_image="$1"  # formato: repo:tag
    local retry_count=0
    local backoff="${BACKOFF_INITIAL}"
    local start_time=$(date +%s)
    local status="FAILED"
    local error_msg=""
    local source_digest="pending"
    local dest_digest=""
    
    # Parsear imagen y tag
    local repo="${source_image%%:*}"
    local tag="${source_image#*:}"
    [[ "${tag}" == "${repo}" ]] && tag="latest"
    
    # Calcular destino
    local dest_repo="${repo}"
    if [[ -n "${DEST_PREFIX:-}" ]]; then
        dest_repo="${DEST_PREFIX}/${repo}"
    fi
    
    log_info "Copiando: ${SOURCE_REGISTRY}/${source_image} -> ${DEST_ACR_LOGIN_SERVER}/${dest_repo}:${tag}"
    
    # Verificar si ya existe con mismo digest
    if [[ "${SKIP_EXISTING}" == "true" ]]; then
        dest_digest=$(get_dest_digest "${dest_repo}" "${tag}")
        if [[ -n "${dest_digest}" ]]; then
            # TODO: Comparar con digest origen
            log_info "  ⏭ Tag ya existe en destino, omitiendo"
            SKIPPED_IMAGES+=("${source_image}")
            ((SKIPPED_COUNT++))
            record_result "${repo}" "${tag}" "${source_digest}" "${dest_digest}" "SKIPPED" "" "0"
            return 0
        fi
    fi
    
    # Intentar con reintentos
    while [[ ${retry_count} -lt ${MAX_RETRIES} ]]; do
        local copy_output=""
        local copy_result=0
        
        case "${COPY_METHOD}" in
            acr-import)
                copy_output=$(copy_with_acr_import "${source_image}" "${dest_repo}" "${tag}" 2>&1) || copy_result=$?
                ;;
            skopeo)
                copy_output=$(copy_with_skopeo "${source_image}" "${dest_repo}" "${tag}" 2>&1) || copy_result=$?
                ;;
            oras)
                copy_output=$(copy_with_oras "${source_image}" "${dest_repo}" "${tag}" 2>&1) || copy_result=$?
                ;;
            docker)
                copy_output=$(copy_with_docker "${source_image}" "${dest_repo}" "${tag}" 2>&1) || copy_result=$?
                ;;
            *)
                log_error "Método de copia no soportado: ${COPY_METHOD}"
                copy_result=1
                ;;
        esac
        
        if [[ ${copy_result} -eq 0 ]]; then
            status="SUCCESS"
            break
        else
            error_msg="${copy_output}"
            log_warn "  Intento $((retry_count + 1))/${MAX_RETRIES} fallido. Backoff: ${backoff}s"
            log_debug "  Error: ${error_msg}"
            
            ((retry_count++))
            
            if [[ ${retry_count} -lt ${MAX_RETRIES} ]]; then
                sleep "${backoff}"
                backoff=$((backoff * 2))
            fi
        fi
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Obtener digest del destino después de copiar
    if [[ "${status}" == "SUCCESS" && "${VERIFY_DIGEST}" == "true" ]]; then
        dest_digest=$(get_dest_digest "${dest_repo}" "${tag}")
    fi
    
    # Registrar resultado
    if [[ "${status}" == "SUCCESS" ]]; then
        log_info "  ✓ Copiado exitosamente (${duration}s)"
        ((SUCCESS_COUNT++))
    else
        log_error "  ✗ Falló después de ${MAX_RETRIES} intentos: ${error_msg}"
        FAILED_IMAGES+=("${source_image}")
        ((FAILED_COUNT++))
    fi
    
    record_result "${repo}" "${tag}" "${source_digest}" "${dest_digest}" "${status}" "${error_msg}" "${duration}"
}

record_result() {
    local repo="$1"
    local tag="$2"
    local source_digest="$3"
    local dest_digest="$4"
    local status="$5"
    local error="$6"
    local duration="$7"
    
    # CSV
    echo "\"${repo}\",\"${tag}\",\"${source_digest}\",\"${dest_digest}\",\"${status}\",\"${error}\",\"${duration}\"" >> "${CSV_FILE}"
    
    # Markdown
    local status_icon
    case "${status}" in
        SUCCESS) status_icon="✅" ;;
        SKIPPED) status_icon="⏭️" ;;
        FAILED)  status_icon="❌" ;;
    esac
    
    echo "| ${repo} | ${tag} | ${source_digest:0:16}... | ${dest_digest:0:16}... | ${status_icon} ${status} | ${duration}s |" >> "${REPORT_FILE}"
}

#======================================================
# PROCESAMIENTO PARALELO
#======================================================
process_images_parallel() {
    local images_file="$1"
    local parallel_count="${MAX_PARALLEL}"
    
    log_info "Procesando imágenes con paralelismo: ${parallel_count}"
    
    # Usar xargs para paralelismo o proceso secuencial
    if [[ ${parallel_count} -gt 1 ]] && command -v xargs &> /dev/null; then
        export -f copy_image copy_with_acr_import copy_with_skopeo copy_with_oras copy_with_docker
        export -f get_source_digest get_dest_digest record_result
        export -f log log_debug log_info log_warn log_error
        export SOURCE_REGISTRY SOURCE_NAMESPACE DEST_ACR_NAME DEST_ACR_LOGIN_SERVER
        export DRY_RUN MAX_RETRIES BACKOFF_INITIAL COPY_METHOD COPY_ALL_PLATFORMS
        export SKIP_EXISTING VERIFY_DIGEST DEST_PREFIX LOG_LEVEL
        export CSV_FILE REPORT_FILE LOG_FILE
        export RED GREEN YELLOW BLUE CYAN NC BOLD
        
        cat "${images_file}" | xargs -P "${parallel_count}" -I {} bash -c 'copy_image "$@"' _ {}
    else
        while IFS= read -r image; do
            copy_image "${image}"
        done < "${images_file}"
    fi
}

#======================================================
# FINALIZACIÓN Y REPORTE
#======================================================
finalize_report() {
    log_info "Generando reporte final..."
    
    # Actualizar resumen en el reporte markdown
    local temp_report="${REPORT_FILE}.tmp"
    
    sed -e "s/| Total imágenes | - |/| Total imágenes | ${TOTAL_IMAGES} |/" \
        -e "s/| Exitosas | - |/| Exitosas | ${SUCCESS_COUNT} |/" \
        -e "s/| Omitidas | - |/| Omitidas | ${SKIPPED_COUNT} |/" \
        -e "s/| Fallidas | - |/| Fallidas | ${FAILED_COUNT} |/" \
        "${REPORT_FILE}" > "${temp_report}"
    
    mv "${temp_report}" "${REPORT_FILE}"
    
    # Agregar sección de errores si hay fallos
    if [[ ${#FAILED_IMAGES[@]} -gt 0 ]]; then
        cat >> "${REPORT_FILE}" << EOF

---

## Imágenes Fallidas

Las siguientes imágenes no pudieron ser copiadas:

\`\`\`
$(printf '%s\n' "${FAILED_IMAGES[@]}")
\`\`\`

### Sugerencias de Resolución

1. Verificar conectividad al registry origen
2. Verificar credenciales si el registry requiere autenticación
3. Verificar rate limits (especialmente Docker Hub)
4. Reintentar con método alternativo: \`--method skopeo\`

EOF
    fi
    
    # Agregar footer
    cat >> "${REPORT_FILE}" << EOF

---

## Archivos Generados

- Log: \`${LOG_FILE}\`
- CSV: \`${CSV_FILE}\`
- Report: \`${REPORT_FILE}\`

**Generado por ACR Replication Tool v1.0**
EOF

    log_info "Reporte guardado en: ${REPORT_FILE}"
    log_info "CSV guardado en: ${CSV_FILE}"
}

show_summary() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    RESUMEN DE REPLICACIÓN                  ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Total procesadas: ${BOLD}${TOTAL_IMAGES}${NC}"
    echo -e "  ${GREEN}✓ Exitosas:${NC}        ${SUCCESS_COUNT}"
    echo -e "  ${YELLOW}⏭ Omitidas:${NC}        ${SKIPPED_COUNT}"
    echo -e "  ${RED}✗ Fallidas:${NC}        ${FAILED_COUNT}"
    echo ""
    
    if [[ ${FAILED_COUNT} -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}✓ REPLICACIÓN COMPLETADA EXITOSAMENTE${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}⚠ REPLICACIÓN COMPLETADA CON ERRORES${NC}"
        echo -e "  Ver detalles en: ${REPORT_FILE}"
    fi
    echo ""
}

cleanup() {
    log_debug "Limpiando archivos temporales..."
    rm -rf "${TEMP_DIR}"
}

#======================================================
# MAIN
#======================================================
main() {
    local cli_dry_run=""
    local cli_config=""
    local cli_images=""
    local cli_parallel=""
    local cli_method=""
    local cli_verbose=""
    
    # Parsear argumentos
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                cli_config="$2"
                shift 2
                ;;
            -d|--dry-run)
                cli_dry_run="true"
                shift
                ;;
            -i|--images)
                cli_images="$2"
                shift 2
                ;;
            -p|--parallel)
                cli_parallel="$2"
                shift 2
                ;;
            -m|--method)
                cli_method="$2"
                shift 2
                ;;
            -v|--verbose)
                cli_verbose="true"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Opción desconocida: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Mostrar banner
    show_banner
    
    # Cargar configuración
    load_config "${cli_config:-${CONFIG_FILE}}"
    
    # Aplicar overrides de CLI
    [[ -n "${cli_dry_run}" ]] && DRY_RUN="${cli_dry_run}"
    [[ -n "${cli_images}" ]] && SOURCE_IMAGES_FILE="${cli_images}"
    [[ -n "${cli_parallel}" ]] && MAX_PARALLEL="${cli_parallel}"
    [[ -n "${cli_method}" ]] && COPY_METHOD="${cli_method}"
    [[ -n "${cli_verbose}" ]] && LOG_LEVEL="DEBUG"
    
    # Mostrar modo
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${YELLOW}>>> MODO DRY-RUN ACTIVADO - No se realizarán cambios <<<${NC}"
        echo ""
    fi
    
    # Verificaciones
    check_prerequisites
    check_azure_login
    check_acr_access
    
    # Inicializar
    initialize
    
    # Preparar lista de imágenes
    local images_list="${TEMP_DIR}/images.txt"
    
    if [[ -n "${SOURCE_IMAGES_FILE:-}" && -f "${SOURCE_IMAGES_FILE}" ]]; then
        load_images_from_file "${SOURCE_IMAGES_FILE}" > "${images_list}"
    else
        log_error "No se proporcionó archivo de imágenes. Usa -i <archivo>"
        log_info "Ejemplo de archivo de imágenes:"
        echo "  nginx:latest"
        echo "  nginx:1.25"
        echo "  redis:7-alpine"
        exit 1
    fi
    
    # Contar imágenes
    TOTAL_IMAGES=$(wc -l < "${images_list}" | tr -d ' ')
    log_info "Total de imágenes a procesar: ${TOTAL_IMAGES}"
    
    if [[ ${TOTAL_IMAGES} -eq 0 ]]; then
        log_warn "No hay imágenes para procesar"
        exit 0
    fi
    
    # Procesar imágenes
    echo ""
    log_info "Iniciando replicación..."
    echo ""
    
    # Usar procesamiento secuencial para mejor control
    while IFS= read -r image; do
        [[ -z "${image}" ]] && continue
        ((TOTAL_IMAGES++)) || true
        copy_image "${image}"
    done < "${images_list}"
    
    # Recalcular total real
    TOTAL_IMAGES=$((SUCCESS_COUNT + SKIPPED_COUNT + FAILED_COUNT))
    
    # Finalizar
    finalize_report
    show_summary
    cleanup
    
    # Exit code basado en errores
    [[ ${FAILED_COUNT} -eq 0 ]] && exit 0 || exit 1
}

# Trap para limpieza
trap cleanup EXIT

# Ejecutar
main "$@"
