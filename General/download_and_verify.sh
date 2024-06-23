#!/usr/bin/env bash

trap "exit 1" ERR

# Optional args: source, checksum, method

# source: The URI of the file to download. Can be a file:// link to avoid downloading. Ensure to unclude the protocol (http://, https://, file://)
source=$1
# checksum: The checksum to compare against. The checksum should be the hash of the file.
checksum=$2
# method: The method to use to calculate the checksum. The available methods are sha512sum, sha256sum, md5sum.
method=$3



known_methods=( "sha512sum" "sha256sum" "md5sum" )
current_dir=$(pwd)
dav_dir="/tmp/download_and_verify/" # Changing this is dangerous as this directory is expected to be created AND DESTROYED by this script.
save_dir="./cloud_images/"

function get_available_methods() {
    trap 'return $?' ERR
    local available_methods=( )
    for method in "${known_methods[@]}"; do
        if command -v $method &>/dev/null; then
        available_methods+=( "$method" )
        fi
    done
    echo $available_methods
}

available_methods=$(get_available_methods)

function get_source() {
    trap 'return $?' ERR
    source=$(whiptail --backtitle "Download and Verify" --title "Download Source" --inputbox "Enter the URI of the file to download (a file:// link will work as well to avoid downloading): " 10 60 "$source" 3>&1 1>&2 2>&3)
    echo $source
}

function get_checksum() {
    trap 'return $?' ERR
    checksum=$(whiptail --backtitle "Download and Verify" --title "Checksum" --inputbox "Enter the checksum to compare against: " 10 60 "$checksum" 3>&1 1>&2 2>&3)
    echo $checksum
}

function get_method() {
    trap 'return $?' ERR
    method=$(whiptail --backtitle "Download and Verify" --title "Method" \
        --menu "Choose an option:" 20 60 10 \
        "sha512sum" "SHA512" \
        "sha256sum" "SHA256" \
        "md5sum" "MD5" 3>&1 1>&2 2>&3)
    echo $method
}

function download() {
    trap 'return $?' ERR
    local source=${1-$source}
    local filename="${source##*/}"
    if [ -d $dav_dir ]; then
        echo "The working directory already exists! This should never be the case as the script will delete the directory. Shutting down to prevent data loss. Directory: $dav_dir" >&2
        echo "You can check the contents of the directory using 'ls $dav_dir' or delete it using 'rm -r $dav_dir'" >&2
        exit 1
    fi
    mkdir -p $dav_dir
    cd $dav_dir
    case "$source" in
        http://*|https://*)
            echo "URI recognized as 'http://' or 'https://'. Downloading..." >&2
            curl -o $filename $source
            ;;
        file://*)
            echo "URI recognized as 'file://'. Linking..." >&2
            if [ ! -f ${source#file://} ]; then
                echo "The file does not exist. Shutting down." >&2
                exit 1
            fi
            ln -s ${source#file://} $filename
            ;;
        *)
            echo "URI not recognized. Shutting down." >&2
            exit 1
            ;;
    esac
    cd $current_dir
    echo $filename
}

function verify() {
    trap 'return $?' ERR
    local method=${1-$method}
    local checksum=${2-$checksum}
    local path=${3}
    local calc_checksum=$($method "$path" | awk '{print $1}')
    if [ "$calc_checksum" = "$checksum" ]; then
        whiptail --backtitle "Download and Verify" --title "Success" --msgbox "Checksum match. Everything good!" 10 60 3>&1 1>&2 2>&3
        echo "All good!" >&2
        return 0
    else
        echo "Checksum mismatch!" >&2
        echo "Expected: $checksum" >&2
        echo "Got: $calc_checksum" >&2
        if $(whiptail --backtitle "Download and Verify" --title "Checksum Mismatch" --yesno "There is a mismatch between the downloaded file's checksum and the expected checksum! Would you like to delete the downloaded file?" 10 60 --yes-button "DELETE" --no-button "KEEP" 3>&1 1>&2 2>&3); then
            rm -rf $dav_dir
            echo "Deleted the working directory." >&2
            exit 1
        else
            echo "Keeping the file. Be careful!" >&2
        fi
    fi
}

function download_and_verify() {
    trap 'return $?' ERR
    local source=$1
    local method=$2
    local checksum=$3
    local filename
    
    if ! filename=$(download "$source"); then
        echo "Download failed. Exiting..." >&2
        exit 1
    fi
    verify "$method" "$checksum" "$dav_dir$filename"
    echo "False"
}

function save() {
    trap 'return $?' ERR
    save_dir=$(whiptail --backtitle "Download and Verify" --title "Save" --inputbox "Enter the directory to save the file to: " 10 60 "$save_dir" 3>&1 1>&2 2>&3)
    if [ ! -d $save_dir ]; then
        echo "The directory does not exist. Creating it..." >&2
        mkdir -p $save_dir
    fi
    echo $(cp -u $dav_dir* $save_dir) >&2
    echo "Saved to $save_dir" >&2
    echo "True"
}

function cleanup() {
    trap 'return $?' ERR
    local saved=$1
    if [ "$saved" = "False" ]; then
        if $(whiptail --backtitle "Download and Verify" --title "Checksum Mismatch" --yesno "The changes were not saved. Would you like to save now?" 10 60 --yes-button "save" --no-button "exit" 3>&1 1>&2 2>&3); then
            saved=$(save)
        fi
    fi
    rm -rf $dav_dir
    echo "Deleted the working directory." >&2
    exit 0
}

while true; do
    choice=$(whiptail --backtitle "Download and Verify" --title "Config" \
        --menu "Choose an option:" 20 60 10 \
        "1" "Source: $source" \
        "2" "Checksum: $checksum" \
        "3" "Method: $method" \
        "4" "Go" \
        "5" "Save" \
        "0" "Exit" 3>&1 1>&2 2>&3)
    case $choice in
        1) source=$(get_source $source);;
        2) checksum=$(get_checksum $checksum);;
        3) method=$(get_method $method);;
        4) saved=$(download_and_verify "$source" "$method" "$checksum");;
        5) saved=$(save);;
        0) cleanup "$saved";;
    esac
done
