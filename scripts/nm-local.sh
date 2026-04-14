# Apple Containers uses virtio-fs for ALL filesystems (rootfs, volumes,
# shared folders). virtio-fs can't handle node_modules' deeply nested
# symlink-heavy structure. nm-local bind-mounts a directory from a
# loop-mounted ext4 sparse image onto ./node_modules — bypasses virtio-fs
# without eating RAM. Bind mount is transparent to yarn/npm (looks like a
# real directory). The image persists across container restarts.
NM_IMG=/home/claude/.nm-local.img
NM_MNT=/mnt/nm

_nm_ensure_mount() {
    if ! mountpoint -q "$NM_MNT" 2>/dev/null; then
        if [ ! -f "$NM_IMG" ]; then
            truncate -s 20G "$NM_IMG"
            mkfs.ext4 -q -m 0 "$NM_IMG"
            echo "Created nm-local ext4 image (20G sparse)"
        fi
        sudo mkdir -p "$NM_MNT"
        sudo mount -o loop "$NM_IMG" "$NM_MNT"
        sudo chown claude:claude "$NM_MNT"
    fi
}

nm-local() {
    local hash=$(echo "$PWD" | md5sum | cut -c1-12)
    local local_nm="$NM_MNT/$hash"
    # Already bind-mounted?
    if mountpoint -q node_modules 2>/dev/null; then
        echo "node_modules already mounted → $local_nm"
        return 0
    fi
    _nm_ensure_mount
    mkdir -p "$local_nm"
    # Ensure node_modules directory exists as a mount target
    if [ -L node_modules ]; then
        rm node_modules
    fi
    if [ ! -d node_modules ]; then
        mkdir node_modules
    fi
    sudo mount --bind "$local_nm" node_modules
    echo "node_modules → $local_nm (ext4 bind mount)"
}

# Wipe node_modules for current project and re-mount
nm-clean() {
    local hash=$(echo "$PWD" | md5sum | cut -c1-12)
    local local_nm="$NM_MNT/$hash"
    _nm_ensure_mount
    if mountpoint -q node_modules 2>/dev/null; then
        sudo umount node_modules
    fi
    if [ -d "$local_nm" ]; then
        rm -rf "$local_nm"
        echo "Cleaned $local_nm"
    fi
    mkdir -p "$local_nm"
    if [ ! -d node_modules ]; then
        mkdir node_modules
    fi
    sudo mount --bind "$local_nm" node_modules
    echo "node_modules → $local_nm (ext4 bind mount, clean)"
}

yarn() {
    if [[ "$PWD" == /home/claude/* ]] && ! mountpoint -q node_modules 2>/dev/null; then
        nm-local
    fi
    command yarn "$@"
}

npm() {
    if [[ "$PWD" == /home/claude/* ]] && ! mountpoint -q node_modules 2>/dev/null; then
        nm-local
    fi
    command npm "$@"
}
