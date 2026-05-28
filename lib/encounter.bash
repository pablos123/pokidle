#!/usr/bin/env bash
# Pool build, evo expansion, rolls, stat formulas.
# Depends on pokeapi_get from lib/api.bash.

# All 6 stats in canonical order. Guarded so the readonly global survives the
# repeated re-sourcing the test harness does.
if [[ -z "${ENCOUNTER_STATS:-}" ]]; then
    declare -gra ENCOUNTER_STATS=(hp attack defense special-attack special-defense speed)
fi

# Rarity tier definitions. Tiers listed common-first; ENCOUNTER_TIER_ROLL_WEIGHT[i]
# is the roll weight of ENCOUNTER_TIERS[i] in encounter_roll_pool_entry.
if [[ -z "${ENCOUNTER_TIERS:-}" ]]; then
    declare -gra ENCOUNTER_TIERS=(common uncommon rare very_rare)
    declare -gra ENCOUNTER_TIER_ROLL_WEIGHT=(60 25 12 3)
fi

# Held items the encounter pool can drop, keyed by biome. Every entry is a
# Pokémon Showdown National Dex AG legal slug — i.e. a subset of
# ENCOUNTER_SHOWDOWN_ITEMS — so any drop is automatically valid for export.
# Items are partitioned thematically with each slug assigned to exactly one
# biome. _encounter_item_pool reads this directly (no type-derived
# indirection); see also ENCOUNTER_EVOLUTION_ITEMS_BY_BIOME for the parallel
# evolution-trigger pool that drops alongside but never reaches export.
if [[ -z "${ENCOUNTER_ITEMS_BY_BIOME[*]:-}" ]]; then
    declare -grA ENCOUNTER_ITEMS_BY_BIOME=(
        [forest]="meadow-plate miracle-seed rindo-berry grassium-z grassy-seed rose-incense big-root sceptilite venusaurite decidium-z chesto-berry"
        [jungle]="jaboca-berry rowap-berry micle-berry custap-berry beedrillite sticky-barb binding-band grip-claw"
        [meadow]="aguav-berry iapapa-berry mago-berry figy-berry wiki-berry mental-herb power-herb destiny-knot audinite lopunnite eevium-z"
        [orchard]="silk-scarf chilan-berry normal-gem normalium-z leftovers berry-juice oran-berry sitrus-berry leppa-berry lum-berry snorlium-z"
        [mountain]="stone-plate hard-stone charti-berry rockium-z rocky-helmet cornerstone-mask aerodactylite tyranitarite garchompite"
        [cave]="rock-incense bright-powder covert-cloak houndoominite"
        [crystal-cavern]="ability-shield clear-amulet mirror-herb diancite deep-sea-scale deep-sea-tooth"
        [cliffside]="pretty-feather wide-lens zoom-lens throat-spray pidgeotite lax-incense lycanium-z"
        [desert]="soft-sand earth-plate shuca-berry razor-fang groundium-z smooth-rock terrain-extender cameruptite safety-goggles"
        [badlands]="focus-band iron-ball ring-target loaded-dice"
        [savanna]="thick-club power-anklet power-band power-belt power-bracer power-lens power-weight kangaskhanite"
        [volcano]="charcoal flame-plate heat-rock occa-berry firium-z flame-orb rawst-berry charizardite-x charizardite-y red-orb"
        [forge]="metal-coat iron-plate steelium-z rusted-shield rusted-sword metronome aggronite scizorite steelixite hearthflame-mask babiri-berry"
        [wildfire]="blazikenite adrenaline-orb incinium-z macho-brace"
        [ocean]="mystic-water splash-plate wacan-berry waterium-z shell-bell blue-orb blastoisinite gyaradosite absorb-bulb primarium-z wellspring-mask passho-berry"
        [reef]="wave-incense lustrous-globe lustrous-orb kings-rock"
        [marsh]="poison-barb toxic-plate black-sludge kebia-berry poisonium-z toxic-orb damp-rock pecha-berry swampertite luminous-moss lagging-tail slowbronite"
        [tide-pool]="silver-powder insect-plate tanga-berry buginium-z shed-shell utility-umbrella sea-incense heracronite pinsirite"
        [tundra]="snowball abomasite altarianite float-stone"
        [glacier]="never-melt-ice icicle-plate icy-rock yache-berry icium-z aspear-berry glalitite"
        [frozen-crypt]="banettite"
        [sky]="sharp-beak sky-plate coba-berry flyinium-z latiasite latiosite soul-dew"
        [storm-coast]="manectite air-balloon light-clay"
        [dragons-nest]="dragon-fang draco-plate haban-berry dragonium-z adamant-crystal adamant-orb salamencite kommonium-z"
        [power-plant]="magnet zap-plate cell-battery electrium-z electric-seed cheri-berry ampharosite booster-energy"
        [cyber-lab]="alakazite mewtwonite-x mewtwonite-y metagrossite mewnium-z metal-powder quick-powder wise-glasses blunder-policy bug-memory dark-memory dragon-memory electric-memory fairy-memory fighting-memory fire-memory flying-memory ghost-memory grass-memory ground-memory ice-memory poison-memory psychic-memory rock-memory steel-memory water-memory burn-drive chill-drive douse-drive shock-drive"
        [live-wire]="light-ball aloraichium-z pikanium-z pikashunium-z"
        [ruins]="odd-incense full-incense salac-berry ganlon-berry lansat-berry liechi-berry petaya-berry apicot-berry starf-berry enigma-berry persim-berry griseous-core griseous-orb lunalium-z solganium-z tapunium-z ultranecrozium-z"
        [mind-temple]="twisted-spoon mind-plate payapa-berry psychium-z psychic-seed focus-sash kee-berry maranga-berry room-service medichamite gardevoirite galladite lucarionite"
        [graveyard]="spooky-plate kasib-berry ghostium-z spell-tag absolite marshadium-z"
        [haunted-manor]="gengarite sablenite mimikium-z"
        [wasteland]="black-glasses dread-plate colbur-berry darkinium-z razor-claw scope-lens weakness-policy sharpedonite"
        [dojo]="black-belt fist-plate chople-berry fightinium-z punching-glove muscle-band protective-pads assault-vest quick-claw expert-belt"
        [farm]="leek stick grepa-berry kelpsy-berry lucky-punch"
        [urban]="choice-band choice-scarf choice-specs life-orb heavy-duty-boots eject-button eject-pack red-card"
        [cathedral]="pixie-plate roseli-berry fairy-feather fairium-z misty-seed mawilite white-herb"
    )
fi

# Evolution-trigger items the pool can drop, keyed by biome. These are
# consumed by lib/evolution.bash when an eligible mon evolves, so they live
# beside the held-item pool but stay out of ENCOUNTER_SHOWDOWN_ITEMS — export
# never assigns them. Distribution mirrors where each stone's evolution lines
# would naturally show up.
if [[ -z "${ENCOUNTER_EVOLUTION_ITEMS_BY_BIOME[*]:-}" ]]; then
    declare -grA ENCOUNTER_EVOLUTION_ITEMS_BY_BIOME=(
        [forest]="leaf-stone"
        [meadow]="sun-stone"
        [orchard]="oval-stone"
        [mountain]="protector"
        [volcano]="fire-stone magmarizer"
        [ocean]="water-stone"
        [reef]="dragon-scale prism-scale"
        [glacier]="ice-stone"
        [frozen-crypt]="dusk-stone"
        [power-plant]="thunder-stone electirizer"
        [cyber-lab]="up-grade dubious-disc"
        [ruins]="dawn-stone"
        [graveyard]="reaper-cloth"
        [cathedral]="moon-stone shiny-stone"
    )
fi

# Every held item / berry Pokémon Showdown accepts on a National Dex AG set,
# as a slug->1 set for O(1) membership. National Dex AG is the most permissive
# format, so anything legal here is legal everywhere. The export command gates
# each candidate on it (see encounter_item_is_showdown_legal). Excludes
# Showdown's "Useless items" group: Poké Balls, evolution stones, sweets,
# bottle caps, trade-evo items, TRs, fossils, EV-reducer berries that Showdown
# classifies as useless (hondew/pomeg/qualot/tamato — grepa and kelpsy are in
# the "Items" group and legal). Update when Showdown's legal item list changes.
if [[ -z "${ENCOUNTER_SHOWDOWN_ITEMS[*]:-}" ]]; then
    # Keys are quoted so shfmt does not parse the hyphens as arithmetic
    # subtraction in an indexed-array subscript and rewrite e.g. [zap-plate] to
    # [zap - plate], which bash then stores literally as the key "zap - plate".
    declare -grA ENCOUNTER_SHOWDOWN_ITEMS=(
        # Top-of-list general battle items (Showdown's "Items" header section)
        ["air-balloon"]=1 ["assault-vest"]=1 ["choice-band"]=1 ["choice-scarf"]=1
        ["choice-specs"]=1 ["expert-belt"]=1 ["focus-sash"]=1 ["heavy-duty-boots"]=1
        ["leftovers"]=1 ["life-orb"]=1 ["loaded-dice"]=1 ["mental-herb"]=1
        ["power-herb"]=1 ["rocky-helmet"]=1 ["salac-berry"]=1
        # General held items (alphabetical: ability-shield .. zoom-lens)
        ["ability-shield"]=1 ["absorb-bulb"]=1 ["adrenaline-orb"]=1
        ["aguav-berry"]=1 ["apicot-berry"]=1 ["babiri-berry"]=1 ["berry-juice"]=1
        ["black-belt"]=1 ["black-glasses"]=1 ["black-sludge"]=1
        ["blunder-policy"]=1 ["booster-energy"]=1 ["bright-powder"]=1
        ["cell-battery"]=1 ["charcoal"]=1 ["charti-berry"]=1 ["chesto-berry"]=1
        ["chilan-berry"]=1 ["chople-berry"]=1 ["clear-amulet"]=1 ["coba-berry"]=1
        ["colbur-berry"]=1 ["covert-cloak"]=1 ["custap-berry"]=1 ["damp-rock"]=1
        ["draco-plate"]=1 ["dragon-fang"]=1 ["dread-plate"]=1 ["earth-plate"]=1
        ["eject-button"]=1 ["eject-pack"]=1 ["electric-seed"]=1
        ["fairy-feather"]=1 ["figy-berry"]=1 ["fist-plate"]=1 ["flame-orb"]=1
        ["flame-plate"]=1 ["full-incense"]=1 ["ganlon-berry"]=1 ["grassy-seed"]=1
        ["grepa-berry"]=1 ["grip-claw"]=1 ["haban-berry"]=1 ["hard-stone"]=1
        ["heat-rock"]=1 ["iapapa-berry"]=1 ["icicle-plate"]=1 ["icy-rock"]=1
        ["insect-plate"]=1 ["iron-plate"]=1 ["kasib-berry"]=1 ["kebia-berry"]=1
        ["kee-berry"]=1 ["kelpsy-berry"]=1 ["kings-rock"]=1 ["lagging-tail"]=1
        ["lansat-berry"]=1 ["lax-incense"]=1 ["leppa-berry"]=1 ["liechi-berry"]=1
        ["light-clay"]=1 ["lum-berry"]=1 ["luminous-moss"]=1 ["magnet"]=1
        ["mago-berry"]=1 ["maranga-berry"]=1 ["meadow-plate"]=1 ["metal-coat"]=1
        ["metronome"]=1 ["micle-berry"]=1 ["mind-plate"]=1 ["miracle-seed"]=1
        ["mirror-herb"]=1 ["misty-seed"]=1 ["muscle-band"]=1 ["mystic-water"]=1
        ["never-melt-ice"]=1 ["normal-gem"]=1 ["occa-berry"]=1 ["odd-incense"]=1
        ["passho-berry"]=1 ["payapa-berry"]=1 ["petaya-berry"]=1 ["pixie-plate"]=1
        ["poison-barb"]=1 ["pretty-feather"]=1 ["protective-pads"]=1
        ["psychic-seed"]=1 ["punching-glove"]=1 ["quick-claw"]=1 ["razor-claw"]=1
        ["razor-fang"]=1 ["red-card"]=1 ["rindo-berry"]=1 ["rock-incense"]=1
        ["room-service"]=1 ["rose-incense"]=1 ["roseli-berry"]=1
        ["safety-goggles"]=1 ["scope-lens"]=1 ["sea-incense"]=1 ["sharp-beak"]=1
        ["shed-shell"]=1 ["shell-bell"]=1 ["shuca-berry"]=1 ["silk-scarf"]=1
        ["silver-powder"]=1 ["sitrus-berry"]=1 ["sky-plate"]=1 ["smooth-rock"]=1
        ["snowball"]=1 ["soft-sand"]=1 ["spell-tag"]=1 ["splash-plate"]=1
        ["spooky-plate"]=1 ["starf-berry"]=1 ["sticky-barb"]=1 ["stone-plate"]=1
        ["tanga-berry"]=1 ["terrain-extender"]=1 ["throat-spray"]=1
        ["toxic-orb"]=1 ["toxic-plate"]=1 ["twisted-spoon"]=1
        ["utility-umbrella"]=1 ["wacan-berry"]=1 ["wave-incense"]=1
        ["weakness-policy"]=1 ["white-herb"]=1 ["wide-lens"]=1 ["wiki-berry"]=1
        ["wise-glasses"]=1 ["yache-berry"]=1 ["zap-plate"]=1 ["zoom-lens"]=1
        # Type-locked Z-crystals
        ["buginium-z"]=1 ["darkinium-z"]=1 ["dragonium-z"]=1 ["electrium-z"]=1
        ["fairium-z"]=1 ["fightinium-z"]=1 ["firium-z"]=1 ["flyinium-z"]=1
        ["ghostium-z"]=1 ["grassium-z"]=1 ["groundium-z"]=1 ["icium-z"]=1
        ["normalium-z"]=1 ["poisonium-z"]=1 ["psychium-z"]=1 ["rockium-z"]=1
        ["steelium-z"]=1 ["waterium-z"]=1
        # Silvally Memories (Multi-Attack type changers)
        ["bug-memory"]=1 ["dark-memory"]=1 ["dragon-memory"]=1 ["electric-memory"]=1
        ["fairy-memory"]=1 ["fighting-memory"]=1 ["fire-memory"]=1 ["flying-memory"]=1
        ["ghost-memory"]=1 ["grass-memory"]=1 ["ground-memory"]=1 ["ice-memory"]=1
        ["poison-memory"]=1 ["psychic-memory"]=1 ["rock-memory"]=1 ["steel-memory"]=1
        ["water-memory"]=1
        # Genesect Drives
        ["burn-drive"]=1 ["chill-drive"]=1 ["douse-drive"]=1 ["shock-drive"]=1
        # Mega Stones
        ["abomasite"]=1 ["absolite"]=1 ["aerodactylite"]=1 ["aggronite"]=1
        ["alakazite"]=1 ["altarianite"]=1 ["ampharosite"]=1 ["audinite"]=1
        ["banettite"]=1 ["beedrillite"]=1 ["blastoisinite"]=1 ["blazikenite"]=1
        ["cameruptite"]=1 ["charizardite-x"]=1 ["charizardite-y"]=1 ["diancite"]=1
        ["galladite"]=1 ["garchompite"]=1 ["gardevoirite"]=1 ["gengarite"]=1
        ["glalitite"]=1 ["gyaradosite"]=1 ["heracronite"]=1 ["houndoominite"]=1
        ["kangaskhanite"]=1 ["latiasite"]=1 ["latiosite"]=1 ["lopunnite"]=1
        ["lucarionite"]=1 ["manectite"]=1 ["mawilite"]=1 ["medichamite"]=1
        ["metagrossite"]=1 ["mewtwonite-x"]=1 ["mewtwonite-y"]=1 ["pidgeotite"]=1
        ["pinsirite"]=1 ["sablenite"]=1 ["salamencite"]=1 ["sceptilite"]=1
        ["scizorite"]=1 ["sharpedonite"]=1 ["slowbronite"]=1 ["steelixite"]=1
        ["swampertite"]=1 ["tyranitarite"]=1 ["venusaurite"]=1
        # Pokémon-locked Z-crystals
        ["aloraichium-z"]=1 ["decidium-z"]=1 ["eevium-z"]=1 ["incinium-z"]=1
        ["kommonium-z"]=1 ["lunalium-z"]=1 ["lycanium-z"]=1 ["marshadium-z"]=1
        ["mewnium-z"]=1 ["mimikium-z"]=1 ["pikanium-z"]=1 ["pikashunium-z"]=1
        ["primarium-z"]=1 ["snorlium-z"]=1 ["solganium-z"]=1 ["tapunium-z"]=1
        ["ultranecrozium-z"]=1
        # Pokémon-specific signature items
        ["adamant-crystal"]=1 ["adamant-orb"]=1 ["blue-orb"]=1
        ["cornerstone-mask"]=1 ["deep-sea-scale"]=1 ["deep-sea-tooth"]=1
        ["griseous-core"]=1 ["griseous-orb"]=1 ["hearthflame-mask"]=1
        ["leek"]=1 ["light-ball"]=1 ["lucky-punch"]=1 ["lustrous-globe"]=1
        ["lustrous-orb"]=1 ["metal-powder"]=1 ["quick-powder"]=1 ["red-orb"]=1
        ["rusted-shield"]=1 ["rusted-sword"]=1 ["soul-dew"]=1 ["stick"]=1
        ["thick-club"]=1 ["wellspring-mask"]=1
        # Usually useless but Showdown-legal (status berries, training braces,
        # gimmick items)
        ["aspear-berry"]=1 ["big-root"]=1 ["binding-band"]=1 ["cheri-berry"]=1
        ["destiny-knot"]=1 ["enigma-berry"]=1 ["float-stone"]=1 ["focus-band"]=1
        ["iron-ball"]=1 ["jaboca-berry"]=1 ["macho-brace"]=1 ["oran-berry"]=1
        ["pecha-berry"]=1 ["persim-berry"]=1 ["power-anklet"]=1 ["power-band"]=1
        ["power-belt"]=1 ["power-bracer"]=1 ["power-lens"]=1 ["power-weight"]=1
        ["rawst-berry"]=1 ["ring-target"]=1 ["rowap-berry"]=1
    )
fi

# _json_int_array <space-separated-ints>
# Print a JSON array literal from space-separated integers.
function _json_int_array {
    local -a parts
    read -ra parts <<<"$1"
    local IFS=,
    printf '[%s]' "${parts[*]}"
}

# encounter_item_is_evolution <name>
# True (exit 0) if <name> is an evolution-trigger item (consumed on use).
# Walks every biome bucket in ENCOUNTER_EVOLUTION_ITEMS_BY_BIOME; cheap because
# the table has ~20 items total.
function encounter_item_is_evolution {
    local name="$1"
    local b
    for b in "${!ENCOUNTER_EVOLUTION_ITEMS_BY_BIOME[@]}"; do
        local -a items
        read -ra items <<<"${ENCOUNTER_EVOLUTION_ITEMS_BY_BIOME[${b}]}"
        local it
        for it in "${items[@]}"; do
            if [[ "${it}" == "${name}" ]]; then
                return 0
            fi
        done
    done
    return 1
}

# encounter_item_is_showdown_legal <name>
# True (exit 0) if <name> is a held item/berry that Pokémon Showdown accepts on
# a set. The export command gates every candidate on this so a team is always
# importable, regardless of what historical drops are stored. The set is the
# union of every holdable item and battle berry in Showdown's item dex (the
# "Useless items" group — Poké Balls, evolution stones, sweets, bottle caps,
# trade-evo items — is intentionally excluded).
function encounter_item_is_showdown_legal {
    [[ -n "${ENCOUNTER_SHOWDOWN_ITEMS[$1]:-}" ]]
}

# encounter_tier_for_capture_rate <capture_rate>
# capture_rate: PokeAPI value 0..255. Higher = easier to catch = more common.
# Thresholds 150/75/25 bucket into common/uncommon/rare/very_rare.
function encounter_tier_for_capture_rate {
    local -i cr="$1"
    if ((cr >= 150)); then
        printf 'common'
    elif ((cr >= 75)); then
        printf 'uncommon'
    elif ((cr >= 25)); then
        printf 'rare'
    else
        printf 'very_rare'
    fi
}

# encounter_natures_list
# Print every nature name, one per line. Returns 1 on fetch failure.
function encounter_natures_list {
    local body
    if ! body="$(pokeapi_get "nature?limit=100")"; then
        return 1
    fi
    jq -r '.results[].name' <<<"${body}"
}

# encounter_nature_mods <nature>
# Print 6 space-separated floats: nature_mod for hp atk def spa spd spe.
function encounter_nature_mods {
    local nature="$1"
    local nat
    if ! nat="$(pokeapi_get "nature/${nature}")"; then
        return 1
    fi
    local inc
    inc="$(jq -r '.increased_stat.name // ""' <<<"${nat}")"
    local dec
    dec="$(jq -r '.decreased_stat.name // ""' <<<"${nat}")"

    local -a out=()
    local s
    for s in "${ENCOUNTER_STATS[@]}"; do
        if [[ "${s}" == "${inc}" ]]; then
            out+=("1.1")
        elif [[ "${s}" == "${dec}" ]]; then
            out+=("0.9")
        else
            out+=("1.0")
        fi
    done
    printf '%s' "${out[*]}"
}

# encounter_roll_ivs
# Print 6 space-separated IVs, each rolled uniformly in 0..31.
function encounter_roll_ivs {
    local -a out=()
    local -i i
    for i in {0..5}; do
        out+=("$((RANDOM % 32))")
    done
    printf '%s' "${out[*]}"
}

# encounter_ev_split <total>
# Distribute <total> EVs across 6 stats (cap 252 each, chunks of 4) and print
# the 6 space-separated values.
function encounter_ev_split {
    local -i total="$1"
    local -a evs=(0 0 0 0 0 0)
    local -i remaining="${total}"
    local -i guard=0
    # Allocate in chunks of 4 (one chunk = +1 effective stat point).
    while ((remaining >= 4)); do
        if ((guard++ > 10000)); then
            break
        fi
        local -i i=$((RANDOM % 6))
        local -i headroom=$((252 - evs[i]))
        if ((headroom < 4)); then
            local -i all=1
            local j
            for j in "${evs[@]}"; do
                if ((j < 252)); then
                    all=0
                    break
                fi
            done
            if ((all)); then
                break
            fi
            continue
        fi
        local -i cap_chunks=$((headroom / 4))
        local -i rem_chunks=$((remaining / 4))
        if ((cap_chunks > rem_chunks)); then
            cap_chunks=${rem_chunks}
        fi
        local -i delta_chunks=$(((RANDOM % cap_chunks) + 1))
        local -i delta=$((delta_chunks * 4))
        evs[i]=$((evs[i] + delta))
        remaining=$((remaining - delta))
    done
    # 510 is not a multiple of 4: drop the 1-3 leftover on a stat with room
    # (matches in-game behavior — last bits are wasted but the total is preserved).
    if ((remaining > 0)); then
        local -i tries=0
        local -i i
        while ((tries < 100)); do
            i=$((RANDOM % 6))
            if ((evs[i] + remaining <= 252)); then
                evs[i]=$((evs[i] + remaining))
                break
            fi
            ((tries++))
        done
    fi
    printf '%s' "${evs[*]}"
}

# encounter_roll_level <lo> <hi>
# Print a random integer level in the inclusive range [lo, hi].
function encounter_roll_level {
    local -i lo="$1"
    local -i hi="$2"
    local -i span=$((hi - lo + 1))
    printf '%d' "$((lo + RANDOM % span))"
}

# encounter_compute_stat <stat-name> <base> <iv> <ev> <level> <nature_mod>
# stat-name in {hp, attack, defense, special-attack, special-defense, speed}.
# nature_mod is "0.9", "1.0", or "1.1". Prints the final stat value.
function encounter_compute_stat {
    local stat="$1"
    local -i base="$2"
    local -i iv="$3"
    local -i ev="$4"
    local -i level="$5"
    local nm="$6"
    # core = floor(((2*base + iv + floor(ev/4)) * level) / 100)
    local -i ev_q=$((ev / 4))
    local -i core=$(((2 * base + iv + ev_q) * level / 100))
    if [[ "${stat}" == "hp" ]]; then
        printf '%d' "$((core + level + 10))"
        return
    fi
    # other = floor((core + 5) * nm)
    case "${nm}" in
        "1.0") printf '%d' "$((core + 5))" ;;
        "1.1") printf '%d' "$(((core + 5) * 110 / 100))" ;;
        "0.9") printf '%d' "$(((core + 5) * 90 / 100))" ;;
        *)
            printf 'encounter_compute_stat: bad nature_mod %s\n' "${nm}" >&2
            return 1
            ;;
    esac
}

# encounter_compute_all_stats <base_json> <ivs_str> <evs_str> <level> <mods_str>
# base_json is .stats[] from /pokemon (array of {base_stat, stat:{name}}).
# Prints "hp atk def spa spd spe" final stats. Returns 1 if a base stat is missing.
function encounter_compute_all_stats {
    local base_json="$1"
    local ivs_str="$2"
    local evs_str="$3"
    local level="$4"
    local mods_str="$5"
    local -a ivs
    read -ra ivs <<<"${ivs_str}"
    local -a evs
    read -ra evs <<<"${evs_str}"
    local -a mods
    read -ra mods <<<"${mods_str}"
    local -a out=()
    local -i i
    for i in {0..5}; do
        local stat="${ENCOUNTER_STATS[i]}"
        local base
        base="$(jq -r --arg s "${stat}" '.[] | select(.stat.name==$s) | .base_stat' <<<"${base_json}")"
        if [[ -z "${base}" || "${base}" == "null" ]]; then
            printf 'encounter_compute_all_stats: missing base for %s\n' "${stat}" >&2
            return 1
        fi
        out+=("$(encounter_compute_stat "${stat}" "${base}" "${ivs[i]}" "${evs[i]}" "${level}" "${mods[i]}")")
    done
    printf '%s' "${out[*]}"
}

# encounter_roll_ability <species>
# Roll an ability. Prints JSON {name, is_hidden}. Returns 1 on fetch failure.
function encounter_roll_ability {
    local species="$1"
    local poke
    if ! poke="$(pokeapi_get "pokemon/${species}")"; then
        return 1
    fi
    local -i hidden_rate="${POKIDLE_HIDDEN_ABILITY_RATE:-5}"

    local hidden_arr
    hidden_arr="$(jq '[.abilities[] | select(.is_hidden==true) | {name: .ability.name, is_hidden: true}]' <<<"${poke}")"
    local normal_arr
    normal_arr="$(jq '[.abilities[] | select(.is_hidden==false) | {name: .ability.name, is_hidden: false}]' <<<"${poke}")"

    local -i roll=$((RANDOM % 100))
    local -i hidden_len
    hidden_len="$(jq 'length' <<<"${hidden_arr}")"
    local pool
    if ((roll < hidden_rate && hidden_len > 0)); then
        pool="${hidden_arr}"
    else
        pool="${normal_arr}"
    fi
    local -i pool_len
    pool_len="$(jq 'length' <<<"${pool}")"
    if ((pool_len == 0)); then
        pool="${hidden_arr}" # last-resort
    fi

    local -i n
    n="$(jq 'length' <<<"${pool}")"
    local -i idx=$((RANDOM % n))
    jq -c ".[${idx}]" <<<"${pool}"
}

# encounter_roll_moves <species> <level>
# Roll up to 4 moves from the union of (level-up + machine + egg + tutor) where
# level_learned_at <= level. Prints a JSON array of move-name strings.
function encounter_roll_moves {
    local species="$1"
    local level="$2"
    local poke
    if ! poke="$(pokeapi_get "pokemon/${species}")"; then
        return 1
    fi

    local candidates
    candidates="$(jq -r --argjson lvl "${level}" '
        [
          .moves[] |
          .move.name as $name |
          .version_group_details[] |
          select(
            (.move_learn_method.name | IN("level-up","machine","egg","tutor")) and
            (.level_learned_at <= $lvl)
          ) | $name
        ] | unique | .[]
    ' <<<"${poke}")"

    local -a arr=()
    local m
    while IFS= read -r m; do
        if [[ -n "${m}" ]]; then
            arr+=("${m}")
        fi
    done <<<"${candidates}"

    local -i n="${#arr[@]}"
    if ((n == 0)); then
        printf '[]'
        return
    fi

    # shuffle and take 4
    local -a picked=()
    while ((${#picked[@]} < 4 && ${#arr[@]} > 0)); do
        local -i idx=$((RANDOM % ${#arr[@]}))
        picked+=("${arr[idx]}")
        # remove arr[idx]
        arr=("${arr[@]:0:idx}" "${arr[@]:idx+1}")
    done

    # emit JSON array
    printf '['
    local sep=""
    local i
    for i in "${picked[@]}"; do
        printf '%s"%s"' "${sep}" "${i}"
        sep=","
    done
    printf ']'
}

# encounter_roll_gender <species>
# Print "F", "M", or "genderless" based on the species' gender_rate.
function encounter_roll_gender {
    local species="$1"
    local spec
    if ! spec="$(pokeapi_get "pokemon-species/${species}")"; then
        return 1
    fi
    local gr
    gr="$(jq -r '.gender_rate' <<<"${spec}")"
    if [[ "${gr}" == "-1" ]]; then
        printf 'genderless'
        return
    fi
    # gr = female chance / 8. Roll 0..7.
    local -i roll=$((RANDOM % 8))
    if ((roll < gr)); then
        printf 'F'
    else
        printf 'M'
    fi
}

# encounter_roll_shiny
# Print "1" with probability 1/POKIDLE_SHINY_RATE (default 1024), else "0".
function encounter_roll_shiny {
    local -i rate="${POKIDLE_SHINY_RATE:-1024}"
    local -i roll=$((RANDOM * 32768 + RANDOM))
    if ((roll % rate == 0)); then
        printf '1'
    else
        printf '0'
    fi
}

# encounter_roll_held_berry <biome_id>
# Print a berry name with probability POKIDLE_BERRY_RATE% (default 15), else
# "null". Also "null" if the biome has no berries.
function encounter_roll_held_berry {
    local biome_id="$1"
    local -i rate="${POKIDLE_BERRY_RATE:-15}"
    local -i roll=$((RANDOM % 100))
    if ((roll >= rate)); then
        printf 'null'
        return
    fi
    local p
    p="$(encounter_pool_path "${biome_id}")"
    if [[ ! -f "${p}" ]]; then
        printf 'null'
        return
    fi
    local -a berries
    mapfile -t berries < <(jq -r '.berries[]?' "${p}")
    local -i n="${#berries[@]}"
    if ((n == 0)); then
        printf 'null'
        return
    fi
    local -i idx=$((RANDOM % n))
    printf '%s' "${berries[idx]}"
}

# encounter_species_for_name <name>
# Resolve a name (a bare species OR a variety-suffixed Pokemon name like
# shaymin-land/wormadam-plant/deoxys-attack) to its bare species name. Try
# /pokemon-species/<name>; on 404 fall back to /pokemon/<name>.species.name.
# Empty on total failure.
function encounter_species_for_name {
    local name="$1"
    if pokeapi_get "pokemon-species/${name}" >/dev/null 2>&1; then
        printf '%s' "${name}"
        return 0
    fi
    local poke
    if ! poke="$(pokeapi_get "pokemon/${name}" 2>/dev/null)"; then
        return 1
    fi
    jq -r '.species.name // empty' <<<"${poke}"
}

# encounter_pick_variety <species>
# Print a random variety name from /pokemon-species/<sp>.varieties[]. Falls
# back to <sp> if the species lookup fails or the varieties array is empty.
function encounter_pick_variety {
    local sp="$1"
    local spec
    if ! spec="$(pokeapi_get "pokemon-species/${sp}" 2>/dev/null)"; then
        printf '%s' "${sp}"
        return
    fi
    local -i n
    n="$(jq '(.varieties // []) | length' <<<"${spec}")"
    if ((n == 0)); then
        printf '%s' "${sp}"
        return
    fi
    local -i idx=$((RANDOM % n))
    local name
    name="$(jq -r --argjson i "${idx}" '.varieties[$i].pokemon.name // empty' <<<"${spec}")"
    if [[ -z "${name}" || "${name}" == "null" ]]; then
        name="${sp}"
    fi
    printf '%s' "${name}"
}

# encounter_walk_chain <chain_json>
# Print a JSON array of {species, stage_idx, min_level_evo (nullable)}.
# stage_idx 0 for root; root has no min_level_evo.
function encounter_walk_chain {
    local chain_json="$1"
    jq -c '
        def walk($node; $stage):
            ($node.evolution_details[0].min_level // null) as $ml |
            { species: $node.species.name, stage_idx: $stage, min_level_evo: $ml },
            ($node.evolves_to[]? | walk(.; $stage + 1));
        [walk(.chain; 0)]
    ' <<<"${chain_json}"
}

# encounter_build_pool <biome_id>
# Print {tiers:{common:[],uncommon:[],rare:[],very_rare:[]}, berries:[...]}.
# Pool = direct union of /type/<t> for each biome.types[]; legendaries/mythicals
# dropped; each species tiered by its own capture_rate. min/max levels come from
# the species' own evolution_details.min_level (root → 5-15; non-level evos like
# stones → 5+15*stage_idx). Returns 1 on fetch failure.
function encounter_build_pool {
    local biome_id="$1"
    if ! command -v biome_types_for >/dev/null; then
        # shellcheck disable=SC1091,SC2154  # POKIDLE_REPO_ROOT exported by the pokidle entrypoint
        source "${POKIDLE_REPO_ROOT}/lib/biome.bash"
    fi

    # 1. Union pokemon-resource names across biome.types[].
    local raw_names='[]'
    local types_list
    if ! types_list="$(biome_types_for "${biome_id}")"; then
        return 1
    fi
    local t
    while IFS= read -r t; do
        if [[ -z "${t}" ]]; then
            continue
        fi
        local type_body
        if ! type_body="$(pokeapi_get "type/${t}")"; then
            return 1
        fi
        raw_names="$(jq -c --argjson e "$(jq -c '[.pokemon[].pokemon.name]' <<<"${type_body}")" \
            '. + $e | unique' <<<"${raw_names}")"
    done <<<"${types_list}"

    # 1b. /type/<t> returns variety-suffixed names (e.g. wormadam-plant,
    #     shaymin-land, deoxys-attack) for forme-bearing species. Collapse
    #     each name to its bare pokemon-species name and dedup. Without this,
    #     /pokemon-species/<variety> 404s and the species silently drops.
    local species_union='[]'
    local raw_name
    while IFS= read -r raw_name; do
        if [[ -z "${raw_name}" ]]; then
            continue
        fi
        local bare
        if ! bare="$(encounter_species_for_name "${raw_name}" 2>/dev/null)"; then
            continue
        fi
        if [[ -z "${bare}" ]]; then
            continue
        fi
        species_union="$(jq -c --arg s "${bare}" '. + [$s] | unique' <<<"${species_union}")"
    done < <(jq -r '.[]' <<<"${raw_names}")

    # 2. Per species: filter legendary/mythical, tier by own capture_rate,
    #    look up min/max via evolution chain (chain JSON cached by id).
    local -A chain_cache=()
    local flat='[]'
    local sp
    while IFS= read -r sp; do
        if [[ -z "${sp}" ]]; then
            continue
        fi
        local spec
        if ! spec="$(pokeapi_get "pokemon-species/${sp}" 2>/dev/null)"; then
            continue
        fi
        local is_leg
        is_leg="$(jq -r '.is_legendary // false' <<<"${spec}")"
        local is_myth
        is_myth="$(jq -r '.is_mythical // false' <<<"${spec}")"
        if [[ "${is_leg}" == "true" || "${is_myth}" == "true" ]]; then
            continue
        fi

        local cr
        cr="$(jq -r '.capture_rate // 45' <<<"${spec}")"
        local tier
        tier="$(encounter_tier_for_capture_rate "${cr}")"

        local emin="${POKIDLE_ENCOUNTER_LEVEL_MIN:-5}"
        local emax="${POKIDLE_ENCOUNTER_LEVEL_MAX:-15}"
        local chain_url
        chain_url="$(jq -r '.evolution_chain.url // empty' <<<"${spec}")"
        if [[ -n "${chain_url}" && "${chain_url}" != "null" ]]; then
            local chain_id="${chain_url%/}"
            chain_id="${chain_id##*/}"
            local chain="${chain_cache[${chain_id}]:-}"
            if [[ -z "${chain}" ]]; then
                if ! chain="$(pokeapi_get "evolution-chain/${chain_id}" 2>/dev/null)"; then
                    chain=""
                fi
                if [[ -n "${chain}" ]]; then
                    chain_cache[${chain_id}]="${chain}"
                fi
            fi
            if [[ -n "${chain}" ]]; then
                local stages
                stages="$(encounter_walk_chain "${chain}")"
                local entry
                entry="$(jq -c --arg sp "${sp}" '.[] | select(.species==$sp)' <<<"${stages}")"
                if [[ -n "${entry}" ]]; then
                    local stage
                    stage="$(jq -r '.stage_idx' <<<"${entry}")"
                    local ml
                    ml="$(jq -r '.min_level_evo // empty' <<<"${entry}")"
                    if [[ -n "${ml}" && "${ml}" != "null" ]]; then
                        emin="${ml}"
                        emax=$((ml + 10))
                    elif ((stage > 0)); then
                        emin=$((5 + 15 * stage))
                        emax=$((emin + 10))
                    fi
                fi
            fi
        fi

        flat="$(jq -c --arg sp "${sp}" --argjson mn "${emin}" --argjson mx "${emax}" --arg tier "${tier}" \
            '. + [{species:$sp, min:$mn, max:$mx, tier:$tier}]' <<<"${flat}")"
    done < <(jq -r '.[]' <<<"${species_union}")

    # 3. Bucket into tier arrays.
    local tiered
    tiered="$(jq -c --argjson tiers '["common","uncommon","rare","very_rare"]' '
        ($tiers | map({(.) : []}) | add) as $empty
        | reduce .[] as $e ($empty;
            .[$e.tier] += [{species: $e.species, min: $e.min, max: $e.max}]
          )
    ' <<<"${flat}")"

    # 4. Derive berries by natural_gift_type intersection with biome.types.
    local berries_json='[]'
    local berry_list
    berry_list="$(pokeapi_get "berry?limit=100" | jq -r '.results[].name')"
    local types_array
    types_array="$(biome_types_for "${biome_id}" | jq -R . | jq -s -c .)"
    local berry
    while IFS= read -r berry; do
        if [[ -z "${berry}" ]]; then
            continue
        fi
        local bj
        if ! bj="$(pokeapi_get "berry/${berry}" 2>/dev/null)"; then
            continue
        fi
        local ngt
        ngt="$(jq -r '.natural_gift_type.name // ""' <<<"${bj}")"
        if [[ -z "${ngt}" ]]; then
            continue
        fi
        if printf '"%s"' "${ngt}" | jq -e --argjson types "${types_array}" '. as $t | $types | index($t) != null' >/dev/null; then
            berries_json="$(jq -c --arg b "${berry}" '. + [$b]' <<<"${berries_json}")"
        fi
    done <<<"${berry_list}"

    jq -c -n --argjson tiers "${tiered}" --argjson berries "${berries_json}" \
        '{tiers: $tiers, berries: $berries}'
}

# encounter_pool_path <biome>
# Print the cache file path for a biome's pool.
function encounter_pool_path {
    local biome="$1"
    printf '%s/pools/%s.json' "${POKIDLE_CACHE_DIR:-${HOME}/.cache/pokidle}" "${biome}"
}

# encounter_pool_save <biome> <body_json>
# Write a versioned pool file (schema 3) for biome from the build_pool output.
function encounter_pool_save {
    local biome="$1"
    local body_json="$2"
    local p
    p="$(encounter_pool_path "${biome}")"
    mkdir -p -- "${p%/*}"
    local body
    body="$(jq -c -n --arg b "${biome}" --arg ts "$(date -u +%FT%TZ)" \
        --argjson p "${body_json}" '{
        biome: $b,
        built_at: $ts,
        schema: 3,
        tiers: $p.tiers,
        berries: ($p.berries // [])
    }')"
    printf '%s' "${body}" >"${p}"
}

# encounter_pool_load <biome>
# Print the cached pool JSON for biome; return 1 if no pool exists.
function encounter_pool_load {
    local biome="$1"
    local p
    p="$(encounter_pool_path "${biome}")"
    if [[ ! -f "${p}" ]]; then
        printf 'encounter_pool_load: no pool for %s\n' "${biome}" >&2
        return 1
    fi
    cat "${p}"
}

# encounter_roll_pool_entry <pool_json>
# Roll a pool entry from a pool {schema:3, tiers:{...}}. Pick a tier by fixed
# weights, walk forward to the next non-empty tier on an empty bucket, then pick
# uniformly inside. Returns 1 if every tier is empty.
function encounter_roll_pool_entry {
    local pool="$1"
    local -i roll=$((RANDOM % 100))
    local -i cum=0
    local -i tier_idx=0
    local -i i
    for i in 0 1 2 3; do
        cum=$((cum + ENCOUNTER_TIER_ROLL_WEIGHT[i]))
        if ((roll < cum)); then
            tier_idx=${i}
            break
        fi
    done
    local -i step
    local name
    local -i n
    local -i arr_idx
    for step in 0 1 2 3; do
        name="${ENCOUNTER_TIERS[$(((tier_idx + step) % 4))]}"
        n="$(jq --arg t "${name}" '.tiers[$t] | length' <<<"${pool}")"
        if ((n > 0)); then
            arr_idx=$((RANDOM % n))
            jq -c --arg t "${name}" --argjson i "${arr_idx}" '.tiers[$t][$i]' <<<"${pool}"
            return 0
        fi
    done
    printf 'encounter_roll_pool_entry: pool has no entries in any tier\n' >&2
    return 1
}

# encounter_roll_pokemon <entry_json> <biome_id>
# Print a JSON encounter object ready for db_insert_encounter (after adding
# session_id, encountered_at, sprite_path). Returns 1 if any roll step fails.
function encounter_roll_pokemon {
    local entry="$1"
    local biome="$2"
    local sp
    sp="$(jq -r '.species' <<<"${entry}")"
    local lo
    lo="$(jq -r '.min' <<<"${entry}")"
    local hi
    hi="$(jq -r '.max' <<<"${entry}")"

    # Pick a random variety. For most species variety == bare species name;
    # for forme-bearing ones (wormadam, lycanroc, oricorio, …) this rolls
    # between the available formes. /pokemon and ability/move fetches use the
    # variety. The encounter's species field stays bare.
    local variety
    variety="$(encounter_pick_variety "${sp}")"
    if [[ -z "${variety}" || "${variety}" == "null" ]]; then
        variety="${sp}"
    fi

    local poke
    if ! poke="$(pokeapi_get "pokemon/${variety}")"; then
        return 1
    fi
    local dex_id
    dex_id="$(jq -r '.id' <<<"${poke}")"
    local sprite_url
    sprite_url="$(jq -r '.sprites.front_default // ""' <<<"${poke}")"
    local sprite_url_shiny
    sprite_url_shiny="$(jq -r '.sprites.front_shiny // ""' <<<"${poke}")"

    local level
    level="$(encounter_roll_level "${lo}" "${hi}")"

    local ivs
    ivs="$(encounter_roll_ivs)"
    local evs
    evs="$(encounter_ev_split "$((RANDOM % 511))")"

    local -a natures
    mapfile -t natures < <(encounter_natures_list)
    local -i nat_count="${#natures[@]}"
    local nature="${natures[$((RANDOM % nat_count))]}"
    local mods
    if ! mods="$(encounter_nature_mods "${nature}")"; then
        return 1
    fi

    local ability_obj
    if ! ability_obj="$(encounter_roll_ability "${variety}")"; then
        return 1
    fi
    local ability
    ability="$(jq -r '.name' <<<"${ability_obj}")"
    local is_hidden
    is_hidden="$(jq -r 'if .is_hidden then 1 else 0 end' <<<"${ability_obj}")"

    local moves_json
    if ! moves_json="$(encounter_roll_moves "${variety}" "${level}")"; then
        return 1
    fi

    local gender
    if ! gender="$(encounter_roll_gender "${sp}")"; then
        return 1
    fi
    local shiny
    shiny="$(encounter_roll_shiny)"
    local held_berry
    if ! held_berry="$(encounter_roll_held_berry "${biome}")"; then
        return 1
    fi

    local base_stats
    base_stats="$(jq -c '.stats' <<<"${poke}")"
    local stats
    if ! stats="$(encounter_compute_all_stats "${base_stats}" "${ivs}" "${evs}" "${level}" "${mods}")"; then
        return 1
    fi

    local final_sprite="${sprite_url}"
    if [[ "${shiny}" == "1" && -n "${sprite_url_shiny}" ]]; then
        final_sprite="${sprite_url_shiny}"
    fi

    local friendship
    if ! friendship="$(encounter_roll_friendship "${sp}")"; then
        return 1
    fi

    local berry_arg
    if [[ "${held_berry}" == "null" ]]; then
        berry_arg="null"
    else
        berry_arg="\"${held_berry}\""
    fi

    local ivs_json
    ivs_json="$(_json_int_array "${ivs}")"
    local evs_json
    evs_json="$(_json_int_array "${evs}")"
    local stats_json
    stats_json="$(_json_int_array "${stats}")"

    jq -n \
        --arg sp "${sp}" --argjson dex "${dex_id}" --argjson lvl "${level}" \
        --arg nature "${nature}" --arg ability "${ability}" --argjson hidden "${is_hidden}" \
        --arg gender "${gender}" --argjson shiny "${shiny}" --argjson held "${berry_arg}" \
        --argjson friendship "${friendship}" \
        --argjson ivs "${ivs_json}" --argjson evs "${evs_json}" --argjson stats "${stats_json}" \
        --argjson moves "${moves_json}" --arg sprite "${final_sprite}" '{
            species: $sp, dex_id: $dex, level: $lvl,
            nature: $nature, ability: $ability, is_hidden_ability: $hidden,
            gender: $gender, shiny: $shiny, held_berry: $held,
            friendship: $friendship,
            ivs: $ivs, evs: $evs, stats: $stats,
            moves: $moves, sprite_url: $sprite
        }'
}

# encounter_roll_friendship <species>
# Print the species' base_happiness from PokeAPI; 70 if missing.
function encounter_roll_friendship {
    local species="$1"
    local spec
    if ! spec="$(pokeapi_get "pokemon-species/${species}")"; then
        return 1
    fi
    local val
    val="$(jq -r '.base_happiness // 70' <<<"${spec}")"
    if [[ "${val}" == "null" || -z "${val}" ]]; then
        val=70
    fi
    printf '%s' "${val}"
}

# _encounter_item_pool <biome_id>
# Print the biome's full item drop pool (one slug per line): the union of its
# Showdown-legal held items and its evolution-trigger items, both biome-keyed
# directly. No PokeAPI-type indirection — each item lives in exactly one biome.
function _encounter_item_pool {
    local biome_id="$1"
    local -a items
    read -ra items <<<"${ENCOUNTER_ITEMS_BY_BIOME[${biome_id}]:-} ${ENCOUNTER_EVOLUTION_ITEMS_BY_BIOME[${biome_id}]:-}"
    local item
    for item in "${items[@]}"; do
        if [[ -z "${item}" ]]; then
            continue
        fi
        printf '%s\n' "${item}"
    done
}

# encounter_roll_item <biome_id>
# Print {"item": "<name>", "sprite_url": "<url|empty>"}. Returns 1 on an empty
# pool or fetch failure.
function encounter_roll_item {
    local biome_id="$1"
    local -a pool=()
    mapfile -t pool < <(_encounter_item_pool "${biome_id}")
    local -i n="${#pool[@]}"
    if ((n == 0)); then
        printf 'encounter_roll_item: empty pool for biome %s\n' "${biome_id}" >&2
        return 1
    fi
    local name="${pool[$((RANDOM % n))]}"
    local item_json
    if ! item_json="$(pokeapi_get "item/${name}")"; then
        return 1
    fi
    local sprite
    sprite="$(jq -r '.sprites.default // ""' <<<"${item_json}")"
    jq -n --arg item "${name}" --arg sprite "${sprite}" '{item: $item, sprite_url: $sprite}'
}
