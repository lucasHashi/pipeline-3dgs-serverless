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

# Instala gsplat pré-compilado para PyTorch 2.4 e CUDA 12.4 (evita compilação de 20 min)
RUN pip install --no-cache-dir gsplat --index-url https://docs.gsplat.studio/whl/pt24cu124

# Instala nerfstudio auditado e bibliotecas do handler (RunPod e Boto3 para R2)
RUN pip install --no-cache-dir \
    nerfstudio==1.1.5 \
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
