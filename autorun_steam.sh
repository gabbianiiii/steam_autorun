#!/bin/bash

INTERVAL=1

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

find_steam() {
    if command -v steam >/dev/null 2>&1; then
        command -v steam
        return 0
    fi

    local paths=(
        "/usr/bin/steam"
        "/usr/games/steam"
        "/usr/local/bin/steam"
        "$HOME/.steam/steam/steam"
        "$HOME/.local/share/Steam/steam"
    )

    for path in "${paths[@]}"; do
        if [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

STEAM=$(find_steam)

if [ -z "$STEAM" ]; then
    echo "ERRO: Steam não encontrada."
    exit 1
fi

log "Steam encontrada: $STEAM"

MOUNT_BASES=(
    "/media/$USER"
    "/run/media/$USER"
)

ACTIVE_USB=""
ACTIVE_APPID=""
REAPER_PID=""
GAME_PIDS=()

find_usb() {
    for base in "${MOUNT_BASES[@]}"; do
        [ -d "$base" ] || continue

        for dir in "$base"/*; do
            [ -d "$dir" ] || continue

            if [ -f "$dir/game.start" ]; then
                echo "$dir"
                return 0
            fi
        done
    done

    return 1
}

read_appid() {
    local file="$1/game.start"

    grep -oE 'AppID[[:space:]]*=[[:space:]]*[0-9]+' "$file" 2>/dev/null \
        | grep -oE '[0-9]+' \
        | head -n1
}

get_game_name() {
    local appid="$1"

    curl -fsS \
        "https://store.steampowered.com/api/appdetails?appids=${appid}&l=brazilian" |
        jq -r --arg id "$appid" '.[$id].data.name // empty'
}

find_reaper() {
    local appid="$1"

    ps -u "$USER" -o pid=,comm=,args= |
        awk -v appid="$appid" '
            $2 == "reaper" && $0 ~ ("AppId=" appid) {
                print $1
                exit
            }
        '
}

get_descendants() {
    local parent="$1"

    ps -u "$USER" -o pid=,ppid= |
        awk -v p="$parent" '$2 == p { print $1 }'
}

capture_process_tree() {
    local root="$1"
    local children
    local child

    GAME_PIDS+=("$root")

    children=$(get_descendants "$root")

    for child in $children; do
        capture_process_tree "$child"
    done
}

process_exists() {
    kill -0 "$1" 2>/dev/null
}

kill_game_tree() {
    log "Encerrando árvore de processos..."

    # Primeiro TERM nos filhos
    for (( i=${#GAME_PIDS[@]}-1; i>=0; i-- )); do
        local pid="${GAME_PIDS[$i]}"

        if process_exists "$pid"; then
            log "TERM -> PID $pid"
            kill -TERM "$pid" 2>/dev/null
        fi
    done

    # Dá alguns segundos para o encerramento normal
    for i in {1..5}; do
        local alive=0

        for pid in "${GAME_PIDS[@]}"; do
            if process_exists "$pid"; then
                alive=1
                break
            fi
        done

        [ "$alive" -eq 0 ] && break

        log "Aguardando encerramento... $i/5"
        sleep 1
    done

    # Agora KILL no que sobrou
    for (( i=${#GAME_PIDS[@]}-1; i>=0; i-- )); do
        local pid="${GAME_PIDS[$i]}"

        if process_exists "$pid"; then
            log "KILL -> PID $pid"
            kill -KILL "$pid" 2>/dev/null
        fi
    done

    sleep 2
}

launch_game() {
    local appid="$1"
    local game="$2"

    log "Iniciando o jogo $game..."

    "$STEAM" -applaunch "$appid" >/dev/null 2>&1 &

    log "Jogo iniciado!"
}

log "=========================================="
log "MONITOR USB + STEAM"
log "=========================================="
log "Monitorando pendrives..."

while true; do

    USB=$(find_usb)

    # ==========================================================
    # NENHUM PENDRIVE ATIVO
    # ==========================================================

    if [ -z "$ACTIVE_USB" ]; then

        if [ -n "$USB" ]; then

            APPID=$(read_appid "$USB")
	    
            if [ -n "$APPID" ]; then
		GAME_NAME=$(get_game_name "$APPID")
		
                log "=========================================="
                log "PENDRIVE DETECTADO"
                log "=========================================="
                log "Pasta: $USB"
                log "AppID: $APPID"

                ACTIVE_USB="$USB"
                ACTIVE_APPID="$APPID"

                launch_game "$APPID" "$GAME_NAME"

                log "Procurando REAPER do jogo..."

                # Espera o REAPER aparecer
                for i in {1..60}; do

                    # Se o pendrive saiu durante a inicialização
                    if [ ! -d "$ACTIVE_USB" ]; then
                        log "Pendrive removido durante a inicialização."
                        break
                    fi

                    REAPER_PID=$(find_reaper "$APPID")

                    if [ -n "$REAPER_PID" ]; then
                        log "REAPER encontrado: PID $REAPER_PID"
                        break
                    fi

                    sleep 1
                done

                # Captura toda a árvore enquanto ela ainda existe
                if [ -n "$REAPER_PID" ]; then

                    GAME_PIDS=()

                    log "Capturando árvore de processos..."

                    capture_process_tree "$REAPER_PID"

                    log "Processos registrados:"

                    for pid in "${GAME_PIDS[@]}"; do
                        ps -p "$pid" -o pid=,ppid=,comm=,args= 2>/dev/null
                    done

                    log "Árvore registrada com ${#GAME_PIDS[@]} processos."

                else
                    log "ATENÇÃO: REAPER não encontrado."
                fi
            fi
        fi

    # ==========================================================
    # PENDRIVE ATIVO
    # ==========================================================

    else

        # O diretório do pendrive desapareceu
        if [ ! -d "$ACTIVE_USB" ]; then

            log ""
            log "=========================================="
            log "PENDRIVE REMOVIDO"
            log "=========================================="
            log "AppID: $ACTIVE_APPID"
            log "REAPER registrado: ${REAPER_PID:-nenhum}"
            log "Processos registrados: ${#GAME_PIDS[@]}"

            if [ "${#GAME_PIDS[@]}" -gt 0 ]; then
                kill_game_tree
            else
                log "Nenhuma árvore de processos foi registrada."
            fi

            log "=========================================="
            log "JOGO ENCERRADO COM SUCESSO"
            log "=========================================="
            log ""

            ACTIVE_USB=""
            ACTIVE_APPID=""
            REAPER_PID=""
            GAME_PIDS=()
        fi
    fi

    sleep "$INTERVAL"

done
