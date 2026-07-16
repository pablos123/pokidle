#!/usr/bin/env bash
# `pokidle setup` — install assets, shipped pools, symlinks and the systemd unit.
# shellcheck disable=SC2154  # POKIDLE_* dirs come from the entrypoint

# pokidle_setup_help
# Print the `pokidle setup` subcommand help.
function pokidle_setup_help {
    cat <<'EOF'
pokidle setup — install config, assets, shipped pools, bin symlinks and the
systemd user unit, then enable + start it.

Usage:
  pokidle setup [--no-enable] [--no-pull]

Options:
  --no-enable   Install only; don't enable/start the service.
  --no-pull     Skip the git pull that refreshes the repo first.
  -h, --help    Show this help
EOF
}

# pokidle_setup [--no-enable]
# Install config, assets, shipped pools, bin symlinks, and the systemd user
# unit, then enable+start it (--no-enable installs only). App-owned artifacts
# (unit + symlinks) are always refreshed; an existing pool cache is left intact
# (use `rebuild-pool` to regenerate pools).
# Setup installs *and* activates the service: pokidle is a daemon, so an
# install that didn't start it would be useless. Pass --no-enable to only
# install the unit (then start it yourself), or `uninstall` to reverse.
function pokidle_setup {
    local -i enable=1
    local -i pull=1
    while (($# > 0)); do
        case "$1" in
            --enable)
                enable=1
                shift
                ;; # back-compat no-op (default)
            --no-enable)
                enable=0
                shift
                ;;
            --no-pull)
                pull=0
                shift
                ;;
            -h | --help | help)
                pokidle_setup_help
                return 0
                ;;
            -*)
                _pokidle_usage_error pokidle_setup_help 'setup: unknown option %s' "$1"
                return
                ;;
            *)
                _pokidle_usage_error pokidle_setup_help 'setup: unexpected argument %s' "$1"
                return
                ;;
        esac
    done

    # Dependency check. systemctl is required: the whole app runs as a
    # systemd user service.
    local -a missing_req=()
    local req
    for req in jq curl sqlite3 notify-send awk systemctl; do
        if ! command -v "${req}" >/dev/null; then
            missing_req+=("${req}")
        fi
    done
    if ((${#missing_req[@]} > 0)); then
        printf 'setup: missing required commands: %s\n' "${missing_req[*]}" >&2
        printf 'setup: install them via your package manager and re-run setup\n' >&2
        return 1
    fi

    # jq >= 1.6 required: list filters use 1.6-only builtins (strflocaltime).
    # An unparseable version string (e.g. a non-jq implementation) only warns —
    # blocking on it would break machines where the filters may still work.
    local jqver
    jqver="$(jq --version 2>/dev/null)"
    if [[ "${jqver}" =~ ^jq-([0-9]+)\.([0-9]+) ]]; then
        if ((BASH_REMATCH[1] == 1 && BASH_REMATCH[2] < 6)); then
            printf 'setup: jq >= 1.6 required, found %s — upgrade jq and re-run setup\n' "${jqver}" >&2
            return 1
        fi
    else
        printf 'setup: warning: cannot parse jq version (%s); jq >= 1.6 is required\n' "${jqver}" >&2
    fi

    # Refresh the repo before installing so one `pokidle setup` both updates
    # and re-installs. --ff-only never rewrites local work; any failure
    # (offline, diverged, not a repo clone) is non-fatal — setup proceeds with
    # the code it already has. The pulled code lands on disk only: this run
    # keeps executing the already-sourced functions, and the systemd restart
    # below picks up the new code.
    if ((pull)) && command -v git >/dev/null &&
        git -C "${POKIDLE_REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if git -C "${POKIDLE_REPO_ROOT}" pull --ff-only; then
            printf 'pulled latest into %s\n' "${POKIDLE_REPO_ROOT}"
        else
            printf 'setup: warning: git pull failed — installing the current checkout\n' >&2
        fi
    fi
    if ! command -v paplay >/dev/null && ! command -v aplay >/dev/null; then
        printf 'setup: optional dep missing: paplay or aplay (sound playback will be skipped)\n'
    fi
    if ! command -v chafa >/dev/null; then
        printf 'setup: optional dep missing: chafa (sprite preview in list/items will be skipped)\n'
    fi

    # Config dir (biome catalog is hardcoded in lib/biome.bash — no file).
    mkdir -p -- "${POKIDLE_CONFIG_DIR}"

    # Data + cache dirs
    mkdir -p -- "${POKIDLE_DATA_DIR}" "${POKIDLE_CACHE_DIR}"

    # Asset symlinks (icons + sounds) into data dir
    local asset
    for asset in biomes notify sounds; do
        local src="${POKIDLE_REPO_ROOT}/share/${asset}"
        local dst="${POKIDLE_DATA_DIR}/${asset}"
        if [[ ! -d "${src}" ]]; then
            continue
        fi
        # App-owned pointer: always refresh so a moved repo never leaves it stale.
        ln -sfn -- "${src}" "${dst}"
        printf 'symlinked %s -> %s\n' "${dst}" "${src}"
    done

    # Seed encounter pools from share/pools so first run skips the cold rebuild.
    # Copies (not symlinks) so later `pokidle rebuild-pool` writes to the cache,
    # not the repo. A shipped pool that is newer than the cached copy (e.g. after
    # `git pull`) overwrites it, so form/pool upgrades land on the next setup
    # without a manual rebuild. A cached pool the user rebuilt themselves is newer
    # than the shipped file, so it is kept.
    local ship_pools="${POKIDLE_REPO_ROOT}/share/pools"
    local cache_pools="${POKIDLE_CACHE_DIR}/pools"
    if [[ -d "${ship_pools}" ]] && compgen -G "${ship_pools}/*.json" >/dev/null; then
        mkdir -p -- "${cache_pools}"
        local -i seeded=0
        local -i skipped=0
        local ship_pool
        for ship_pool in "${ship_pools}"/*.json; do
            local name="${ship_pool##*/}"
            local dst="${cache_pools}/${name}"
            if [[ -f "${dst}" && ! "${ship_pool}" -nt "${dst}" ]]; then
                skipped=$((skipped + 1))
                continue
            fi
            cp -- "${ship_pool}" "${dst}"
            seeded=$((seeded + 1))
        done
        if ((seeded > 0)); then
            printf 'seeded %d pool(s) into %s\n' "${seeded}" "${cache_pools}"
        fi
        if ((skipped > 0)); then
            printf 'kept %d up-to-date pool(s)\n' "${skipped}"
        fi
    fi

    # Seed the Showdown artifacts (holdable items + form-item registry) from
    # share/ so first run skips the network fetch. Newer-wins: a user-rebuilt
    # cache file is kept; a shipped file newer than the cache (e.g. after git
    # pull) overwrites it.
    local artifact
    for artifact in items-holdable.tsv form-items.tsv; do
        local ship_tsv="${POKIDLE_REPO_ROOT}/share/${artifact}"
        local cache_tsv="${POKIDLE_SHOWDOWN_CACHE_DIR}/${artifact}"
        if [[ -f "${ship_tsv}" ]]; then
            mkdir -p -- "${cache_tsv%/*}"
            if [[ -f "${cache_tsv}" && ! "${ship_tsv}" -nt "${cache_tsv}" ]]; then
                printf 'kept up-to-date %s\n' "${artifact}"
            else
                cp -- "${ship_tsv}" "${cache_tsv}"
                printf 'seeded %s into %s\n' "${artifact}" "${cache_tsv%/*}"
            fi
        fi
    done

    # Symlink pokidle into ~/.local/bin
    local bindir="${HOME}/.local/bin"
    mkdir -p -- "${bindir}"
    ln -sf -- "${POKIDLE_REPO_ROOT}/pokidle" "${bindir}/pokidle"
    printf 'symlinked %s -> %s\n' "${bindir}/pokidle" "${POKIDLE_REPO_ROOT}/pokidle"
    case ":${PATH}:" in
        *":${bindir}:"*) ;;
        *) printf 'warning: %s is not in PATH — add it to your shell rc\n' "${bindir}" >&2 ;;
    esac

    # Bash completion. The bash-completion package lazy-loads a file named
    # after the command from the per-user dir below (no root needed).
    local comp_src="${POKIDLE_REPO_ROOT}/share/completions/pokidle.bash"
    local comp_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/bash-completion/completions"
    if [[ -f "${comp_src}" ]]; then
        mkdir -p -- "${comp_dir}"
        ln -sf -- "${comp_src}" "${comp_dir}/pokidle"
        printf 'symlinked %s -> %s\n' "${comp_dir}/pokidle" "${comp_src}"
    fi

    # Systemd unit. The unit is app-owned (generated from the repo copy), so
    # always refresh it — a stale ExecStart from an older install would crash
    # the service. daemon-reload below picks up the new content.
    local sd_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
    mkdir -p -- "${sd_dir}"
    cp -- "${POKIDLE_REPO_ROOT}/systemd/pokidle.service" "${sd_dir}/pokidle.service"
    printf 'wrote %s\n' "${sd_dir}/pokidle.service"

    # Reload systemd user units
    if ! systemctl --user daemon-reload; then
        printf 'warning: systemctl --user daemon-reload failed (no logind?)\n' >&2
    fi

    if ((enable)); then
        if systemctl --user enable --now pokidle.service; then
            printf 'enabled and started pokidle.service\n'
        else
            printf 'enable failed — see journalctl --user -u pokidle\n' >&2
            return 1
        fi
        # Reload a daemon that was already running on stale code: `enable --now`
        # only starts a stopped unit, it does not restart a running one.
        if systemctl --user restart pokidle.service; then
            printf 'restarted pokidle.service (reloaded current code)\n'
        else
            printf 'warning: restart failed — see journalctl --user -u pokidle\n' >&2
        fi
    else
        printf 'installed (not started). next: systemctl --user enable --now pokidle.service\n'
    fi
}
