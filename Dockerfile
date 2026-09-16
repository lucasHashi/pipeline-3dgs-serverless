FROM pytorch/pytorch:2.4.1-cuda12.4-cudnn9-devel

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${PATH}

# Instala ferramentas do sistema (FFmpeg, COLMAP e compilação)
RUN apt-get update -qq && apt-get install -y -qq \
    ffmpeg \
    colmap \
    ninja-build \
    build-essential \
    git \
    libgl1 \
    libgl1-mesa-glx \
    libglib2.0-0 \
    wget \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Atualiza instaladores
RUN pip install --no-cache-dir --upgrade pip setuptools wheel

# Instala gsplat pré-compilado para PyTorch 2.4 e CUDA 12.4 e Nerfstudio oficial
RUN pip install --no-cache-dir gsplat --index-url https://docs.gsplat.studio/whl/pt24cu124
RUN pip install --no-cache-dir nerfstudio==1.1.5 runpod boto3 requests

WORKDIR /workspace

# Copia os scripts do pipeline e handler
COPY process.sh handler.py /workspace/

# Permissões de execução e garantia de quebras de linha Unix
RUN chmod +x /workspace/process.sh && \
    sed -i 's/\r$//' /workspace/process.sh

# Garante que não há entrypoint herdado interferindo na execução do RunPod
ENTRYPOINT []

CMD ["python", "-u", "handler.py"]

