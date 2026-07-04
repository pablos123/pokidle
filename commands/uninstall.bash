#!/usr/bin/env bash
# `pokidle uninstall` — remove the systemd unit and symlinks (data left intact).
# shellcheck disable=SC2154  # POKIDLE_* dirs come from the entrypoint

# pokidle_uninstall_help
# Print the `pokidle uninstall` subcommand help.
function pokidle_uninstall_help {
    cat <<'EOF'
pokidle uninstall — disable + remove the systemd unit and bin/asset symlinks.
Config, database and cache are left intact.

Usage:
  pokidle uninstall

Options:
  -h, --help    Show this help
EOF
}

# pokidle_uninstall
# Disable + remove the systemd unit and bin/asset symlinks. Config, DB, and
# cache are left intact.
function pokidle_uninstall {
    case "${1-}" in
        -h | --help | help)
            pokidle_uninstall_help
            return 0
            ;;
        *) ;;
    esac
    # Capture the daemon PID before disabling, so a failed `disable --now`
    # (e.g. no logind/session bus) can't leave an orphan running.
    local main_pid
    main_pid="$(systemctl --user show -p MainPID --value pokidle.service 2>/dev/null)"
    if ! systemctl --user disable --now pokidle.service 2>/dev/null; then
        # disable failed: kill the orphan directly so no trace survives.
        if [[ "${main_pid}" =~ ^[0-9]+$ ]] && ((main_pid > 0)); then
            kill "${main_pid}" 2>/dev/null || :
        fi
    fi
    rm -f -- "${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/pokidle.service"
    rm -f -- "${HOME}/.local/bin/pokidle"
    local comp_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/bash-completion/completions"
    if [[ -L "${comp_dir}/pokidle" ]]; then
        rm -f -- "${comp_dir}/pokidle"
    fi
    local asset
    for asset in biomes notify sounds; do
        local dst="${POKIDLE_DATA_DIR}/${asset}"
        if [[ -L "${dst}" ]]; then
            rm -f -- "${dst}"
        fi
    done
    if ! systemctl --user daemon-reload; then
        : # no logind; non-fatal
    fi
    printf 'uninstalled. Config (%s), DB (%s), cache (%s) left intact.\n' \
        "${POKIDLE_CONFIG_DIR}" "${POKIDLE_DB_PATH}" "${POKIDLE_CACHE_DIR}"
}
