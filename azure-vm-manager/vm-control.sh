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

    vms=$(az vm list -g $rg  -o json | jq -r '.[].name')
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
    fatal "Noo peration specified"
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
            exec $@
        fi
        ;;
esac
