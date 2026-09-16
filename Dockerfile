FROM pytorch/pytorch:2.4.1-cuda12.4-cudnn9-devel

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${PATH}

# Dependências de sistema (libopengl0 corrige warnings do pymeshlab)
RUN apt-get update -qq && apt-get install -y -qq \
    ffmpeg colmap ninja-build build-essential git wget curl ca-certificates \
    zip unzip libgl1 libopengl0 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip setuptools wheel

# 1) Tenta wheel pré-compilado do gsplat (pt24/cu124); 2) cai no PyPI (JIT) se não houver
RUN pip install --no-cache-dir gsplat==1.4.0 \
        --index-url https://docs.gsplat.studio/whl/pt24cu124 \
    || pip install --no-cache-dir gsplat==1.4.0

# Versões pinadas = build reproduzível
RUN pip install --no-cache-dir \
    nerfstudio==1.1.5 \
    "runpod==1.*" \
    "boto3==1.*" \
    "requests==2.*"

# Pré-compila a extensão CUDA do gsplat DENTRO da imagem.
# Sem isso, todo cold start perderia 5-15 min compilando no worker.
# Archs: 8.0 (A100), 8.6 (A6000/3090), 8.9 (4090/L40), 9.0 (H100)
ENV TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0"
RUN MAX_JOBS=$(nproc) python -c "from gsplat.cuda._backend import _C; print('>>> gsplat CUDA pré-compilado OK')" \
    || echo ">>> warmup falhou; gsplat fará JIT no 1º job (apenas 1x por worker)"

WORKDIR /workspace
COPY process.sh handler.py /workspace/

# Permissões de execução e garantia de quebras de linha Unix
RUN chmod +x /workspace/process.sh && \
    sed -i 's/\r$//' /workspace/process.sh

# Garante que não há entrypoint herdado interferindo na execução do RunPod
ENTRYPOINT []

CMD ["python", "-u", "handler.py"]
