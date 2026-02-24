#!/usr/bin/env bash
# =============================================================================
# show_hkv_status.sh
# =============================================================================
# Version:      0.9.9.6
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

# ────────────────────────────────────────────────────────────────
# Configuration
# ────────────────────────────────────────────────────────────────
SCRIPT_FILE=$(readlink -f "$(which "$0")")
SCRIPT_NAME=$(basename "$SCRIPT_FILE")
WMBUS_RAW_DATA_FILE="hkvs_current.jsonl"
HKV_ID_LIST_FILE="HKV_ID_list.lst"
SCREEN_SESSION_NAME_COLLECTOR="hkv-collector"

ID_WIDTH=8
UNIT_WIDTH=4
NAME_WIDTH=38
FAKTOR_WIDTH=6
CLASS_WIDTH=5
NUM_WIDTH=8
DATE_WIDTH=19
PREV_WIDTH=8
CURR_WIDTH=7
LOOP_INTERVAL=15

# ────────────────────────────────────────────────────────────────
# Help
# ────────────────────────────────────────────────────────────────
show_help() {
    cat << 'EOF'
Usage: ./show_hkv_status.sh [OPTIONS]

OPTIONS:
  -col, --collect    Start collector
                     - Only -col → starts and attaches screen (live output)
                     - -col + other options → starts (if needed) and shows loop view
  -kill-col, --kill-collector   Stop collector (screen + process)
  -s <mode>          Sort mode: id|unit|name|factor|class|previous|current|date
  -l [seconds]       Loop mode (default: 15 s) → auto-starts collector
  -e, --export       Export current view to file (one-time)
  -c, --clear        Delete raw data file (with confirmation)
  -h, --help         Show this help

Examples:
  ./show_hkv_status.sh -l 10 -s date          → Loop view + auto collector start
  ./show_hkv_status.sh -col                   → Start collector + open screen window
  ./show_hkv_status.sh -col -l 5              → Collector + loop view
  ./show_hkv_status.sh -kill-col              → Stop collector
EOF
    exit 0
}

# ────────────────────────────────────────────────────────────────
# Parse arguments
# ────────────────────────────────────────────────────────────────
COLLECT=false
ONLY_COLLECT=false
KILL_COLLECT=false
EXPORT=false
LOOP=false
CLEAR_DATA=false
SORT_MODE="id"
LOOP_SEC=$LOOP_INTERVAL
START_COLLECTOR=false


# If only -col is given → open screen session immediately
if [[ $# -eq 1 ]]; then
    ONLY_COLLECT=true
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -col|--collect)
            COLLECT=true
            shift
            ;;
        -kill-col|--kill-collector)
            KILL_COLLECT=true
            shift
            ;;
        -h|--help) show_help ;;
        -e|--export) EXPORT=true; shift ;;
        -l|--loop)
            LOOP=true
            COLLECT=true
            shift
            [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] && { LOOP_SEC="$1"; shift; }
            ;;
        -c|--clear)
            CLEAR_DATA=true
            shift
            ;;
        -s)
            shift
            [[ $# -eq 0 ]] && { echo "Error: -s requires value"; exit 1; }
            SORT_MODE="$1"
            shift
            ;;
        *)
            echo "Unknown parameter: $1"
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

SORT_MODE=$(echo "$SORT_MODE" | tr '[:upper:]' '[:lower:]')

# ────────────────────────────────────────────────────────────────
# Delete raw data file (with confirmation)
# ────────────────────────────────────────────────────────────────
if $CLEAR_DATA; then
    if [ -f "$WMBUS_RAW_DATA_FILE" ]; then
        echo "Delete $WMBUS_RAW_DATA_FILE ? (y/N)"
        read -r confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            rm -f "$WMBUS_RAW_DATA_FILE"
            echo "→ Deleted."
        else
            echo "→ Aborted."
        fi
    else
        echo "No file present."
    fi
fi

# ────────────────────────────────────────────────────────────────
# Stop collector (if -kill-col)
# ────────────────────────────────────────────────────────────────
if $KILL_COLLECT; then
    if screen -list | grep -q "$SCREEN_SESSION_NAME_COLLECTOR"; then
        echo "Stopping collector session: $SCREEN_SESSION_NAME_COLLECTOR"
        screen -S "$SCREEN_SESSION_NAME_COLLECTOR" -X quit
        sleep 1
        if screen -list | grep -q "$SCREEN_SESSION_NAME_COLLECTOR"; then
            echo "Error stopping session – manual kill required:"
            echo "  screen -S $SCREEN_SESSION_NAME_COLLECTOR -X quit"
        else
            echo "→ Collector stopped"
        fi
    else
        echo "No collector running (session not found)"
    fi
    exit 0
fi

# ────────────────────────────────────────────────────────────────
# Collector status check
# ────────────────────────────────────────────────────────────────
collector_status() {
    if screen -list | grep -q "$SCREEN_SESSION_NAME_COLLECTOR"; then
        echo "Collector running (screen: $SCREEN_SESSION_NAME_COLLECTOR)"
        return 0
    else
        echo "Collector not running"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────
# Start collector (on -col or -l)
# ────────────────────────────────────────────────────────────────
if $COLLECT || $LOOP; then
    if ! collector_status; then
        echo "Starting collector in screen session: $SCREEN_SESSION_NAME_COLLECTOR"
        IDS_PATTERN=$(awk 'NF && $0 !~ /^#/ {printf "%s%s", (n++?"|":""), sprintf("%08d",$1)}' "$HKV_ID_LIST_FILE")

        if [ -z "$IDS_PATTERN" ]; then
            echo "ERROR: No valid IDs found in $HKV_ID_LIST_FILE"
            exit 1
        fi
        
        START_COLLECTOR=true
        screen -dmS "$SCREEN_SESSION_NAME_COLLECTOR" bash -c "
            echo 'wmbusmeters collector running...'
            echo 'Stop: Ctrl+C | Detach: Ctrl+A D'
            echo ''
            echo 'HKV IDs: $IDS_PATTERN'
            echo ''
            wmbusmeters --format=json /dev/ttyUSB0:cul:t1 MyHCA bfw240radio ANYID NOKEY \
            | while IFS= read -r line; do
                [[ \"\$line\" =~ ^[[:space:]]*\\{ ]] || continue
                if [[ \"\$line\" =~ \\\"id\\\":\\\"($IDS_PATTERN)\\\" ]]; then
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
        sleep 3
        collector_status
    fi

    # Only -col → attach screen immediately
    if $ONLY_COLLECT; then
        echo "Opening collector session (live output)..."
        exec screen -r "$SCREEN_SESSION_NAME_COLLECTOR"
    fi
fi

# ────────────────────────────────────────────────────────────────
# Rest of the script (display)
# ────────────────────────────────────────────────────────────────

# Sort key mapping
case "$SORT_MODE" in
    id) sort_key=1 ; sort_num=false ; sort_rev=false ;;
    unit) sort_key=2 ; sort_num=false ; sort_rev=false ;;
    name) sort_key=3 ; sort_num=false ; sort_rev=false ;;
    factor) sort_key=4 ; sort_num=true ; sort_rev=true ;;
    class) sort_key=5 ; sort_num=false ; sort_rev=false ;;
    previous) sort_key=6 ; sort_num=true ; sort_rev=true ;;
    curr|current) sort_key=7 ; sort_num=true ; sort_rev=true ;;
    date) sort_key=9 ; sort_num=true ; sort_rev=true ;;
    *)
        echo "Invalid sort mode: $SORT_MODE"
        exit 1
        ;;
esac

# Function: Load data + create temp file
create_tempfile() {
    tmpfile=$(mktemp)
    total_known=0
    with_values=0

    declare -A hkv_data
    if [ -s "$WMBUS_RAW_DATA_FILE" ]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            ts="${line:0:19}"
            json="${line:20}"

            [[ ! "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] && continue

            raw_id=$(echo "$json" | grep -oP '(?<="id":")[^"]+' || continue)
            id=$(echo "$raw_id" | sed 's/^0*//')

            current=$(echo "$json" | grep -oP '(?<="current_hca":)\d+' || echo "0")
            prev=$(echo "$json"   | grep -oP '(?<="prev_hca":)\d+'   || echo "0")

            hkv_data["$id"]="$prev"$'\t'"$current"$'\t'"$ts"
        done < "$WMBUS_RAW_DATA_FILE"
    fi

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# || "$line" =~ ^ID[[:space:]] ]] && continue

        read -r raw_id unit name factor class comment <<< "$line"

        id=$(echo "$raw_id" | tr -d '[:space:]' | sed 's/^0*//')
        [[ ! "$id" =~ ^[0-9]{6,8}$ ]] && continue

        ((total_known++))

        unit=$(echo "$unit" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        factor=$(echo "$factor" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        class=$(echo "$class" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [ -z "$name" ] && name="unknown"
        [ -z "$factor" ] && factor="---"
        [ -z "$class" ] && class="---"

        if [[ -v hkv_data[$id] ]]; then
            IFS=$'\t' read -r prev current ts <<< "${hkv_data[$id]}"
            ((with_values++))
        else
            prev="---"
            current="---"
            ts="---"
        fi

        if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
            ts_sort=$(printf '%s%s%s%s%s%s' \
                "${ts:0:4}" "${ts:5:2}" "${ts:8:2}" "${ts:11:2}" "${ts:14:2}" "${ts:17:2}")
        else
            ts_sort="00000000000000"
        fi

        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$id" "$unit" "$name" "$factor" "$class" "$prev" "$current" "$ts" "$ts_sort"

    done < "$HKV_ID_LIST_FILE" > "$tmpfile"
}

# ────────────────────────────────────────────────────────────────
# Output function with collector status
# ────────────────────────────────────────────────────────────────
output() {
    clear 2>/dev/null || true

    # Collector status
    if screen -list | grep -q "$SCREEN_SESSION_NAME_COLLECTOR"; then
        printf "Collector status: running (Live log: screen -r $SCREEN_SESSION_NAME_COLLECTOR)"
        if $LOOP; then
            printf " | Refresh every ${LOOP_SEC} seconds\n"
        else
            echo ""
        fi
    else
        echo "Collector status: NOT running => Start: ./$SCRIPT_NAME -col"
    fi

    echo ""
    printf "%${ID_WIDTH}s | %${UNIT_WIDTH}s | %-${NAME_WIDTH}s | %${FAKTOR_WIDTH}s | %-${CLASS_WIDTH}s | %${PREV_WIDTH}s | %${CURR_WIDTH}s | %-${DATE_WIDTH}s\n" \
        "ID" "Unit" "Name" "Factor" "Class" "previous" "current" "last update"

    printf "%s\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

    local sort_opts=""
    $sort_num && sort_opts+="-n "
    $sort_rev && sort_opts+="-r "

    sort -t $'\t' -k${sort_key},${sort_key} ${sort_opts} "$tmpfile" \
    | while IFS=$'\t' read -r id unit name factor class prev current ts ts_sort; do
        printf "%${ID_WIDTH}s | %${UNIT_WIDTH}s | %-${NAME_WIDTH}s | %${FAKTOR_WIDTH}s | %-${CLASS_WIDTH}s | %${PREV_WIDTH}s | %${CURR_WIDTH}s | %-${DATE_WIDTH}s\n" \
            "$id" "$unit" "${name:0:$NAME_WIDTH}" "$factor" "$class" "$prev" "$current" "$ts"
    done

    printf "%s\n" "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

    echo "Total known HKVs: $total_known"
    echo "HKVs with current values: $with_values / $total_known"

    rm -f "$tmpfile"
}

# ────────────────────────────────────────────────────────────────
# Main logic
# ────────────────────────────────────────────────────────────────
export SCREEN_SESSION_NAME_COLLECTOR
export START_COLLECTOR

if $LOOP; then
    trap "
        if [ \"\$START_COLLECTOR\" = \"true\" ]; then
            echo \"Stopping collector (autostarted by scriopt)...\"
            echo \"Session name: \$SCREEN_SESSION_NAME_COLLECTOR\"
            killall screen
            screen -S \"\$SCREEN_SESSION_NAME_COLLECTOR\" -X quit 2>/dev/null || true
            # Kill any hanging wmbusmeters processes from this session
            pkill -f \"wmbusmeters.*\$SCREEN_SESSION_NAME_COLLECTOR\" 2>/dev/null || true
        else
            echo \"Resume collector (separated started)...\"
        fi
        rm -f \"\$tmpfile\" 2>/dev/null
        exit 0
    " INT TERM EXIT

    while true; do
        create_tempfile
        output

        # Countdown loop for refresh interval
        COUNTDOWN=$LOOP_SEC

	while [ $COUNTDOWN -ge 0 ]; do
	    # \r = zurück an Zeilenanfang
	    # \e[K = Zeile bis Ende löschen (verhindert Müll bei Überschreiben)
	    echo -ne "\rAuto refresh ${COUNTDOWN}s (Enter = refresh now, any other key = exit): "

	    # Taste prüfen, ohne sichtbaren Umbruch
	    if read -n 1 -t 1 -s key; then
		# -s = silent (keine Ausgabe der Taste)
		if [[ "$key" == $'\n' || -z "$key" ]]; then
		    echo -ne "\nRefreshing now...\e[K"
		    break
		else
		    echo -e "\nExiting loop..."
		    break 2
		fi
	    fi

	    ((COUNTDOWN--))
	done

        # Auto refresh when countdown reaches 0
        if [ $COUNTDOWN -lt 0 ]; then
            echo -ne "\rAuto refresh ... \e[K"
        fi
    done
else
    create_tempfile
    output
fi

# Export outside loop
if $EXPORT && ! $LOOP; then
    REPORT_FILE="hkv_status_$(date +%Y-%m-%d_%H%M).txt"
    create_tempfile
    output > "$REPORT_FILE"
    echo "Output saved to: $REPORT_FILE"
fi

exit 0

