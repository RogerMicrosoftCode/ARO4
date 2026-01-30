#!/bin/bash
#######################################################
# Script: validate_replication.sh
# Descripción: Valida que las imágenes fueron replicadas
#              correctamente al ACR destino
#
# Uso: ./validate_replication.sh [--config <file>]
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
BOLD='\033[1m'

#======================================================
# CONFIGURACIÓN
#======================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# Cargar configuración
if [[ -f "${CONFIG_FILE}" ]]; then
    source "${CONFIG_FILE}"
fi

DEST_ACR_NAME="${DEST_ACR_NAME:-}"
REPORTS_DIR="${REPORTS_DIR:-./reports}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

#======================================================
# FUNCIONES
#======================================================
log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') - $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') - $*"; }

show_banner() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║           ACR REPLICATION VALIDATOR v1.0                   ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

validate_acr_access() {
    log_info "Verificando acceso al ACR: ${DEST_ACR_NAME}..."
    
    if ! az acr show --name "${DEST_ACR_NAME}" &> /dev/null; then
        log_error "No se puede acceder al ACR: ${DEST_ACR_NAME}"
        exit 1
    fi
    
    log_info "✓ Acceso verificado"
}

list_acr_repositories() {
    log_info "Listando repositorios en ACR..."
    
    local repos
    repos=$(az acr repository list --name "${DEST_ACR_NAME}" -o tsv 2>/dev/null)
    
    if [[ -z "${repos}" ]]; then
        log_warn "No se encontraron repositorios en el ACR"
        return
    fi
    
    echo ""
    echo -e "${BOLD}Repositorios en ${DEST_ACR_NAME}:${NC}"
    echo "────────────────────────────────────────"
    
    local count=0
    while IFS= read -r repo; do
        local tag_count
        tag_count=$(az acr repository show-tags --name "${DEST_ACR_NAME}" --repository "${repo}" -o tsv 2>/dev/null | wc -l)
        echo "  📦 ${repo} (${tag_count} tags)"
        ((count++))
    done <<< "${repos}"
    
    echo "────────────────────────────────────────"
    echo -e "Total: ${BOLD}${count}${NC} repositorios"
    echo ""
}

validate_images_from_file() {
    local images_file="${1:-${SOURCE_IMAGES_FILE:-}}"
    
    if [[ -z "${images_file}" || ! -f "${images_file}" ]]; then
        log_warn "No se proporcionó archivo de imágenes para validar"
        return
    fi
    
    log_info "Validando imágenes desde: ${images_file}"
    
    local validation_report="${REPORTS_DIR}/validation_${TIMESTAMP}.md"
    mkdir -p "${REPORTS_DIR}"
    
    cat > "${validation_report}" << EOF
# ACR Validation Report

**Fecha:** $(date '+%Y-%m-%d %H:%M:%S')  
**ACR:** ${DEST_ACR_NAME}  

## Resultados de Validación

| Repositorio | Tag | Estado | Digest |
|-------------|-----|--------|--------|
EOF

    local total=0
    local found=0
    local missing=0
    
    while IFS= read -r image; do
        [[ -z "${image}" || "${image}" =~ ^# ]] && continue
        
        local repo="${image%%:*}"
        local tag="${image#*:}"
        [[ "${tag}" == "${repo}" ]] && tag="latest"
        
        # Aplicar prefijo si existe
        local dest_repo="${repo}"
        if [[ -n "${DEST_PREFIX:-}" ]]; then
            dest_repo="${DEST_PREFIX}/${repo}"
        fi
        
        ((total++))
        
        # Verificar si existe
        local digest
        digest=$(az acr repository show-manifests \
            --name "${DEST_ACR_NAME}" \
            --repository "${dest_repo}" \
            --query "[?tags[?contains(@, '${tag}')]].digest | [0]" \
            -o tsv 2>/dev/null)
        
        if [[ -n "${digest}" ]]; then
            echo "  ✅ ${dest_repo}:${tag}"
            echo "| ${dest_repo} | ${tag} | ✅ FOUND | ${digest:0:20}... |" >> "${validation_report}"
            ((found++))
        else
            echo "  ❌ ${dest_repo}:${tag} - NO ENCONTRADO"
            echo "| ${dest_repo} | ${tag} | ❌ MISSING | - |" >> "${validation_report}"
            ((missing++))
        fi
        
    done < "${images_file}"
    
    # Resumen
    cat >> "${validation_report}" << EOF

---

## Resumen

| Métrica | Valor |
|---------|-------|
| Total esperadas | ${total} |
| Encontradas | ${found} |
| Faltantes | ${missing} |
| Porcentaje éxito | $(( (found * 100) / (total > 0 ? total : 1) ))% |

EOF

    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         RESUMEN DE VALIDACIÓN        ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Total esperadas:  ${BOLD}${total}${NC}"
    echo -e "  ${GREEN}✓ Encontradas:${NC}    ${found}"
    echo -e "  ${RED}✗ Faltantes:${NC}      ${missing}"
    echo ""
    
    if [[ ${missing} -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}✓ VALIDACIÓN EXITOSA - 100% replicado${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}⚠ VALIDACIÓN CON FALTANTES${NC}"
    fi
    
    echo ""
    log_info "Reporte guardado en: ${validation_report}"
}

compare_digests() {
    local source_image="$1"
    local dest_image="$2"
    
    log_info "Comparando digests..."
    
    # Obtener digest del origen
    local source_digest=""
    if command -v skopeo &> /dev/null; then
        source_digest=$(skopeo inspect "docker://${source_image}" 2>/dev/null | jq -r '.Digest')
    fi
    
    # Obtener digest del destino
    local repo="${dest_image%%:*}"
    local tag="${dest_image#*:}"
    
    local dest_digest
    dest_digest=$(az acr repository show-manifests \
        --name "${DEST_ACR_NAME}" \
        --repository "${repo}" \
        --query "[?tags[?contains(@, '${tag}')]].digest | [0]" \
        -o tsv 2>/dev/null)
    
    echo "  Source: ${source_digest:-unknown}"
    echo "  Dest:   ${dest_digest:-unknown}"
    
    if [[ -n "${source_digest}" && -n "${dest_digest}" ]]; then
        if [[ "${source_digest}" == "${dest_digest}" ]]; then
            echo -e "  ${GREEN}✓ Digests coinciden${NC}"
            return 0
        else
            echo -e "  ${YELLOW}⚠ Digests diferentes (posible multi-arch o actualización)${NC}"
            return 1
        fi
    fi
}

show_acr_stats() {
    log_info "Obteniendo estadísticas del ACR..."
    
    # Obtener uso del ACR
    local usage
    usage=$(az acr show-usage --name "${DEST_ACR_NAME}" -o json 2>/dev/null)
    
    if [[ -n "${usage}" ]]; then
        echo ""
        echo -e "${BOLD}Estadísticas del ACR:${NC}"
        echo "────────────────────────────────────────"
        
        echo "${usage}" | jq -r '.value[] | "  \(.name): \(.currentValue) / \(.limit) (\(.unit))"'
        
        echo "────────────────────────────────────────"
    fi
}

#======================================================
# MAIN
#======================================================
main() {
    local images_file=""
    
    # Parsear argumentos
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                source "${CONFIG_FILE}"
                shift 2
                ;;
            -i|--images)
                images_file="$2"
                shift 2
                ;;
            -h|--help)
                echo "Uso: $0 [-c config.env] [-i images.txt]"
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done
    
    show_banner
    
    if [[ -z "${DEST_ACR_NAME}" ]]; then
        log_error "DEST_ACR_NAME no está configurado"
        exit 1
    fi
    
    validate_acr_access
    list_acr_repositories
    show_acr_stats
    
    if [[ -n "${images_file}" ]]; then
        validate_images_from_file "${images_file}"
    elif [[ -n "${SOURCE_IMAGES_FILE:-}" && -f "${SOURCE_IMAGES_FILE}" ]]; then
        validate_images_from_file "${SOURCE_IMAGES_FILE}"
    fi
    
    echo ""
    log_info "Validación completada"
}

main "$@"
