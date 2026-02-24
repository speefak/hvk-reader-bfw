#!/usr/bin/env bash
# =============================================================================
# hkv-reader-bfw
# =============================================================================
# Version:      0.8
# Purpose:      Display and manage HKV data from wmbusmeters
#               - Live table view (sorted, loop mode)
#               - Background data collection via wmbusmeters (screen session)
#               - Auto-start collector when using -l / --loop
#               - Manual collector stop with -kill-col
#               - Collector status shown in table
#
# Examples:
#   ./show_hkv_status.sh -l 10 -s date          → Loop view (auto collector start)
#   ./show_hkv_status.sh -col                   → Start collector + open screen window
#   ./show_hkv_status.sh -col -l 5 -s unit      → Collector + loop view
#   ./show_hkv_status.sh -kill-col              → Stop collector
#   ./hkv-reader-bfw -f /path/to/custom_ids.lst -l 10 → Use custom ID file + loop
#
# Dependencies:
#   - wmbusmeters
#   - screen
#   - awk, grep, date, mktemp (standard tools)
#
# Output file:  hkvs_current.jsonl
# ID list:      HKV_ID_list.lst
# =============================================================================

set -u

# ─────────────────────────────────────────────────────────────────────────────
# Configuration & Constants
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_FILE=$(readlink -f "${BASH_SOURCE[0]}")
SCRIPT_NAME=$(basename "$SCRIPT_FILE")

: "${DATA_DIR:="/var/tmp"}"
WMBUS_RAW_DATA_FILE="${DATA_DIR}/hkvs_current.jsonl"
DEFAULT_ID_LIST="HKV_ID_list.lst"
SCREEN_SESSION_NAME="hkv-collector"

# Column widths
ID_WIDTH=8
UNIT_WIDTH=4
NAME_WIDTH=30
FAKTOR_WIDTH=6
CLASS_WIDTH=5
PREV_WIDTH=8
CURR_WIDTH=7
DATE_WIDTH=19

DEFAULT_LOOP_INTERVAL=15

# ─────────────────────────────────────────────────────────────────────────────
# Global Flags & Variables
# ─────────────────────────────────────────────────────────────────────────────
HKV_ID_LIST_FILE="$DEFAULT_ID_LIST"
SORT_MODE="id"
LOOP_SEC=$DEFAULT_LOOP_INTERVAL

COLLECT=false
ONLY_COLLECT=false
KILL_COLLECT=false
EXPORT=false
LOOP=false
CLEAR_DATA=false
START_COLLECTOR=false

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

show_help() {
    cat << 'EOF'
Usage: '"$SCRIPT_NAME"' [OPTIONS]

Options:
  -col, --collect          Start collector (background or attach)
  -kill-col, --kill-collector  Stop collector
  -f, --id-file <path>     Use custom ID list file
  -s <mode>                Sort by: id|unit|name|factor|class|previous|current|date
  -l [seconds]             Loop mode (default 15s), auto-starts collector
  -e, --export             Export current view to file (one-time)
  -c, --clear              Delete raw data file (with confirmation)
  -h, --help               Show this help

Examples:
  '"$SCRIPT_NAME"' -l 10 -s date
  '"$SCRIPT_NAME"' -col
  '"$SCRIPT_NAME"' -col -l 5
  '"$SCRIPT_NAME"' -kill-col
EOF
    exit 0
}
# ─────────────────────────────────────────────────────────────────────────────
collector_is_running() {
    screen -list | grep -q "$SCREEN_SESSION_NAME"
}
# ─────────────────────────────────────────────────────────────────────────────
collector_status() {
    if collector_is_running; then
        echo "Collector running (screen: $SCREEN_SESSION_NAME)"
        return 0
    else
        echo "Collector not running"
        return 1
    fi
}
# ─────────────────────────────────────────────────────────────────────────────
start_collector() {
    local ids_pattern
    ids_pattern=$(awk 'NF && $0 !~ /^#/ {printf "%s%s", (n++?"|":""), sprintf("%08d",$1)}' "$HKV_ID_LIST_FILE")

    if [[ -z "$ids_pattern" ]]; then
        echo "ERROR: No valid IDs found in $HKV_ID_LIST_FILE" >&2
        exit 1
    fi

    echo "Starting collector in screen session: $SCREEN_SESSION_NAME"
    
    screen -dmS "$SCREEN_SESSION_NAME" bash -c "
        echo 'wmbusmeters collector running...'
        echo 'Stop: Ctrl+C | Detach: Ctrl+A D'
        echo ''
        echo 'HKV IDs: $ids_pattern'
        echo ''
        wmbusmeters --format=json /dev/ttyUSB0:cul:t1 MyHCA bfw240radio ANYID NOKEY \\
        | while IFS= read -r line; do
            [[ \"\$line\" =~ ^[[:space:]]*\\{ ]] || continue
            if [[ \"\$line\" =~ \\\"id\\\":\\\"($ids_pattern)\\\" ]]; then
                id=\"\${BASH_REMATCH[1]}\"
                ts=\"\$(date '+%Y-%m-%d %H:%M:%S')\"
                full_line=\"\$ts \$line\"
                if [ -s '$WMBUS_RAW_DATA_FILE' ]; then
                    grep -v \\\"id\\\":\\\"\"\$id\"\\\" '$WMBUS_RAW_DATA_FILE' > '$WMBUS_RAW_DATA_FILE'.tmp || true
                    mv '$WMBUS_RAW_DATA_FILE'.tmp '$WMBUS_RAW_DATA_FILE'
                fi
                echo \"\$full_line\" >> '$WMBUS_RAW_DATA_FILE'
                echo \"\$full_line\"
                echo \"\"
            fi
        done
    "

    sleep 2
    collector_status
}
# ─────────────────────────────────────────────────────────────────────────────
stop_collector() {
    if collector_is_running; then
        echo "Stopping collector session: $SCREEN_SESSION_NAME"
        screen -S "$SCREEN_SESSION_NAME" -X quit
        sleep 1
        if collector_is_running; then
            echo "Error stopping session – try manually:"
            echo "  screen -S $SCREEN_SESSION_NAME -X quit"
        else
            echo "→ Collector stopped"
        fi
    else
        echo "No collector running (session not found)"
    fi
}
# ─────────────────────────────────────────────────────────────────────────────
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -col|--collect)           COLLECT=true ;;
            -kill-col|--kill-collector) KILL_COLLECT=true ;;
            -f|--id-file)
                shift
                [[ $# -eq 0 ]] && { echo "Error: -f requires path" >&2; exit 1; }
                HKV_ID_LIST_FILE="$1"
                ;;
            -h|--help)                show_help ;;
            -e|--export)              EXPORT=true ;;
            -l|--loop)
                LOOP=true
                COLLECT=true
                if [[ ${2:-} =~ ^[0-9]+$ ]]; then
                    LOOP_SEC="$2"
                    shift
                fi
                ;;
            -c|--clear)               CLEAR_DATA=true ;;
            -s)
                shift
                [[ $# -eq 0 ]] && { echo "Error: -s requires value" >&2; exit 1; }
                SORT_MODE="$1"
                ;;
            *)  echo "Unknown parameter: $1" >&2
                echo "Use -h for help" >&2
                exit 1 ;;
        esac
        shift
    done

    SORT_MODE=$(echo "$SORT_MODE" | tr '[:upper:]' '[:lower:]')

    # Special case: only -col → attach immediately
    [[ $# -eq 0 && $COLLECT = true && $LOOP = false && $EXPORT = false && $CLEAR_DATA = false ]] && ONLY_COLLECT=true
}
# ─────────────────────────────────────────────────────────────────────────────
get_sort_settings() {
    case "$SORT_MODE" in
        id)         echo "1 false false" ;;
        unit)       echo "2 false false" ;;
        name)       echo "3 false false" ;;
        factor)     echo "4 true  true"  ;;
        class)      echo "5 false false" ;;
        previous)   echo "6 true  true"  ;;
        curr|current) echo "7 true  true"  ;;
        date)       echo "9 true  true"  ;;
        *)          echo "Invalid sort mode: $SORT_MODE" >&2; exit 1 ;;
    esac
}
# ─────────────────────────────────────────────────────────────────────────────
create_data_table() {
    local tmpfile total_known=0 with_values=0
    tmpfile=$(mktemp) || exit 1

    declare -A hkv_data

    if [[ -s "$WMBUS_RAW_DATA_FILE" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            ts="${line:0:19}"
            json="${line:20}"
            [[ ! "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] && continue

            raw_id=$(echo "$json" | grep -oP '(?<="id":")[^"]+' || continue)
            id=$(echo "$raw_id" | sed 's/^0*//')
            current=$(echo "$json" | grep -oP '(?<="current_hca":)\d+' || echo "0")
            prev=$(echo "$json" | grep -oP '(?<="prev_hca":)\d+' || echo "0")

            hkv_data["$id"]="$prev"$'\t'"$current"$'\t'"$ts"
        done < "$WMBUS_RAW_DATA_FILE"
    fi

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# || "$line" =~ ^ID[[:space:]] ]] && continue

        read -r raw_id unit name factor class _ <<< "$line"
        id=$(echo "$raw_id" | tr -d '[:space:]' | sed 's/^0*//')
        [[ ! "$id" =~ ^[0-9]{6,8}$ ]] && continue

        ((total_known++))

        unit=${unit##*[[:space:]]}   unit=${unit%%[[:space:]]*}
        name=${name##*[[:space:]]}   name=${name%%[[:space:]]*}
        factor=${factor##*[[:space:]]} factor=${factor%%[[:space:]]*}
        class=${class##*[[:space:]]}   class=${class%%[[:space:]]*}

        : "${name:=unknown}" "${factor:="---"}" "${class:="---"}"

        if [[ -v hkv_data[$id] ]]; then
            IFS=$'\t' read -r prev current ts <<< "${hkv_data[$id]}"
            ((with_values++))
        else
            prev="---" current="---" ts="---"
        fi

        ts_sort="00000000000000"
        if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
            ts_sort="${ts:0:4}${ts:5:2}${ts:8:2}${ts:11:2}${ts:14:2}${ts:17:2}"
        fi

        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$id" "$unit" "$name" "$factor" "$class" "$prev" "$current" "$ts" "$ts_sort"
    done < "$HKV_ID_LIST_FILE" > "$tmpfile"

    echo "$tmpfile" "$total_known" "$with_values"
}
# ─────────────────────────────────────────────────────────────────────────────
print_table() {
    local tmpfile=$1 total_known=$2 with_values=$3

    clear 2>/dev/null || true

    if collector_is_running; then
        printf "Collector status: running (live log: screen -r %s)" "$SCREEN_SESSION_NAME"
        $LOOP && printf " | Refresh every %d seconds" "$LOOP_SEC"
        echo ""
    else
        echo "Collector status: NOT running => Start: ./$SCRIPT_NAME -col"
    fi
    echo ""

    printf "%${ID_WIDTH}s | %${UNIT_WIDTH}s | %-${NAME_WIDTH}s | %${FAKTOR_WIDTH}s | %-${CLASS_WIDTH}s | %${PREV_WIDTH}s | %${CURR_WIDTH}s | %-${DATE_WIDTH}s\n" \
        "ID" "Unit" "Name" "Factor" "Class" "previous" "current" "last update"

    printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

    read sort_key sort_num sort_rev <<< "$(get_sort_settings)"

    local sort_opts=""
    $sort_num && sort_opts+="-n "
    $sort_rev && sort_opts+="-r "

    sort -t $'\t' -k"${sort_key},${sort_key}" ${sort_opts} "$tmpfile" \
    | while IFS=$'\t' read -r id unit name factor class prev current ts _; do
        printf "%${ID_WIDTH}s | %${UNIT_WIDTH}s | %-${NAME_WIDTH}s | %${FAKTOR_WIDTH}s | %-${CLASS_WIDTH}s | %${PREV_WIDTH}s | %${CURR_WIDTH}s | %-${DATE_WIDTH}s\n" \
            "$id" "$unit" "${name:0:$NAME_WIDTH}" "$factor" "$class" "$prev" "$current" "$ts"
    done

    printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    echo "Total known HKVs: $total_known"
    echo "HKVs with current values: $with_values / $total_known"

    rm -f "$tmpfile"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

parse_arguments "$@"

if $CLEAR_DATA; then
    if [[ -f "$WMBUS_RAW_DATA_FILE" ]]; then
        echo "Delete $WMBUS_RAW_DATA_FILE ? (y/N)"
        read -r confirm
        [[ "$confirm" =~ ^[yY]$ ]] && rm -f "$WMBUS_RAW_DATA_FILE" && echo "→ Deleted." || echo "→ Aborted."
    else
        echo "No file present."
    fi
fi

if $KILL_COLLECT; then
    stop_collector
    exit 0
fi

if $COLLECT || $LOOP; then
    if ! collector_is_running; then
        start_collector
        START_COLLECTOR=true
    fi

    if $ONLY_COLLECT; then
        echo "Opening collector session (live output)..."
        exec screen -r "$SCREEN_SESSION_NAME"
    fi
fi

# ── Display logic ────────────────────────────────────────────────────────────

if $LOOP; then
    trap '
        if [[ "$START_COLLECTOR" = true ]]; then
            echo "Stopping collector (autostarted by script)..."
            screen -S "$SCREEN_SESSION_NAME" -X quit 2>/dev/null
            pkill -f "wmbusmeters.*$SCREEN_SESSION_NAME" 2>/dev/null
        fi
        exit 0
    ' INT TERM EXIT

    while true; do
        read tmpfile total_known with_values < <(create_data_table)
        print_table "$tmpfile" "$total_known" "$with_values"

        COUNTDOWN=$LOOP_SEC
        while (( COUNTDOWN >= 0 )); do
            echo -ne "\rAuto refresh ${COUNTDOWN}s (Enter = now, other key = exit): "
            if read -n 1 -t 1 -s key; then
                if [[ -z "$key" || "$key" == $'\n' ]]; then
                    echo -e "\nRefreshing now...\e[K"
                    break
                else
                    echo -e "\nExiting loop..."
                    exit 0
                fi
            fi
            ((COUNTDOWN--))
        done
    done
else
    read tmpfile total_known with_values < <(create_data_table)
    print_table "$tmpfile" "$total_known" "$with_values"

    if $EXPORT; then
        REPORT_FILE="hkv_status_$(date +%Y-%m-%d_%H%M).txt"
        print_table <(create_data_table) > "$REPORT_FILE"   # second call → new data
        echo "Output saved to: $REPORT_FILE"
    fi
fi

exit 0
