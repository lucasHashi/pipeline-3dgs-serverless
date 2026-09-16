FROM pytorch/pytorch:2.4.1-cuda12.4-cudnn9-devel

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${PATH}

# Instala pacotes do sistema necessários para ffmpeg, colmap e compilações auxiliares
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

# Atualiza ferramentas Python fundamentais
RUN pip install --no-cache-dir --upgrade pip setuptools wheel

# Instalação com versões auditadas (nerfstudio 1.1.5, gsplat 1.4.0, runpod e boto3 para Cloudflare R2)
RUN pip install --no-cache-dir \
    nerfstudio==1.1.5 \
    gsplat==1.4.0 \
    runpod \
    boto3 \
    requests

WORKDIR /workspace

# Copia os scripts do motor e do handler
COPY process.sh handler.py /workspace/

# Permissão de execução e conversão de quebras de linha para padrão Unix
RUN chmod +x /workspace/process.sh && \
    sed -i 's/\r$//' /workspace/process.sh

# Inicia o handler serverless em modo unbuffered para logs em tempo real
CMD ["python", "-u", "handler.py"]
