FROM dromni/nerfstudio:1.1.5

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Instala bibliotecas do handler Serverless e cliente Cloudflare R2 (S3)
# O ambiente já possui Nerfstudio 1.1.5, gsplat, COLMAP, FFmpeg e CUDA 100% pré-instalados
RUN pip install --no-cache-dir \
    runpod \
    boto3 \
    requests

WORKDIR /workspace

# Copia os scripts do pipeline e handler
COPY process.sh handler.py /workspace/

# Garante permissões de execução e quebras de linha padrão Unix (LF)
RUN chmod +x /workspace/process.sh && \
    sed -i 's/\r$//' /workspace/process.sh

# Inicia o handler serverless em modo unbuffered para logs em tempo real
CMD ["python", "-u", "handler.py"]
