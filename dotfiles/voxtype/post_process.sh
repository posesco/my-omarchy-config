#!/bin/bash

# Leer texto de la transcripción
RAW_TEXT=$(cat)
if [ -z "$RAW_TEXT" ]; then
    exit 0
fi

# 1. Iniciar llama-server a demanda
"$HOME/.local/bin/llm" --port 18080 --no-warmup >/dev/null 2>&1 &
LLM_PID=$!

# Asegurar que limpiamos el proceso al salir del script, pase lo que pase
cleanup() {
    if [ ! -z "$LLM_PID" ] && kill -0 "$LLM_PID" 2>/dev/null; then
        kill "$LLM_PID" 2>/dev/null
        wait "$LLM_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

# 2. Esperar a que el servidor esté listo (máximo 5 segundos, 50 * 0.1s)
READY=0
for i in {1..50}; do
    res=$(curl -s --max-time 1 http://127.0.0.1:18080/health 2>/dev/null)
    if [ ! -z "$res" ] && echo "$res" | grep -q '"status": *"ok"'; then
        READY=1
        break
    fi
    sleep 0.1
done

if [ "$READY" -ne 1 ]; then
    # Si no inició, retornamos el texto original
    LOG_TEXT="$RAW_TEXT"
    FINAL_OUTPUT="$RAW_TEXT"
else
    # 3. Preparar JSON y enviar petición
    PAYLOAD=$(jq -n \
      --arg prompt "Corrige la ortografía, gramática y puntuación del siguiente dictado en español. Remueve muletillas (eh, este, bueno, o sea) y repeticiones, y mantén el tono natural del texto. Responde ÚNICAMENTE con el texto corregido, sin notas, introducciones ni explicaciones adicionales." \
      --arg text "$RAW_TEXT" \
      '{
        model: "qwen",
        messages: [
          {role: "system", content: $prompt},
          {role: "user", content: $text}
        ],
        temperature: 0.3
      }')

    CORRECTED_TEXT=$(curl -s -X POST http://127.0.0.1:18080/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" | jq -r '.choices[0].message.content' 2>/dev/null)

    # Definir texto final
    if [ -z "$CORRECTED_TEXT" ] || [ "$CORRECTED_TEXT" = "null" ]; then
        LOG_TEXT="$RAW_TEXT"
        FINAL_OUTPUT="$RAW_TEXT"
    else
        LOG_TEXT="$CORRECTED_TEXT"
        FINAL_OUTPUT=$(echo "$CORRECTED_TEXT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
fi

# 4. Registrar en el histórico (SQLite) de forma segura mediante Python
python3 -c '
import sqlite3, sys, os
data_home = os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share"))
db_path = os.path.join(data_home, "voxtype/history.db")
os.makedirs(os.path.dirname(db_path), exist_ok=True)
conn = sqlite3.connect(db_path)
c = conn.cursor()
c.execute("CREATE TABLE IF NOT EXISTS transcriptions (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp DATETIME DEFAULT CURRENT_TIMESTAMP, raw_text TEXT, corrected_text TEXT)")
c.execute("INSERT INTO transcriptions (raw_text, corrected_text) VALUES (?, ?)", (sys.argv[1], sys.argv[2]))
conn.commit()
conn.close()
' "$RAW_TEXT" "$LOG_TEXT"

# 5. Retornar salida final al cursor
echo "$FINAL_OUTPUT"
