#!/bin/bash
set -euo pipefail

INPUT_DIR="${INPUT_DIR:-/workspace/input}"
RAW_DIR="${RAW_DIR:-/workspace/raw_frames}"
FORMATTED_DIR="${FORMATTED_DIR:-/workspace/dataset_formatado}"
OUTPUT_DIR="${OUTPUT_DIR:-/workspace/output}"
EXPORT_DIR="${EXPORT_DIR:-/workspace/export}"
RESULT_PLY="${RESULT_PLY:-/workspace/resultado.ply}"

FPS_RATE="${FPS_RATE:-2}"
MAX_ITERATIONS="${MAX_ITERATIONS:-30000}"
SFM_TOOL="${SFM_TOOL:-colmap}"
MATCHING_METHOD="${MATCHING_METHOD:-exhaustive}"   # exhaustive é o ideal p/ multi-vídeo
CULL_ALPHA_THRESH="${CULL_ALPHA_THRESH:-0.005}"

echo "=========================================================="
echo ">>> Iniciando Pipeline 3DGS Serverless"
echo ">>> FPS: ${FPS_RATE}"
echo ">>> SfM Tool: ${SFM_TOOL} | Matching: ${MATCHING_METHOD}"
echo ">>> Max Iterations: ${MAX_ITERATIONS}"
echo "=========================================================="

# Limpeza de execuções anteriores (workers serverless são reutilizados entre jobs!)
rm -rf "$RAW_DIR" "$FORMATTED_DIR" "$OUTPUT_DIR" "$EXPORT_DIR" "$RESULT_PLY"
mkdir -p "$RAW_DIR" "$FORMATTED_DIR" "$OUTPUT_DIR" "$EXPORT_DIR"

# ---- 1) Extração de frames de N vídeos ----
echo ">>> [1/4] Extraindo frames dos vídeos a ${FPS_RATE} fps..."
idx=1
video_count=0

for video in "$INPUT_DIR"/*; do
  [ -f "$video" ] || continue
  case "${video,,}" in
    *.mp4|*.mov|*.mkv|*.avi|*.webm) ;;
    *) continue ;;
  esac
  ((video_count++)) || true
  vname=$(basename "${video%.*}" | tr -cd '[:alnum:]_-')
  echo "    -> Processando vídeo ${idx}: $(basename "$video") -> prefixo vid${idx}_${vname}_"
  ffmpeg -v error -i "$video" -vf "fps=${FPS_RATE}" -q:v 2 \
    "${RAW_DIR}/vid${idx}_${vname}_%05d.jpg"
  ((idx++)) || true
done

if [ "$video_count" -eq 0 ]; then
  echo "ERRO: Nenhum vídeo encontrado em ${INPUT_DIR}."
  exit 1
fi

frame_count=$(ls -1 "$RAW_DIR" 2>/dev/null | wc -l)
echo ">>> Total de frames extraídos: ${frame_count}"

# Mínimo de 30 frames (recomendado pelo guia para SfM confiável)
if [ "$frame_count" -lt 30 ]; then
  echo "ERRO: Poucos frames (${frame_count}). Mínimo: 30. Verifique se os vídeos baixaram corretamente."
  exit 1
fi

# ---- 2) SfM (COLMAP, matching exaustivo para casar frames ENTRE vídeos) ----
echo ">>> [2/4] Executando SfM (${SFM_TOOL}, matching=${MATCHING_METHOD})..."
ns-process-data images \
  --data "$RAW_DIR" \
  --output-dir "$FORMATTED_DIR" \
  --matching-method "$MATCHING_METHOD" \
  --sfm-tool "$SFM_TOOL"

if [ ! -f "$FORMATTED_DIR/transforms.json" ]; then
  echo "ERRO: transforms.json não gerado — COLMAP falhou (pouca textura/overlap nos vídeos?)"
  exit 1
fi
echo "✅ SfM OK"

# ---- 3) Treinamento 3DGS ----
echo ">>> [3/4] Treinando modelo 3DGS (splatfacto, ${MAX_ITERATIONS} iterações)..."
ns-train splatfacto \
  --data "$FORMATTED_DIR" \
  --output-dir "$OUTPUT_DIR" \
  --vis tensorboard \
  --pipeline.model.cull-alpha-thresh "$CULL_ALPHA_THRESH" \
  --max-num-iterations "$MAX_ITERATIONS"

# ---- 4) Exportação para .ply ----
echo ">>> [4/4] Exportando gaussian-splat para .ply..."
CONFIG_PATH=$(find "$OUTPUT_DIR" -name "config.yml" | sort -r | head -n 1)

if [ -z "$CONFIG_PATH" ] || [ ! -f "$CONFIG_PATH" ]; then
  echo "ERRO: config.yml do modelo treinado não foi encontrado em ${OUTPUT_DIR}."
  exit 1
fi

echo "    -> Usando config: ${CONFIG_PATH}"
ns-export gaussian-splat \
  --load-config "$CONFIG_PATH" \
  --output-dir "$EXPORT_DIR"

# Localiza o .ply gerado (nome principal ou qualquer .ply como fallback)
if [ -f "$EXPORT_DIR/splat.ply" ]; then
  cp "$EXPORT_DIR/splat.ply" "$RESULT_PLY"
else
  ANY_PLY=$(find "$EXPORT_DIR" -name "*.ply" | head -n 1)
  if [ -n "$ANY_PLY" ] && [ -f "$ANY_PLY" ]; then
    cp "$ANY_PLY" "$RESULT_PLY"
  else
    echo "ERRO: splat.ply não encontrado em ${EXPORT_DIR} após ns-export."
    exit 1
  fi
fi

echo ">>> Pipeline Finalizado com Sucesso! Arquivo: ${RESULT_PLY} ($(du -h "$RESULT_PLY" | cut -f1))"
