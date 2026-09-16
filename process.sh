#!/bin/bash
set -e

INPUT_DIR="${INPUT_DIR:-/workspace/input}"
RAW_DIR="${RAW_DIR:-/workspace/raw_frames}"
FORMATTED_DIR="${FORMATTED_DIR:-/workspace/dataset_formatado}"
OUTPUT_DIR="${OUTPUT_DIR:-/workspace/output}"
EXPORT_DIR="${EXPORT_DIR:-/workspace/export}"
RESULT_PLY="${RESULT_PLY:-/workspace/resultado.ply}"

FPS_RATE="${FPS_RATE:-2}"
MAX_ITERATIONS="${MAX_ITERATIONS:-30000}"
SFM_TOOL="${SFM_TOOL:-colmap}"
MATCHING_METHOD="${MATCHING_METHOD:-exhaustive}"
CULL_ALPHA_THRESH="${CULL_ALPHA_THRESH:-0.005}"

echo "=========================================================="
echo ">>> Iniciando Pipeline 3DGS Serverless"
echo ">>> FPS: ${FPS_RATE}"
echo ">>> SfM Tool: ${SFM_TOOL} | Matching: ${MATCHING_METHOD}"
echo ">>> Max Iterations: ${MAX_ITERATIONS}"
echo "=========================================================="

# Limpeza de execuções anteriores
rm -rf "$RAW_DIR" "$FORMATTED_DIR" "$OUTPUT_DIR" "$EXPORT_DIR" "$RESULT_PLY"
mkdir -p "$RAW_DIR" "$FORMATTED_DIR" "$OUTPUT_DIR" "$EXPORT_DIR"

echo ">>> [1/4] Extraindo frames dos vídeos a ${FPS_RATE} fps..."
idx=1
shopt -s nullglob nocaseglob
video_count=0

for video in "$INPUT_DIR"/*.{mp4,mov,mkv,avi,webm}; do
  if [ -f "$video" ]; then
    ((video_count++))
    vname=$(basename "$video" | cut -f 1 -d '.')
    echo "    -> Processando vídeo ${idx}: $(basename "$video")"
    ffmpeg -v error -i "$video" -vf "fps=${FPS_RATE}" -q:v 2 "${RAW_DIR}/vid${idx}_${vname}_%05d.jpg"
    ((idx++))
  fi
done
shopt -u nullglob nocaseglob

if [ "$video_count" -eq 0 ]; then
  echo "ERRO: Nenhum vídeo encontrado em ${INPUT_DIR}."
  exit 1
fi

frame_count=$(ls -1 "$RAW_DIR" 2>/dev/null | wc -l)
echo ">>> Total de frames extraídos: ${frame_count}"

if [ "$frame_count" -lt 5 ]; then
  echo "ERRO: Poucos frames gerados (${frame_count}). Mínimo recomendado: 5 frames."
  exit 1
fi

echo ">>> [2/4] Executando SfM (Structure from Motion)..."
ns-process-data images \
  --data "$RAW_DIR" \
  --output-dir "$FORMATTED_DIR" \
  --matching-method "$MATCHING_METHOD" \
  --sfm-tool "$SFM_TOOL"

echo ">>> [3/4] Treinando modelo 3DGS (splatfacto)..."
ns-train splatfacto \
  --data "$FORMATTED_DIR" \
  --output-dir "$OUTPUT_DIR" \
  --vis tensorboard \
  --pipeline.model.cull-alpha-thresh "$CULL_ALPHA_THRESH" \
  --max-num-iterations "$MAX_ITERATIONS"

echo ">>> [4/4] Exportando arquivo .ply final..."
CONFIG_PATH=$(find "$OUTPUT_DIR" -name "config.yml" | head -n 1)

if [ -z "$CONFIG_PATH" ] || [ ! -f "$CONFIG_PATH" ]; then
  echo "ERRO: config.yml do modelo treinado não foi encontrado em ${OUTPUT_DIR}."
  exit 1
fi

echo "    -> Usando config: ${CONFIG_PATH}"
ns-export gaussian-splat \
  --load-config "$CONFIG_PATH" \
  --output-dir "$EXPORT_DIR"

if [ -f "$EXPORT_DIR/splat.ply" ]; then
  cp "$EXPORT_DIR/splat.ply" "$RESULT_PLY"
  echo ">>> Sucesso! Arquivo gerado em ${RESULT_PLY} ($(du -h "$RESULT_PLY" | cut -f1))"
else
  # Tenta localizar qualquer .ply gerado pelo export
  ANY_PLY=$(find "$EXPORT_DIR" -name "*.ply" | head -n 1)
  if [ -n "$ANY_PLY" ] && [ -f "$ANY_PLY" ]; then
    cp "$ANY_PLY" "$RESULT_PLY"
    echo ">>> Sucesso! Arquivo gerado em ${RESULT_PLY} ($(du -h "$RESULT_PLY" | cut -f1))"
  else
    echo "ERRO: splat.ply não encontrado em ${EXPORT_DIR} após ns-export."
    exit 1
  fi
fi

echo ">>> Pipeline Finalizado com Sucesso."
