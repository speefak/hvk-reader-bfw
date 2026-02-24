#!/usr/bin/env bash
# hkv-reade-bfw
# Version: 0.2

set -u

# ────────────────────────────────────────────────────────────────
# Konfiguration
# ────────────────────────────────────────────────────────────────
SCRIPT_FILE=$(readlink -f $(which $0))
SCRIPT_NAME=$(basename $SCRIPT_FILE)
DATA_FILE="hkvs_current.jsonl"
NAMES_FILE="HKV_ID_list.lst"
COLLECTOR_SESSION="hkv-collector"

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
# Hilfe
# ────────────────────────────────────────────────────────────────
show_help() {
    cat << 'EOF'
Verwendung: ./show_hkv_status.sh [OPTIONEN]

OPTIONEN:
  -col, --collect    Collector starten
                     - Nur -col → startet und öffnet screen sofort (Live-Ausgabe)
                     - -col + weitere Optionen → startet (falls nötig) und zeigt Loop-Anzeige
  -s <modus>         Sortiermodus: id|unit|name|factor|class|previous|current|date
  -l [sek]           Endlosschleife (Standard: 15 s)
  -e, --export       Einmalige Ausgabe in Datei speichern
  -c, --clear        Rohdaten-Datei löschen (mit Abfrage)
  -h, --help         diese Hilfe
EOF
    exit 0
}

# ────────────────────────────────────────────────────────────────
# Argumente parsen
# ────────────────────────────────────────────────────────────────
COLLECT=false
EXPORT=false
LOOP=false
CLEAR_DATA=false
SORT_MODE="id"
LOOP_SEC=$LOOP_INTERVAL
ONLY_COLLECT=false
KILL_COLLECT=false

# Wenn nur -col angegeben wurde → Collector starten und screen öffnen
if [[ $# -eq 1 ]];then
   ONLY_COLLECT=true
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -col|--collect)
            COLLECT=true
            shift
            ;;
         -colq)
            KILL_COLLECT=true
            shift
            ;;
        -h|--help) show_help ;;
        -e|--export) EXPORT=true; shift ;;
        -l|--loop)
            LOOP=true
            shift
            [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]] && { LOOP_SEC="$1"; shift; }
            ;;
        -c|--clear)
            CLEAR_DATA=true
            shift
            ;;
        -s)
            shift
            [[ $# -eq 0 ]] && { echo "Fehler: -s benötigt Wert"; exit 1; }
            SORT_MODE="$1"
            shift
            ;;
        *)
            echo "Unbekannter Parameter: $1"
            echo "Verwende -h für Hilfe"
            exit 1
            ;;
    esac
done

SORT_MODE=$(echo "$SORT_MODE" | tr '[:upper:]' '[:lower:]')

# ────────────────────────────────────────────────────────────────
# Collector beenden (wenn -kill-col angegeben)
# ────────────────────────────────────────────────────────────────
collector_quit () {
    if screen -list | grep -q "$COLLECTOR_SESSION"; then
        echo "Beende Collector-Session: $COLLECTOR_SESSION"
        screen -S "$COLLECTOR_SESSION" -X quit
        sleep 1
        if screen -list | grep -q "$COLLECTOR_SESSION"; then
            echo "Fehler beim Beenden – manuell killen:"
            echo "  screen -S $COLLECTOR_SESSION -X quit"
        else
            echo "→ Collector beendet"
        fi
    else
        echo "Kein Collector läuft (Session nicht gefunden)"
    fi
    exit 0
}
# ────────────────────────────────────────────────────────────────
# Collector-Status prüfen
# ────────────────────────────────────────────────────────────────
collector_status() {
    if screen -list | grep -q "$COLLECTOR_SESSION"; then
        echo "Collector läuft (screen: $COLLECTOR_SESSION)"
        return 0
    else
        echo "Collector läuft NICHT"
        return 1
    fi
}
# ────────────────────────────────────────────────────────────────
# Collector beenden und script exit wenn -colq option
# ────────────────────────────────────────────────────────────────
if $KILL_COLLECT; then
    collector_quit
fi

# ────────────────────────────────────────────────────────────────
# Collector starten (nur bei -col)
# ────────────────────────────────────────────────────────────────
if $COLLECT || $LOOP ; then
    if ! collector_status; then
        echo "Starte Collector in screen-Session: $COLLECTOR_SESSION"

        # WICHTIG: Pattern VORHER expandieren!
        IDS_PATTERN=$(awk 'NF && $0 !~ /^#/ {printf "%s%s", (n++?"|":""), sprintf("%08d",$1)}' "$NAMES_FILE")

        if [ -z "$IDS_PATTERN" ]; then
            echo "FEHLER: Keine gültigen IDs in $NAMES_FILE gefunden"
            exit 1
        fi

        screen -dmS "$COLLECTOR_SESSION" bash -c "
            echo 'wmbusmeters Collector läuft...'
            echo 'Beenden: Ctrl+C   |   Detach: Ctrl+A D'
            echo ''
            echo 'HKV IDs: $IDS_PATTERN'
            echo ''

            wmbusmeters --format=json /dev/ttyUSB0:cul:t1 MyHCA bfw240radio ANYID NOKEY \
            | while IFS= read -r line; do
  #                  echo \"\$line\"
                [[ \"\$line\" =~ ^[[:space:]]*\\{ ]] || continue
                if [[ \"\$line\" =~ \\\"id\\\":\\\"($IDS_PATTERN)\\\" ]]; then
                    id=\"\${BASH_REMATCH[1]}\"
                    ts=\"\$(date '+%Y-%m-%d %H:%M:%S')\"
                    full_line=\"\$ts \$line\"

                    if [ -s '$DATA_FILE' ]; then
                        grep -v \\\"id\\\":\\\"\"\$id\"\\\" '$DATA_FILE' > '$DATA_FILE'.tmp || true
                        mv '$DATA_FILE'.tmp '$DATA_FILE'
                    fi

                    echo \"\$full_line\" >> '$DATA_FILE'
                    echo \"\$full_line\"
                    echo \"\"
                fi
            done
        "

        sleep 3
        collector_status
    fi

    # Wenn nur -col → screen öffnen
    if $ONLY_COLLECT; then
        echo "Öffne Collector-Session (Live-Ausgabe)..."
        exec screen -r "$COLLECTOR_SESSION"
    fi
fi
# ────────────────────────────────────────────────────────────────
# Rest des Skripts (Anzeige)
# ────────────────────────────────────────────────────────────────

# Sortierschlüssel
case "$SORT_MODE" in
    id)          sort_key=1 ; sort_num=false ; sort_rev=false ;;
    unit)        sort_key=2 ; sort_num=false ; sort_rev=false ;;
    name)        sort_key=3 ; sort_num=false ; sort_rev=false ;;
    factor)      sort_key=4 ; sort_num=true  ; sort_rev=true  ;;
    class)       sort_key=5 ; sort_num=false ; sort_rev=false ;;
    previous)    sort_key=6 ; sort_num=true  ; sort_rev=true  ;;
    curr|current) sort_key=7 ; sort_num=true  ; sort_rev=true  ;;
    date)        sort_key=9 ; sort_num=true  ; sort_rev=true  ;;
    *)
        echo "Ungültiger Sortiermodus: $SORT_MODE"
        exit 1
        ;;
esac

# Rohdaten löschen
if $CLEAR_DATA; then
    if [ -f "$DATA_FILE" ]; then
        echo "Löschen von $DATA_FILE ? (j/N)"
        read -r confirm
        if [[ "$confirm" =~ ^[jJ]$ ]]; then
            rm -f "$DATA_FILE"
            echo "→ Gelöscht."
        else
            echo "→ Abbruch."
        fi
    else
        echo "Keine Datei vorhanden."
    fi
    exit 0
fi

# Funktion: Daten laden + tmpfile erzeugen
create_tempfile() {
    tmpfile=$(mktemp)
    total_known=0
    with_values=0

    declare -A hkv_data
    if [ -s "$DATA_FILE" ]; then
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
        done < "$DATA_FILE"
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

        [ -z "$name" ] && name="unbekannt"
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

    done < "$NAMES_FILE" > "$tmpfile"
}

# ────────────────────────────────────────────────────────────────
# Ausgabefunktion mit Collector-Status
# ────────────────────────────────────────────────────────────────
output() {
    clear 2>/dev/null || true

    # Collector-Status anzeigen
    if screen -list | grep -q "$COLLECTOR_SESSION"; then
        printf "Collector-Status: läuft (Live-Log: screen -r $COLLECTOR_SESSION)"
        if $LOOP; then
           printf " | Aktualisierung alle ${LOOP_SEC} Sekunden\n"
        else
           echo ""
        fi   
    else
        echo "Collector-Status: läuft NICHT => Starten: ./$SCRIPT_NAME -col"
    fi
    
    echo ""

    printf "%${ID_WIDTH}s | %${UNIT_WIDTH}s | %-${NAME_WIDTH}s | %${FAKTOR_WIDTH}s | %-${CLASS_WIDTH}s | %${PREV_WIDTH}s | %${CURR_WIDTH}s | %-${DATE_WIDTH}s\n" \
        "ID" "Unit" "Name" "Factor" "Class" "previous" "current" "letztes Update"

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

    echo "Bekannte HKVs gesamt: $total_known"
    echo "HKVs mit aktuellen Werten: $with_values / $total_known"
    
    if $LOOP; then
        echo "Beenden: beliebige Taste"
    fi    

    rm -f "$tmpfile"
}

# ────────────────────────────────────────────────────────────────
# Hauptlogik
# ────────────────────────────────────────────────────────────────

export COLLECTOR_SESSION
if $LOOP; then
    trap '
        echo "Beende Collector automatisch..."
        # Spezifisch nur diese Session killen (nicht alle screens!)
        screen -S "$COLLECTOR_SESSION" -X quit 2>/dev/null || true
        # Falls screen-Prozesse hängen bleiben (manchmal passiert das)
        pkill -f "SCREEN.*$COLLECTOR_SESSION" 2>/dev/null || true
        pkill -f "wmbusmeters.*$COLLECTOR_SESSION" 2>/dev/null || true
        rm -f "$tmpfile" 2>/dev/null
        exit 0
    ' INT TERM EXIT

    while true; do
        create_tempfile
        output

        if read -n 1 -t "$LOOP_SEC" key 2>/dev/null; then
            if [[ "$key" == $'\n' ]]; then
                :   # Enter → sofort neu laden
            else
                break   # Trap wird automatisch ausgeführt
            fi
        fi
    done
else
    create_tempfile
    output
fi

# Export nur außerhalb Loop
if $EXPORT && ! $LOOP; then
    REPORT_FILE="hkv_stand_$(date +%Y-%m-%d_%H%M).txt"
    create_tempfile
    output > "$REPORT_FILE"
    echo "Ausgabe gespeichert in: $REPORT_FILE"
fi


