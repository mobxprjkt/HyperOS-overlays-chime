#!/bin/bash

set -e

if [ "$1" == "--local-aapt" ]; then
    export LD_LIBRARY_PATH=.
    export PATH=.:$PATH
    shift
fi

script_dir="$(dirname "$(readlink -f -- "$0")")"

if [ "$#" -eq 1 ]; then
    if [ -d "$1" ]; then
        makes="$(find "$1" -name Android.mk -exec readlink -f -- '{}' \;)"
    else
        makes="$(readlink -f -- "$1")"
    fi
else
    cd "$script_dir"
    makes="$(find "$PWD/.." -name Android.mk)"
fi

if ! command -v aapt > /dev/null; then
    export LD_LIBRARY_PATH=.
    export PATH=$PATH:.
fi

if ! command -v aapt > /dev/null && ! command -v aapt2 > /dev/null; then
    echo "Please install aapt or aapt2 (apt install aapt or aapt2)"
    exit 1
fi

cd "$script_dir"

root_dir="$(cd "$script_dir/.." && pwd)"
overlay_mk="$root_dir/overlay.mk"

declare -a product_packages
declare -a vendor_packages

if [ -f "$overlay_mk" ]; then
    current_section=""

    while IFS= read -r line; do
        line="${line%\\}"
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        [[ -z "$line" ]] && continue

        if [[ "$line" == "# product overlay" ]]; then
            current_section="product"
            continue
        elif [[ "$line" == "# vendor overlay" ]]; then
            current_section="vendor"
            continue
        fi

        [[ "$line" == \#* ]] && continue

        if [[ "$current_section" == "product" ]]; then
            product_packages+=("$line")
        elif [[ "$current_section" == "vendor" ]]; then
            vendor_packages+=("$line")
        fi
    done < "$overlay_mk"
else
    echo "Warning: overlay.mk not found, APKs will stay in build/"
fi

contains() {
    local e
    local match="$1"

    shift

    for e; do
        [[ "$e" == "$match" ]] && return 0
    done

    return 1
}

build_with_aapt() {
    local name="$1"
    local path="$2"

    local temp_android_data="$PWD/android_data_$$"

    mkdir -p "$temp_android_data"
    export ANDROID_DATA="$temp_android_data"

    aapt package \
        -f \
        -F "${name}-unsigned.apk" \
        -M "$path/AndroidManifest.xml" \
        -S "$path/res" \
        -I android.jar

    local ret=$?

    rm -rf "$temp_android_data"
    unset ANDROID_DATA

    return $ret
}

build_with_aapt2() {
    local name="$1"
    local path="$2"

    local temp_dir
    temp_dir="$(mktemp -d)"

    trap 'rm -rf "$temp_dir"' RETURN

    aapt2 compile \
        -o "$temp_dir" \
        --dir "$path/res" || return 1

    local flat_files
    flat_files="$(find "$temp_dir" -name "*.flat")"

    if [ -z "$flat_files" ]; then
        echo "No resources compiled for $name"
        return 1
    fi

    aapt2 link \
        -o "${name}-unsigned.apk" \
        -I android.jar \
        --manifest "$path/AndroidManifest.xml" \
        $flat_files || return 1
}

echo "$makes" | while read -r f; do

    [[ -z "$f" ]] && continue

    name="$(sed -nE 's/LOCAL_PACKAGE_NAME.*:\=\s*(.*)/\1/p' "$f")"

    if [ -z "$name" ]; then
        echo "Warning: LOCAL_PACKAGE_NAME not found in $f"
        continue
    fi

    echo ""
    echo "========================================"
    echo "Generating $name"
    echo "========================================"

    path="$(dirname "$f")"

    if build_with_aapt "$name" "$path"; then
        echo "Successfully built with aapt"

    elif command -v aapt2 > /dev/null && build_with_aapt2 "$name" "$path"; then
        echo "Successfully built with aapt2"

    else
        echo "Failed to build $name with both aapt and aapt2"
        exit 1
    fi

    echo "Signing $name.apk"

    LD_LIBRARY_PATH=./signapk/ java -jar signapk/signapk.jar \
        keys/platform.x509.pem \
        keys/platform.pk8 \
        "${name}-unsigned.apk" \
        "${name}.apk"

    rm -f "${name}-unsigned.apk"

    echo "Successfully signed ${name}.apk"

    if [ -f "$overlay_mk" ]; then

        if contains "$name" "${product_packages[@]}"; then
            target_dir="$root_dir/product/overlay"

        elif contains "$name" "${vendor_packages[@]}"; then
            target_dir="$root_dir/vendor/overlay"

        else
            target_dir="$root_dir/build"
        fi

        mkdir -p "$target_dir"

        source_apk="$(readlink -f "${name}.apk")"
        target_apk="$(readlink -f "$target_dir/${name}.apk")"

        echo "Source : $source_apk"
        echo "Target : $target_apk"

        if [ "$source_apk" = "$target_apk" ]; then

            echo "${name}.apk is already in:"
            echo "$target_dir"

        else

            if [ -f "$target_dir/${name}.apk" ]; then
                echo "Removing existing ${name}.apk"
                rm -f "$target_dir/${name}.apk"
            fi

            mv "${name}.apk" "$target_dir/"

            echo "Moved ${name}.apk to:"
            echo "$target_dir"

        fi
    else
        echo "overlay.mk not found"
        echo "${name}.apk will remain in:"
        echo "$root_dir"
    fi

done

echo ""
echo "========================================"
echo "All overlays processed successfully"
echo "========================================"