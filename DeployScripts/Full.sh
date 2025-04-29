#/bin/bash
az login --use-device-code --tenant 16b3c013-d300-468d-ac64-7eda0820b6d3
export LOCATION="westus3"
export RESOURCEGROUP="arobuildw3"
export CLUSTER="arobuild"
export SP_CLIENT_ID=""
export SP_CLIENT_SECRET=""
export VISIBILITY="Public"
az group create --name $RESOURCEGROUP--location $LOCATION
az network vnet create --resource-group $RESOURCEGROUP--name aro-vnet --address-prefixes 192.168.192.0/23
az network vnet subnet create --resource-group $RESOURCEGROUP--vnet-name aro-vnet --name master-subnet --address-prefixes 192.168.192.0/25 --service-endpoints Microsoft.ContainerRegistry
az network vnet subnet create --resource-group $RESOURCEGROUP--vnet-name aro-vnet --name worker-subnet --address-prefixes 192.168.192.128/25 --service-endpoints Microsoft.ContainerRegistry
az network vnet subnet update --name master-subnet --resource-group $RESOURCEGROUP--vnet-name aro-vnet --private-link-service-network-policies Disabled

#az ad sp create-for-rbac -n arobuildgbbc --role contriburor --scopes /subscriptions/55318ed6-5d8a-4bd2-889f-10e502960c28/resourceGroups/$RESOURCEGROUP--skip-assignment
#az ad sp list --show-mine -o table
az aro create --resource-group $RESOURCEGROUP --name $CLUSTER --vnet aro-vnet --master-subnet master-subnet --worker-subnet worker-subnet --apiserver-visibility $VISIBILITY --ingress-visibility $VISIBILITY --domain jaropro.net --pull-secret @pull-secret.txt --client-id $SP_CLIENT_ID --client-secret $SP_CLIENT_SECRET
#az aro create --resource-group $RESOURCEGROUP --name $CLUSTER --vnet aro-vnet --master-subnet master-subnet --worker-subnet worker-subnet --apiserver-visibility $VISIBILITY --ingress-visibility $VISIBILITY --domain jaropro.net --pull-secret @pull-secret.txt

#SECCION TO DELETE ALL or FULL DEPLOYMENT
#az aro delete --name $CLUSTER --resource-group $RESOURCEGROUP --yes --no-wait
#az network vnet subnet delete --name master-subnet --resource-group $RESOURCEGROUP --vnet-name aro-vnet
#az network vnet subnet delete --name worker-subnet --resource-group $RESOURCEGROUP --vnet-name aro-vnet
#az network vnet delete --name aro-vnet --resource-group $RESOURCEGROUP

#OR

#az group delete --name $RESOURCEGROUP --yes --no-wait

#SECCION PARA VERIFICAR EL TIPO DE VM
#az vm list-skus --location $LOCATION --size Standard_D --all --output table | grep '1,2,3    None' >vmlist.txt
#cat vmlist.txt |grep D8