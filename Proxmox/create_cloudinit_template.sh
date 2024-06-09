#!/usr/bin/env bash

function header_info() {
clear
cat <<"EOF"
   __    __   __      __
  \  \  /  / |   \  /   |
   \  \/  /  |    \/    |
    \    /   |  |\__/|  |
     \__/    |__|    |__| Templater

EOF
}
header_info

function exit_handler() {
  exit_status=$1
  if [ "$exit_status" -ne 0 ]; then
    header_info "Exiting..."
    echo "Exit status: $exit_status"
    exit 0
  fi
}

err_report() {
    echo "Error on line $1"
    exit 1
}

trap 'exit_handler $?' ERR

# Defaults
default_purpose="default"
default_vmid=10000
default_memory=2048
default_name="CI-Template"
default_storage_size=10
default_cpu_type="host"
default_cpu_cores=4
default_ipconfig0_v4="dhcp"
default_ipconfig0_v6="dhcp"
default_guest_agent=1

default_username="localadmin"
default_ssh_pubkeys="$(pwd)/.ssh/authorized_keys"

# Static Variables
# Purpose/Cloudinit Vendor Configuration File
cloudinit_vendor_suffix="_vendorconfig.yaml"
snippets_folder="/var/lib/vz/snippets/"
snippets_storage="local" # currently only local is supported because I have no idea how to reliably get the path for other storage locations

# Check if the 'whiptail' utility is installed
if ! command -v whiptail &>/dev/null; then
  echo "This script requires the 'whiptail' utility to be installed."
  exit 1
fi

# Check if the script is being run as root
if [[ $EUID -ne 0 ]]; then
  whiptail --backtitle "Proxmox VM Template Creator" --title "Insufficient Permissions" --msgbox "This script must be run as root." 10 60 3>&1 1>&2 2>&3
  exit 1
fi

# Check if the required tools are installed
if ! command -v qm &>/dev/null || ! command -v qemu-img &>/dev/null; then
  whiptail --backtitle "Proxmox VM Template Creator" --title "Missing Dependencies" --msgbox "This script requires the 'qm' and 'qemu-img' utility to be installed." 10 60 3>&1 1>&2 2>&3
  exit 1
fi

# Check if the required arguments are provided
if [ "$#" -ne 1 ]; then
  whiptail --backtitle "Proxmox VM Template Creator" --title "Missing arguments" --msgbox "Usage: $0 <cloud_image>" 10 60 3>&1 1>&2 2>&3
  exit 1
fi

# Check if the cloud image exists
if [ ! -f "$1" ]; then
  whiptail --backtitle "Proxmox VM Template Creator" --title "Error" --msgbox "Error: Cloud image not found." 10 60 3>&1 1>&2 2>&3
  exit 1
fi

# Check if the cloud image is a valid qcow2 image
if ! qemu-img info "$1" | grep -q "file format: qcow2"; then
  whiptail --backtitle "Proxmox VM Template Creator" --title "Error" --msgbox "Error: Invalid cloud image format." 10 60 3>&1 1>&2 2>&3
  exit 1
fi

function cleanup_vmid() {
  vmid=$1
  echo "Destroying the VM with ID $vmid..."
  if qm status $vmid &>/dev/null; then
    echo "Stopping the VM..."
    qm stop $vmid &>/dev/null
    echo "Destroying the VM..."
    qm destroy $vmid &>/dev/null
    echo "VM with ID $vmid has been destroyed."
  fi
# qm destroy <vmid> [OPTIONS]
# Destroy the VM and all used/owned volumes. Removes any VM specific permissions and firewall rules
# <vmid>: <integer> (100 - 999999999)
#     The (unique) ID of the VM.
# --destroy-unreferenced-disks <boolean> (default = 0)
#     If set, destroy additionally all disks not referenced in the config but with a matching VMID from all enabled storages.
# --purge <boolean>
#     Remove VMID from configurations, like backup & replication jobs and HA.
# --skiplock <boolean>
#     Ignore locks - only root is allowed to use this option.
}

whiptail --backtitle "Proxmox VM Template Creator" --title "Welcome" --msgbox "This script will create a Proxmox VM template using the provided cloud image." 10 60 --ok-button "Continue"

# Purpose/Cloudinit Vendor Configuration File
function get_purpose() {
  local purpose="${1:-$default_purpose}"
  trap 'return $?' ERR

  purpose=$(whiptail --backtitle "Proxmox VM Template Creator" --title "Machine Purpose" --inputbox "Enter the purpose of the VM template:" 10 60 "$purpose" --ok-button "Next" --cancel-button "Cancel" 3>&1 1>&2 2>&3)
  echo "$purpose"

}
# VM ID
function get_vmid() {
  local vmid="${1:-$default_vmid}"
  trap 'return $?' ERR

  while true; do
    vmid=$(whiptail --backtitle "Proxmox VM Template Creator" --title "VM ID" --inputbox "Enter the VM ID:" 10 60 "$vmid" --ok-button "Next" --cancel-button "Cancel" 3>&1 1>&2 2>&3)
    if qm list | awk '{print $1}' | grep -q "^$vmid$" || pct list | awk '{print $1}' | grep -q "^$vmid$"; then
      if whiptail --backtitle "Proxmox VM Template Creator" --title "Warning" --yesno "Warning: The VM ID $vmid is already taken." 10 60 --yes-button "Force" --no-button "Back" 3>&1 1>&2 2>&3; then
        break
      fi
    else
        break
    fi
  done
  echo "$vmid"

}

# Memory
function get_memory() {
  local memory="${1:-$default_memory}"
  trap 'return $?' ERR

  memory=$(whiptail --backtitle "Proxmox VM Template Creator" --title "Memory" --inputbox "Enter the memory size in MB:" 10 60 "$memory" --ok-button "Next" --cancel-button "Cancel" 3>&1 1>&2 2>&3)
  echo "$memory"

}

# Name
function get_name() {
  local name="${1:-$default_name}"
  trap 'return $?' ERR

  name=$(whiptail --backtitle "Proxmox VM Template Creator" --title "Name" --inputbox "Enter the name of the VM template:" 10 60 "$name" --ok-button "Next" --cancel-button "Cancel" 3>&1 1>&2 2>&3)
  echo "$name"

}

# Storage
function get_storage_pool() {
  trap 'return $?' ERR

  local storage_pools=$(pvesm status | awk '{print $1}')
  readarray -t storage_pools <<< $storage_pools
  unset 'storage_pools[0]'

  local whiptail_args=(
      --backtitle "Proxmox VM Template Creator"
      --title "Storage"
      --ok-button "Next"
      --cancel-button "Cancel"
      --menu "Select the storage pool where the VM template will be stored:" 10 60 "${#storage_pools[@]}"
  )

  i=0
  for storage_pool in "${storage_pools[@]}"; do
    whiptail_args+=( "$((++i))" "$storage_pool" )
  done

  storage_pool=$(whiptail "${whiptail_args[@]}" 3>&1 1>&2 2>&3)
  storage_pool="${storage_pools[$storage_pool]}"
  echo "$storage_pool"

}

function get_storage_size() {
  local storage_size="${1:-$default_storage_size}"
  trap 'return $?' ERR

  storage_size=$(whiptail --backtitle "Proxmox VM Template Creator" --title "Storage Size" --inputbox "Enter the storage size in GB:" 10 60 "$storage_size" --ok-button "Next" --cancel-button "Cancel" 3>&1 1>&2 2>&3)
  echo "$storage_size"

}

# CPU
function get_cpu_type() {
  local cpu_type="${1:-$default_cpu_type}"
  trap 'return $?' ERR

  cpu_type=$(whiptail --backtitle "Proxmox VM Template Creator" --title "CPU" --inputbox "Enter the CPU type:" 10 60 "$cpu_type" --ok-button "Next" --cancel-button "Cancel" 3>&1 1>&2 2>&3)
  echo "$cpu_type"

}

function get_cpu_cores() {
  local cpu_cores="${1:-$default_cpu_cores}"
  trap 'return $?' ERR

  cpu_cores=$(whiptail --backtitle "Proxmox VM Template Creator" --title "CPU Cores" --inputbox "Enter the number of CPU cores:" 10 60 "$cpu_cores" --ok-button "Next" --cancel-button "Cancel" 3>&1 1>&2 2>&3)
  echo "$cpu_cores"

}

# Network
function get_net0_driver() {
  trap 'return $?' ERR

  local drivers=( "virtio" ) # Get all the network drivers
  local whiptail_args=(
    --backtitle "Proxmox VM Template Creator"
    --title "Network"
    --ok-button "Next"
    --cancel-button "Cancel"
    --menu "Select the network driver the template should use:" 10 60 "${#drivers[@]}"
  )

  i=-1
  for driver in "${drivers[@]}"; do
    whiptail_args+=( "$((++i))" "$driver" )
  done

  driver=$(whiptail "${whiptail_args[@]}" 3>&1 1>&2 2>&3)
  driver="${drivers[$driver]}"
  echo "$driver"
}

function get_net0_bridge() {
  trap 'return $?' ERR
  
  interfaces=$(networkctl --no-legend | awk '{print $2}' | grep vmbr) # Get all the vmbr interfaces
  readarray -t interfaces <<< $interfaces
  local whiptail_args=(
    --backtitle "Proxmox VM Template Creator"
    --title "Network"
    --ok-button "Next"
    --cancel-button "Cancel"
    --menu "Select the network bridge the template should attach to:" 10 60 "${#interfaces[@]}"
  )

  i=-1
  for interface in "${interfaces[@]}"; do
    whiptail_args+=( "$((++i))" "$interface" )
  done

  interface=$(whiptail "${whiptail_args[@]}" 3>&1 1>&2 2>&3)
  interface="${interfaces[$interface]}"
  echo "$interface"
}

function get_net0() {
  trap 'return $?' ERR

  driver=$(get_net0_driver)
  bridge=$(get_net0_bridge)
  echo "$driver,bridge=$bridge"
}

# IP Configuration
function get_ipconfig0_v4() {
  local ipconfig0="${1:-$default_ipconfig0_v4}"
  trap 'return $?' ERR

  ipconfig0=$(whiptail --backtitle "Proxmox VM Template Creator" --title "IPv4 Configuration" --inputbox "Enter the IPv4 configuration for the network interface:" 10 60 "$ipconfig0" --ok-button "Next" --cancel-button "Cancel" 3>&1 1>&2 2>&3)
  echo "$ipconfig0"

}

function get_ipconfig0_v6() {
  local ipconfig0="${1:-$default_ipconfig0_v6}"
  trap 'return $?' ERR

  ipconfig0=$(whiptail --backtitle "Proxmox VM Template Creator" --title "IPv6 Configuration" --inputbox "Enter the IPv6 configuration for the network interface:" 10 60 "$ipconfig0" --ok-button "Next" --cancel-button "Cancel" 3>&1 1>&2 2>&3)
  echo "$ipconfig0"

}

function get_ipconfig0() {
  trap 'return $?' ERR

  ipconfig0_v4=$(get_ipconfig0_v4)
  ipconfig0_v6=$(get_ipconfig0_v6)
  echo "ip=$ipconfig0_v4,ip6=$ipconfig0_v6"
}

# OS Type
function get_ostype() {
  trap 'return $?' ERR

  local os_types=( l24 l26 other solaris w2k w2k3 w2k8 win10 win11 win7 win8 wvista wxp ) # Available OS types
  local whiptail_args=(
    --backtitle "Proxmox VM Template Creator"
    --title "OS Type"
    --ok-button "Next"
    --cancel-button "Cancel"
    --menu "Select the OS type the template should use:" 10 60 "${#os_types[@]}"
  )

  i=-1
  for os_type in "${os_types[@]}"; do
    whiptail_args+=( "$((++i))" "$os_type" )
  done

  os_type=$(whiptail "${whiptail_args[@]}" 3>&1 1>&2 2>&3)
  os_type="${os_types[$os_type]}"
  echo "$os_type"
}

# Authentication
function get_username() {
  local username="${1:-$default_username}"
  trap 'return $?' ERR

  username=$(whiptail --backtitle "Proxmox VM Template Creator" --title "Username" --inputbox "Enter the username for the VM template:" 10 60 "$username" --ok-button "Next" --cancel-button "Cancel" 3>&1 1>&2 2>&3)
  echo "$username"

}

function get_ssh_pubkeys() {
  local ssh_pubkeys="${1:-$default_ssh_pubkeys}"
  trap 'unset ssh_pubkeys; return 0' ERR

  if whiptail --backtitle "Proxmox VM Template Creator" --title "SSH Public Key" --yesno "Do you want to use an SSH public key for authentication?" 10 60 --yes-button "Yes" --no-button "No" 3>&1 1>&2 2>&3; then
    while true; do
      ssh_pubkeys=$(whiptail --backtitle "Proxmox VM Template Creator" --title "SSH Public Key" --inputbox "Enter the path to the SSH public key(s):" 10 60 "$ssh_pubkeys" --ok-button "Confirm" --cancel-button "Skip" 3>&1 1>&2 2>&3)
      if [ -f "$ssh_pubkeys" ]; then
        echo "$ssh_pubkeys"
        break
      fi
      whiptail --backtitle "Proxmox VM Template Creator" --title "Error" --msgbox "Error: Cloud image not found." 10 60 --ok-button "Back" 3>&1 1>&2 2>&3
    done
  fi

}

function get_guest_agent() {
  local enable_guest_agent="${1:-$default_guest_agent}"
  trap 'return $0' ERR

  if whiptail --backtitle "Proxmox VM Template Creator" --title "QEMU Guest Agent" --yesno "Do you want to enable the QEMU Guest Agent?" 10 60 --yes-button "Yes" --no-button "No" 3>&1 1>&2 2>&3; then
    echo "1"
  else
    echo "0"
  fi
}

# Create the VM template
function create_cloudinit_template() {
  trap 'err_report $LINENO' ERR
  header_info
  echo "Creating the VM template..."
  local image=$1
  local purpose=$2
  local vmid=$3
  local memory=$4
  local name=$5
  local storage_pool=$6
  local storage_size=$7
  local cpu_type=$8
  local cpu_cores=$9
  local net0=${10}
  local ipconfig0=${11}
  local ostype=${12}
  local username=${13}
  local ssh_pubkeys=${14}
  local enable_guest_agent=${15}

  local cloudinit_vendor_file="${purpose}${cloudinit_vendor_suffix}"
  local cloudinit_vendor_config="${snippets_folder}${cloudinit_vendor_file}"

  if qm list | awk '{print $1}' | grep -q "^$vmid$" || pct list | awk '{print $1}' | grep -q "^$vmid$"; then
    if whiptail --backtitle "Proxmox VM Template Creator" --title "Warning" --yesno "Warning: The VM ID $vmid is already taken. Do you want to permanently destroy the VM to free the ID?" 10 60 --yes-button "Yes, destroy the VM!" --no-button "No, abort!" 3>&1 1>&2 2>&3; then
      cleanup_vmid $vmid
    else
      echo "Aborting creation of the VM template. No changes have been made persistent."
      exit 0
    fi
  fi

  if ! [ -f "$cloudinit_vendor_config" ]; then
    echo -e "The cloudinit vendor configuration file is missing.\nTrying to create it..."
    if ! [ -f "${snippets_folder}${default_purpose}${cloudinit_vendor_suffix}" ]; then
      echo -e "The default cloudinit vendor configuration file is missing.\nPlease create it manually as \"${snippets_folder}${default_purpose}${cloudinit_vendor_suffix}\".\nAlso, make sure you have the snippets storage enabled.\nExiting..."
      exit 1
    else
      if whiptail --backtitle "Proxmox VM Template Creator" --title "Cloudinit Vendor Configuration" --yesno "The cloudinit vendor configuration file is missing. Do you want to make a copy of the default configuration to later edit it?" 10 60 --yes-button "Yes" --no-button "No" 3>&1 1>&2 2>&3; then
        cp "${snippets_folder}${default_purpose}${cloudinit_vendor_suffix}" "$cloudinit_vendor_config"
        echo -e "The cloudinit vendor configuration file has been created."
      else
        echo -e "The cloudinit vendor configuration file is missing.\nPlease create it manually."
        exit 1
      fi
    fi
  fi

  echo "Creating new VM"
  qm create $vmid --cpu $cpu_type --cores $cpu_cores --memory $memory --name $name --net0 $net0 --ipconfig0 $ipconfig0 --ostype $ostype --tablet 0
  
  echo "Importing disk image: $image"
  qm importdisk $vmid $image $storage_pool

  echo "Setting the VMs main disk"
  qm set $vmid --scsihw virtio-scsi-pci --scsi0 $storage_pool:vm-$vmid-disk-0

  echo "Setting the main disk as boot disk"
  qm set $vmid --boot c --bootdisk scsi0

  echo "Setting the cloudinit disk"
  qm set $vmid --ide2 $storage_pool:cloudinit

  echo "Setting the cloudinit user"
  qm set $vmid --ciuser $username

  if [ -f "$ssh_pubkeys" ]; then
    echo "Setting the SSH key(s)"
    qm set $vmid --sshkey $ssh_pubkeys
  fi

  echo "Setting the serial and VGA"
  qm set $vmid --serial0 socket --vga serial0

  echo "Setting the cloudinit vendor configuration"
  qm set $vmid --cicustom "vendor=${snippets_storage}:snippets/${cloudinit_vendor_file}"
  echo "Attached the cloudinit vendor configuration file: $cloudinit_vendor_config"

  echo "Setting the QEMU Guest Agent"
  qm set $vmid --agent enabled=$enable_guest_agent,fstrim_cloned_disks=$enable_guest_agent

  echo "Updating the cloudinit configuration"
  qm cloudinit update $vmid

  if whiptail --backtitle "Proxmox VM Template Creator" --title "Template Creation" --yesno "Do you want to set the VM as a template?" 10 60 --yes-button "Yes" --no-button "No" 3>&1 1>&2 2>&3; then
    echo "Setting the VM as a template"
    qm set $vmid --template
  fi

  echo "VM has been created using $image as the base. Please edit it to your hearts content in the web UI! Also don't forget to ensure that the qemu-guest-agent package is installed."
  exit 0
}

function confirm_choices() {
  local image=$1
  local purpose=$2
  local vmid=$3
  local memory=$4
  local name=$5
  local storage_pool=$6
  local storage_size=$7
  local cpu_type=$8
  local cpu_cores=$9
  local net0=${10}
  local ipconfig0=${11}
  local ostype=${12}
  local username=${13}
  local ssh_pubkeys=${14}
  local enable_guest_agent=${15}

  values_string="\n\nPurpose: $purpose\
    \nVM ID: $vmid\
    \nMemory: $memory MB\
    \nName: $name\
    \nStorage Pool: $storage_pool\
    \nStorage Size: $storage_size GB\
    \nCPU Type: $cpu_type\
    \nCPU Cores: $cpu_cores\
    \nNet0: $net0\
    \nIP Configuration: $ipconfig0\
    \nOS Type: $ostype\
    \nUsername: $username\
    \nTrusted SSH Pubkey File: $ssh_pubkeys
    \nQEMU Guest Agent: $enable_guest_agent"

  if whiptail --backtitle "Proxmox VM Template Creator" --title "Confirmation" \
    --yesno "Please confirm the following settings: \
    $values_string" 40 60 \
    --yes-button "Create" --no-button "Cancel" 3>&1 1>&2 2>&3; then

    echo -e "Confirmation received!\nCreating the VM template with:\
    $values_string"
    create_cloudinit_template "$image" "$purpose" "$vmid" "$memory" "$name" "$storage_pool" "$storage_size" "$cpu_type" "$cpu_cores" "$net0" "$ipconfig0" "$ostype" "$username" "$ssh_pubkeys" "$enable_guest_agent"
  else
    echo -e "Configuration refused!\nRefused values:\
    $values_string"
    echo -e "Aborting creation of the VM template.\nNo changes have been made persistent."
    exit 0
  fi
}

# Collect all the information
purpose=$(get_purpose)
vmid=$(get_vmid)
memory=$(get_memory)
name=$(get_name)
storage_pool=$(get_storage_pool)
storage_size=$(get_storage_size)
cpu_type=$(get_cpu_type)
cpu_cores=$(get_cpu_cores)
net0=$(get_net0)
ipconfig0=$(get_ipconfig0)
ostype=$(get_ostype)
username=$(get_username)
ssh_pubkeys=$(get_ssh_pubkeys)
enable_guest_agent=$(get_guest_agent)

while true; do
  choice=$(whiptail --backtitle "Proxmox VM Template Creator" --title "Config" \
    --menu "Choose an option:" 20 60 10 \
    "1" "Purpose: $purpose" \
    "2" "VM ID: $vmid" \
    "3" "Memory: $memory MB" \
    "4" "Name: $name" \
    "5" "Storage Pool: $storage_pool" \
    "6" "Storage Size: $storage_size GB" \
    "7" "CPU Type: $cpu_type" \
    "8" "CPU Cores: $cpu_cores" \
    "9" "Net0: $net0" \
    "10" "IP Configuration: $ipconfig0" \
    "11" "OS Type: $ostype" \
    "12" "Username: $username" \
    "13" "Trusted SSH Key File: $ssh_pubkeys" \
    "14" "QEMU Guest Agent: $enable_guest_agent" \
    "15" "Create" \
    "0" "Exit" 3>&1 1>&2 2>&3)
  case $choice in
    1) purpose=$(get_purpose $purpose);;
    2) vmid=$(get_vmid $vmid);;
    3) memory=$(get_memory $memory);;
    4) name=$(get_name $name);;
    5) storage_pool=$(get_storage_pool $storage_pool);;
    6) storage_size=$(get_storage_size $storage_size);;
    7) cpu_type=$(get_cpu_type $cpu_type);;
    8) cpu_cores=$(get_cpu_cores $cpu_cores);;
    9) net0=$(get_net0 $net0);;
    10) ipconfig0=$(get_ipconfig0 $ipconfig0);;
    11) ostype=$(get_ostype $ostype);;
    12) username=$(get_username $username);;
    13) ssh_pubkeys=$(get_ssh_pubkeys $ssh_pubkeys);;
    14) enable_guest_agent=$(get_guest_agent $enable_guest_agent);;
    15) confirm_choices "$1" "$purpose" "$vmid" "$memory" "$name" "$storage_pool" "$storage_size" "$cpu_type" "$cpu_cores" "$net0" "$ipconfig0" "$ostype" "$username" "$ssh_pubkeys" "$enable_guest_agent";;
    0) exit 0;;
  esac
done
