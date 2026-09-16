FROM pytorch/pytorch:2.4.1-cuda12.4-cudnn9-devel

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${PATH}
# Qt residual (pymeshlab etc.) nunca procurará display em container headless
ENV QT_QPA_PLATFORM=offscreen

# Dependências do pipeline + deps de build do COLMAP (SEM o pacote 'colmap' do apt)
RUN apt-get update -qq && apt-get install -y -qq \
    ffmpeg ninja-build build-essential git wget curl ca-certificates \
    zip unzip libgl1 libopengl0 libglib2.0-0 \
    libboost-program-options-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libflann-dev libfreeimage-dev libmetis-dev \
    libgoogle-glog-dev libgflags-dev libsqlite3-dev libglew-dev \
    libceres-dev libcurl4-openssl-dev libcgal-dev \
    && rm -rf /var/lib/apt/lists/*

# CMake moderno (COLMAP 3.12+ exige >= 3.28; o do Ubuntu 22.04 é 3.22)
RUN pip install --no-cache-dir "cmake==3.31.*"

# COLMAP 3.11.0 do source: sem GUI/Qt, SIFT via CUDA (headless de verdade)
# Archs: 86=A6000/3090/A40/A5000, 89=4090/L40
# -DGUI_ENABLED=OFF = sem Qt, sem X11, sem SIGABRT em container headless
# -DCUDA_ENABLED=ON = SIFT via CUDA real (não OpenGL)
RUN git clone --depth 1 --branch 3.11.0 https://github.com/colmap/colmap.git /tmp/colmap \
    && cmake -S /tmp/colmap -B /tmp/colmap/build -GNinja \
       -DGUI_ENABLED=OFF \
       -DOPENGL_ENABLED=OFF \
       -DCUDA_ENABLED=ON \
       -DTESTS_ENABLED=OFF \
       -DCMAKE_CUDA_ARCHITECTURES="86;89" \
    && cmake --build /tmp/colmap/build -j$(nproc) \
    && cmake --install /tmp/colmap/build \
    && rm -rf /tmp/colmap

# Guarda: garante que a CLI aceita as flags que o nerfstudio 1.1.5 hardcoda
RUN colmap feature_extractor -h 2>&1 | grep -q "SiftExtraction.use_gpu" \
    && colmap exhaustive_matcher -h 2>&1 | grep -q "SiftMatching.use_gpu" \
    && echo ">>> COLMAP CLI compatível com nerfstudio 1.1.5" \
    || (echo ">>> ERRO FATAL: COLMAP incompatível — use a tag 3.11.0" && exit 1)

RUN pip install --no-cache-dir --upgrade pip setuptools wheel

# gsplat pré-compilado (evita JIT de 5-15 min no cold start)
RUN pip install --no-cache-dir gsplat==1.4.0 \
        --index-url https://docs.gsplat.studio/whl/pt24cu124 \
    || pip install --no-cache-dir gsplat==1.4.0

RUN pip install --no-cache-dir \
    nerfstudio==1.1.5 \
    "runpod==1.*" \
    "boto3==1.*" \
    "requests==2.*"

# Pré-compila a extensão CUDA do gsplat DENTRO da imagem
# Archs: 8.0 (A100), 8.6 (A6000/3090), 8.9 (4090/L40/A5000), 9.0 (H100)
ENV TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0"
RUN MAX_JOBS=$(nproc) python -c "from gsplat.cuda._backend import _C; print('>>> gsplat CUDA pré-compilado OK')" \
    || echo ">>> warmup do gsplat falhou; fará JIT no 1º job (apenas 1x por worker)"

WORKDIR /workspace
COPY process.sh handler.py /workspace/
RUN chmod +x /workspace/process.sh && \
    sed -i 's/\r$//' /workspace/process.sh

ENTRYPOINT []
CMD ["python", "-u", "handler.py"]
