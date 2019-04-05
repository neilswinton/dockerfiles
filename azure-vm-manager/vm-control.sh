#!/bin/bash

set -e

program=$0
here=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
verbose=false

operations="--add-account <account-name> | --delete-acccount <account-name> | <account-name> --group-start | --group-stop <resource-group>"

function fatal()
{
    if [ -n "$*" ] ; then
        echo >&2 "$*"
    fi
        echo >&2 "usage: $program $operations"
    exit 1
}

function track_ip()
{
    local rule_name="$1"
    local rg="$2"

    if [ -z "$rule_name" ]; then
        fatal "Missing rule name.  --track-ip <rule-name> <resource-group> [nsg-name]"
    fi

    if [ -z "$rg" ]; then
        fatal "Missing resource group name.  --track-ip <rule-name> <resource-group>"
    fi

    # get nsg
    if [ -z "$3" ]; then
        nsg="$(az network nsg list --resource-group $rg --output json | jq -r '.[0].name')"
    else
        nsg="$3"
    fi
        rule=$(az network nsg rule show --resource-group $rg --nsg-name "$nsg" --name "$rule_name" --output json)  || fatal "Invalid network security group"

    local jsonfile="$AZURE_CONFIG_DIR/.trackedip/$rg/$rule_name"
    mkdir -p $(dirname "$jsonfile")
    cat > "$jsonfile" <<<"$rule"
    cat "$jsonfile"
}

function update_tracked_ips()
{
    readonly local current_ip="$(curl --silent --fail checkip.amazonaws.com)"
    readonly local source_address_prefix="$current_ip/32"

    local files=$(find "$AZURE_CONFIG_DIR/.trackedip" -type f)
    local changed=0
    for file in $files;do
        local id=$(jq -r < $file .id)
        if [ "$source_address_prefix" != "$(jq -r < $file .sourceAddressPrefix)" ];then
            az network nsg rule update --ids "$id" --source-address-prefixes "$source_address_prefix" --output json > $file || fatal
            changed=$((changed+1))
        fi
    done
    echo "$changed rules of $(echo $files | wc -w) rules required updating"
}

function group_vm_operation()
{
    rg="$1"
    operation="$2"
    if [ -z "$rg" ]; then
        fatal "Command requires a resource group name"
    fi

    if [ "$operation" == "deallocate" ] || [ "$operation" == "start" ];then
        nowait="--no-wait"
    else
        nowait=""
    fi

    vms=$(az vm list --resource-group $rg  -o json | jq -r '.[].name')
    for vm in $vms;do
        az vm $operation --resource-group $rg --name $vm $nowait
    done
}

function account_command()
{
    token="$1"
    shift 1

    case "$token" in

        --group)
            group_vm_operation $@
            ;;

        --group-all)
            rgs=$(az group list -o json | jq -r '.[].name')
            for rg in $rgs;do
                group_vm_operation $rg $@
            done
            ;;

        --group-tag)
            rgs=$(az group list -o json | jq -r '.[].name')
            for rg in $rgs;do
                group_vm_operation $rg $@
            done
            ;;

        --track-ip)
            track_ip $@
            ;;

        --update-tracked-ips)
            update_tracked_ips
            ;;

        *)
            fatal "Unknown command: $token"
            ;;
    esac
}

if [ "$1" == "--debug" ] || [ "$1" == "-d" ];then
    set -x
    shift 1
    verbose=true
fi

token="$1"
if [ -z "$token" ]; then
    fatal "No operation specified"
fi
shift 1

CONFIG_DIR="${CONFIG_DIR:-/etc/azure-vm-manager}"
if [ ! -d "$CONFIG_DIR" ];then
    fatal "$CONFIG_DIR does not exist"
fi

case "$token" in
    --account-add)
        if [ -z "$1" ]; then
            fatal "account name is required"
        fi
        mkdir "$CONFIG_DIR/$1"
        ;;

    --account-foreach)
        for AZURE_CONFIG_DIR in "$CONFIG_DIR"/*;do
            export AZURE_CONFIG_DIR
            if [[ $1 =~ ^-- ]] ;
            then
                account_command $@
            else
                $@
            fi
            echo ""
        done
        ;;
    --account-list)
        ls -1 "$CONFIG_DIR"
        ;;

    --account-delete)
        if [ -z "$1" ]; then
            fatal "account name is required"
        fi

        if [ ! -d "$CONFIG_DIR/$1" ]; then
            fatal "account not found"
        fi

        rm -rf "$CONFIG_DIR/$1"
        ;;
    *)
        export AZURE_CONFIG_DIR="$CONFIG_DIR/$token"
        if [[ $1 =~ ^-- ]] ;
        then
            account_command $@
        else
            exec $token $@
        fi
        ;;
esac
