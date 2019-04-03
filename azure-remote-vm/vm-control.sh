#!/bin/bash

set -e

program=$0
here=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
CONFIG_FILE="/etc/azure-vm-control/.vmcontrol"
verbose=false

operations="bash | checkip | configure | list | login | nsg-add | start | stop"

function fatal()
{
    if [ -n "$*" ] ; then
        echo >&2 "$*"
    fi
        echo >&2 "usage: $program $operations"
    exit 1
}

# Shell out if no parameters
if [ -z "$*" ];then
    exec bash
fi

if [ "$1" == "--debug" ] || [ "$1" == "-d" ];then
    set -x
    shift 1
    verbose=true
fi

operation="$1"
if [ -z "$operation" ]; then
    fatal "No operation specified"
fi
shift 1

CONFIG_FILE="/etc/azure-vm-control/.vmcontrol"

function reconfigure()
{
    if [ -z "$AVC_UUID" ];then
        AVC_UUID="$(cat /proc/sys/kernel/random/uuid)"
    fi

    if [ -z "$AVC_EXTERNAL_IP" ];then
        AVC_EXTERNAL_IP="$(curl --fail --silent checkip.amazonaws.com)"
    fi

    cat > "$CONFIG_FILE" <<EOF
declare -A configuration=(
    [AVC_EXTERNAL_IP]="$AVC_EXTERNAL_IP"
    [AVC_NSG_NAME]="$AVC_NSG_NAME"
    [AVC_NSG_RULE_PRIORITY]="$AVC_NSG_RULE_PRIORITY"
    [AVC_UUID]="$AVC_UUID"
)


for key in "\${!configuration[@]}"
do
     if [ -n "\$key" ];then     
        export \$key=\${configuration[\$key]}
     fi    
done
EOF

    source "$CONFIG_FILE" 
    if $verbose;then 
        cat "$CONFIG_FILE"
        env | grep ^AVC_
    fi
}

function set_nsg()
{
    local nsg="$1"
    az network nsg show --name $nsg  || fatal "Failed to guess network security group"

    maxprio=$(az network nsg rule list --nsg-name $nsg --out json  | jq '.[].priority' | sort -n | tail -1)
    if [ -z "$maxprio" ];then
        new_prio=110
    else
        new_prio=$((maxprio + 1))
    fi
    az network nsg rule create --name $AVC_UUID  --nsg-name $nsg --priority $new_prio  --access Allow --destination-address-prefixes '*' --destination-port-ranges '*' --direction Inbound --protocol '*' --source-address-prefixes ${AVC_EXTERNAL_IP}/32 --source-port-ranges '*'
    
    AVC_NSG_NAME="$nsg"
    AVC_NSG_RULE_PRIORITY="$new_prio"
}

function update_ip()
{

    publicip="$(curl --fail --silent checkip.amazonaws.com)"
    if [ "$publicip" != "$AVC_EXTERNAL_IP" ];then
        if [ -z "$AVC_NSG_RULE_PRIORITY" ]; then
            fatal "Must set or guess nsg before changing IP"
        fi 
        az network nsg rule update --name $AVC_UUID  --nsg-name $AVC_NSG_NAME --priority $AVC_NSG_RULE_PRIORITY  --access Allow --destination-address-prefixes '*' --destination-port-ranges '*' --direction Inbound --protocol '*' --source-address-prefixes ${AVC_EXTERNAL_IP}/32 --source-port-ranges '*'
        AVC_EXTERNAL_IP="$publicip"
    fi
    reconfigure
}

touch "$CONFIG_FILE"
source "$CONFIG_FILE" 

case "$operation" in
    bash)
        exec bash
        ;;

    checkip)
        update_ip
        ;;
    configure)
        az configure $@
        ;;
    dump-config)
        cat "$CONFIG_FILE"
        ;;
    reset-config)
        rm "$CONFIG_FILE"
        ;;
    list)
        az vm list $@
        ;;
    login)
        az login
        ;;
    nsg-add)
        set_nsg "$1"
        reconfigure
        ;;
    nsg-guess)
        nsg="$(az network nsg list --out json | jq -r '.[0].name')"
        set_nsg "$nsg"
        reconfigure
        ;;
    start)
        update_ip
        az vm start $@
        ;;
    status)
        az vm get-instance-view $@
        ;;
    stop)
        az vm deallocate $@
        ;;
    -)
        az $@
        ;;
    *)
        fatal "Unknown operation: $*"
esac
