# The live ISO cannot reach the real root filesystem if BusyBox alternatives
# were not materialized in the initramfs. Fail the build instead of producing
# media that stalls in /init.
cosmopod_validate_initramfs_tools() {
    for tool in cat grep mkdir mount sed sh touch; do
        image_path="${IMAGE_ROOTFS}${bindir}/$tool"
        if [ -L "$image_path" ]; then
            target="$(readlink "$image_path")"
            case "$target" in
                /*) image_path="${IMAGE_ROOTFS}${target}" ;;
                *) image_path="$(dirname "$image_path")/$target" ;;
            esac
        fi
        if [ ! -x "$image_path" ]; then
            bbfatal "Cosmopod initramfs is missing executable ${bindir}/$tool"
        fi
    done
}

ROOTFS_POSTPROCESS_COMMAND:append = " cosmopod_validate_initramfs_tools;"
