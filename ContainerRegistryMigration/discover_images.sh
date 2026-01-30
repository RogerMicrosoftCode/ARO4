#!/bin/bash
#######################################################
# Script: discover_images.sh
# Descripción: Descubre repositorios y tags de un registry
#              para generar lista de imágenes a replicar
#
# Uso: ./discover_images.sh --registry docker.io --namespace library
#######################################################

set -euo pipefail

#======================================================
# COLORES
#======================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#======================================================
# CONFIGURACIÓN
#======================================================
REGISTRY=""
NAMESPACE=""
OUTPUT_FILE="discovered_images.txt"
MAX_TAGS=50
FILTER_TAGS=""
EXCLUDE_PATTERN="alpha|beta|rc|dev|test|sha-"

#======================================================
# FUNCIONES
#======================================================
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

show_usage() {
    cat << EOF
Uso: $0 [opciones]

Opciones:
    -r, --registry <url>      Registry origen (docker.io, ghcr.io, quay.io)
    -n, --namespace <name>    Namespace/organización
    -o, --output <file>       Archivo de salida (default: discovered_images.txt)
    -t, --max-tags <n>        Máximo de tags por imagen (default: 50)
    -f, --filter <pattern>    Filtrar tags por patrón regex
    -e, --exclude <pattern>   Excluir tags por patrón regex
    -h, --help                Mostrar esta ayuda

Ejemplos:
    $0 -r docker.io -n library -o images.txt
    $0 -r ghcr.io -n microsoft -t 10
    $0 -r quay.io -n coreos --filter "^v[0-9]"

EOF
}

discover_dockerhub_repos() {
    local namespace="$1"
    log_info "Descubriendo repositorios en Docker Hub: ${namespace}..."
    
    # Docker Hub API
    local url="https://hub.docker.com/v2/repositories/${namespace}/?page_size=100"
    local repos=""
    
    while [[ -n "${url}" && "${url}" != "null" ]]; do
        local response
        response=$(curl -s "${url}" 2>/dev/null)
        
        local page_repos
        page_repos=$(echo "${response}" | jq -r '.results[].name' 2>/dev/null)
        
        if [[ -n "${page_repos}" ]]; then
            repos="${repos}${page_repos}"$'\n'
        fi
        
        url=$(echo "${response}" | jq -r '.next // empty' 2>/dev/null)
        sleep 1
    done
    
    echo "${repos}" | grep -v '^$' | sort -u
}

discover_tags_dockerhub() {
    local namespace="$1"
    local image="$2"
    
    local url="https://hub.docker.com/v2/repositories/${namespace}/${image}/tags?page_size=100"
    local tags=""
    local count=0
    
    while [[ -n "${url}" && "${url}" != "null" && ${count} -lt ${MAX_TAGS} ]]; do
        local response
        response=$(curl -s "${url}" 2>/dev/null)
        
        local page_tags
        page_tags=$(echo "${response}" | jq -r '.results[].name' 2>/dev/null)
        
        if [[ -n "${page_tags}" ]]; then
            while IFS= read -r tag; do
                # Aplicar filtros
                if [[ -n "${EXCLUDE_PATTERN}" && "${tag}" =~ ${EXCLUDE_PATTERN} ]]; then
                    continue
                fi
                if [[ -n "${FILTER_TAGS}" && ! "${tag}" =~ ${FILTER_TAGS} ]]; then
                    continue
                fi
                
                tags="${tags}${tag}"$'\n'
                ((count++))
                
                if [[ ${count} -ge ${MAX_TAGS} ]]; then
                    break
                fi
            done <<< "${page_tags}"
        fi
        
        url=$(echo "${response}" | jq -r '.next // empty' 2>/dev/null)
        sleep 0.5
    done
    
    echo "${tags}" | grep -v '^$'
}

discover_tags_skopeo() {
    local registry="$1"
    local image="$2"
    
    if ! command -v skopeo &> /dev/null; then
        log_error "skopeo no está instalado"
        return 1
    fi
    
    local full_image="${registry}/${image}"
    log_info "Usando skopeo para: ${full_image}"
    
    skopeo list-tags "docker://${full_image}" 2>/dev/null | \
        jq -r '.Tags[]' 2>/dev/null | \
        head -n "${MAX_TAGS}"
}

discover_ghcr() {
    local namespace="$1"
    log_warn "GHCR requiere token de autenticación para listar paquetes"
    log_info "Usa: gh api /users/${namespace}/packages?package_type=container"
    
    if command -v gh &> /dev/null; then
        gh api "/users/${namespace}/packages?package_type=container" 2>/dev/null | \
            jq -r '.[].name' 2>/dev/null
    fi
}

#======================================================
# MAIN
#======================================================
main() {
    # Parsear argumentos
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--registry) REGISTRY="$2"; shift 2 ;;
            -n|--namespace) NAMESPACE="$2"; shift 2 ;;
            -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
            -t|--max-tags) MAX_TAGS="$2"; shift 2 ;;
            -f|--filter) FILTER_TAGS="$2"; shift 2 ;;
            -e|--exclude) EXCLUDE_PATTERN="$2"; shift 2 ;;
            -h|--help) show_usage; exit 0 ;;
            *) shift ;;
        esac
    done
    
    if [[ -z "${REGISTRY}" || -z "${NAMESPACE}" ]]; then
        log_error "Se requiere --registry y --namespace"
        show_usage
        exit 1
    fi
    
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║           IMAGE DISCOVERY TOOL                             ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    log_info "Registry: ${REGISTRY}"
    log_info "Namespace: ${NAMESPACE}"
    log_info "Output: ${OUTPUT_FILE}"
    
    # Limpiar archivo de salida
    > "${OUTPUT_FILE}"
    
    local repos=""
    
    case "${REGISTRY}" in
        docker.io|hub.docker.com)
            repos=$(discover_dockerhub_repos "${NAMESPACE}")
            ;;
        ghcr.io)
            repos=$(discover_ghcr "${NAMESPACE}")
            ;;
        *)
            log_warn "Registry ${REGISTRY} no soporta descubrimiento automático"
            log_info "Proporciona lista manual de imágenes"
            exit 1
            ;;
    esac
    
    if [[ -z "${repos}" ]]; then
        log_error "No se encontraron repositorios"
        exit 1
    fi
    
    log_info "Repositorios encontrados: $(echo "${repos}" | wc -l | tr -d ' ')"
    
    # Obtener tags de cada repo
    local total_images=0
    
    while IFS= read -r repo; do
        [[ -z "${repo}" ]] && continue
        
        log_info "Descubriendo tags de: ${repo}"
        
        local tags=""
        case "${REGISTRY}" in
            docker.io|hub.docker.com)
                tags=$(discover_tags_dockerhub "${NAMESPACE}" "${repo}")
                ;;
            *)
                tags=$(discover_tags_skopeo "${REGISTRY}" "${NAMESPACE}/${repo}")
                ;;
        esac
        
        while IFS= read -r tag; do
            [[ -z "${tag}" ]] && continue
            echo "${repo}:${tag}" >> "${OUTPUT_FILE}"
            ((total_images++))
        done <<< "${tags}"
        
    done <<< "${repos}"
    
    echo ""
    log_info "═══════════════════════════════════════════"
    log_info "Total imágenes descubiertas: ${total_images}"
    log_info "Guardadas en: ${OUTPUT_FILE}"
    log_info "═══════════════════════════════════════════"
    
    echo ""
    log_info "Primeras 10 imágenes:"
    head -10 "${OUTPUT_FILE}" | sed 's/^/  /'
}

main "$@"
