#!/bin/bash
#######################################################
# Script: get_aro_hosts.sh
# Descripción: Obtiene las IPs de los servicios de ARO
#              y genera un archivo para /etc/hosts
# Uso: ./get_aro_hosts.sh
#######################################################

# Variables del cluster ARO - Modificar según el entorno
RESOURCE_GROUP="JAROPRIVATE"
CLUSTER_NAME="arogbbltam"

# Archivo de salida
OUTPUT_FILE="aro_hosts.txt"

echo "=============================================="
echo "Obteniendo información del cluster ARO..."
echo "Resource Group: $RESOURCE_GROUP"
echo "Cluster Name: $CLUSTER_NAME"
echo "=============================================="

# Obtener información del cluster
echo "Consultando datos del cluster..."

domain=$(az aro show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query clusterProfile.domain -o tsv)
if [ -z "$domain" ]; then
    echo "Error: No se pudo obtener el dominio del cluster"
    exit 1
fi

location=$(az aro show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query location -o tsv)
apiServer=$(az aro show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query apiserverProfile.url -o tsv)
webConsole=$(az aro show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query consoleProfile.url -o tsv)

# Extraer hostnames de las URLs
apiHost=$(echo "$apiServer" | sed 's|https://||' | sed 's|:.*||' | sed 's|/.*||')
consoleHost=$(echo "$webConsole" | sed 's|https://||' | sed 's|/.*||')

# Obtener las IPs privadas del cluster
echo "Obteniendo IPs del cluster..."

apiIP=$(az aro show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query apiserverProfile.ip -o tsv)
ingressIP=$(az aro show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query ingressProfiles[0].ip -o tsv)

# Mostrar información obtenida
echo ""
echo "=============================================="
echo "Información del Cluster ARO"
echo "=============================================="
echo "Domain: $domain"
echo "Location: $location"
echo "API Server URL: $apiServer"
echo "API Server Host: $apiHost"
echo "API Server IP: $apiIP"
echo "Web Console URL: $webConsole"
echo "Console Host: $consoleHost"
echo "Ingress IP: $ingressIP"
echo "=============================================="

# Generar archivo de hosts
echo ""
echo "Generando archivo $OUTPUT_FILE..."

cat > "$OUTPUT_FILE" << EOF
# ARO Cluster Hosts - $(date)
# Resource Group: $RESOURCE_GROUP
# Cluster Name: $CLUSTER_NAME
# Domain: $domain
# Location: $location

# API Server
$apiIP    $apiHost

# Web Console (uses Ingress IP)
$ingressIP    $consoleHost

# OAuth Server (uses Ingress IP)
$ingressIP    oauth-openshift.apps.$domain.$location.aroapp.io

# Additional apps routes (uses Ingress IP)
# Agregar aquí rutas adicionales de aplicaciones
# $ingressIP    <app-name>.apps.$domain.$location.aroapp.io

EOF

echo ""
echo "=============================================="
echo "Archivo generado exitosamente: $OUTPUT_FILE"
echo "=============================================="
echo ""
echo "Para usar este archivo, ejecuta:"
echo "  sudo cat $OUTPUT_FILE >> /etc/hosts"
echo ""
echo "O copia el contenido manualmente a tu /etc/hosts"
echo ""

# Mostrar contenido del archivo generado
echo "Contenido del archivo generado:"
echo "----------------------------------------------"
cat "$OUTPUT_FILE"
echo "----------------------------------------------"
