#!/bin/bash
#######################################################
# Script: get_aro_credentials.sh
# Descripción: Obtiene las credenciales de acceso al
#              cluster ARO y genera un archivo de salida
# Uso: ./get_aro_credentials.sh
#######################################################

# Variables del cluster ARO - Modificar según el entorno
RESOURCE_GROUP="JAROPRIVATE"
CLUSTER_NAME="arogbbltam"

# Archivo de salida con identificador del cluster
OUTPUT_FILE="aro_credentials_${CLUSTER_NAME}.txt"

echo "=============================================="
echo "Obteniendo credenciales del cluster ARO..."
echo "Resource Group: $RESOURCE_GROUP"
echo "Cluster Name: $CLUSTER_NAME"
echo "=============================================="

# Verificar que el cluster existe
echo "Verificando acceso al cluster..."

clusterCheck=$(az aro show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query name -o tsv 2>/dev/null)
if [ -z "$clusterCheck" ]; then
    echo "Error: No se pudo acceder al cluster $CLUSTER_NAME en el grupo $RESOURCE_GROUP"
    echo "Verifica que el cluster existe y tienes los permisos necesarios."
    exit 1
fi

# Obtener credenciales del cluster
echo "Consultando credenciales..."

credentials=$(az aro list-credentials --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" -o json)

if [ -z "$credentials" ]; then
    echo "Error: No se pudieron obtener las credenciales del cluster"
    exit 1
fi

# Extraer usuario y contraseña
kubeadminUser=$(echo "$credentials" | jq -r '.kubeadminUsername')
kubeadminPassword=$(echo "$credentials" | jq -r '.kubeadminPassword')

# Obtener URL de la consola para facilitar el acceso
consoleUrl=$(az aro show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query consoleProfile.url -o tsv)
apiServerUrl=$(az aro show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query apiserverProfile.url -o tsv)

# Mostrar información obtenida
echo ""
echo "=============================================="
echo "Credenciales del Cluster ARO"
echo "=============================================="
echo "Usuario: $kubeadminUser"
echo "Contraseña: $kubeadminPassword"
echo "Console URL: $consoleUrl"
echo "API Server: $apiServerUrl"
echo "=============================================="

# Generar archivo de credenciales
echo ""
echo "Generando archivo $OUTPUT_FILE..."

cat > "$OUTPUT_FILE" << EOF
#######################################################
# ARO Cluster Credentials
# Generado: $(date)
# Resource Group: $RESOURCE_GROUP
# Cluster Name: $CLUSTER_NAME
#######################################################

# Credenciales de Administrador
Usuario: $kubeadminUser
Password: $kubeadminPassword

# URLs de Acceso
Console URL: $consoleUrl
API Server: $apiServerUrl

#######################################################
EOF

# Establecer permisos restrictivos en el archivo de credenciales
chmod 600 "$OUTPUT_FILE"

echo ""
echo "=============================================="
echo "Archivo generado exitosamente: $OUTPUT_FILE"
echo "=============================================="
echo ""
echo "NOTA: El archivo tiene permisos 600 (solo lectura para el propietario)"
echo ""
echo "Accede a la consola web:"
echo "  $consoleUrl"
echo ""

# Mostrar contenido del archivo generado
echo "Contenido del archivo generado:"
echo "----------------------------------------------"
cat "$OUTPUT_FILE"
echo "----------------------------------------------"
