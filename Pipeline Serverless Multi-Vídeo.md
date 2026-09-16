# **Pipeline Serverless: Multi-Vídeo → 3DGS (RunPod)**

Este guia descreve como configurar uma arquitetura **Serverless** no RunPod para gerar modelos 3D (.ply) a partir de múltiplos vídeos. Todo o ambiente (PyTorch, COLMAP, GLOMAP, Nerfstudio) é empacotado na nuvem.

O servidor "acorda" ao receber uma requisição de API com as URLs dos vídeos, baixa os arquivos, processa usando glomap e splatfacto, faz o upload do .ply para o seu storage (S3/Supabase), e "dorme".

## **Passo 1: Preparação de Contas (100% Nuvem)**

Você não instalará Docker nem Python localmente para construir isso. Usaremos:

1. **RunPod:** Para rodar a GPU (Gere uma API Key em *Settings \> API Keys*).  
2. **Docker Hub (Gratuito):** Crie uma conta para hospedar sua imagem de container.  
3. **GitHub (Gratuito):** Fará a compilação pesada do Docker.  
4. **Storage (AWS S3, Cloudflare R2 ou Supabase):** Onde o arquivo .ply será salvo (Tenha os dados: ACCESS\_KEY, SECRET\_KEY, ENDPOINT\_URL e BUCKET).

## **Passo 2: Criando a Imagem Docker Customizada (Via GitHub)**

Vamos criar um repositório no GitHub para "fabricar" sua infraestrutura.

### **1\. Configure os Segredos no GitHub**

Crie um repositório no GitHub (ex: pipeline-3dgs-serverless).

Vá em **Settings \> Secrets and variables \> Actions** e crie:

* DOCKERHUB\_USERNAME (Seu usuário do Docker Hub)  
* DOCKERHUB\_TOKEN (Sua senha ou Token do Docker Hub)

### **2\. Crie os arquivos no repositório**

Crie os 4 arquivos abaixo diretamente na interface web do GitHub:

**Arquivo 1: process.sh** (O Motor)

\#\!/bin/bash  
set \-e

INPUT\_DIR="/workspace/input"  
RAW\_DIR="/workspace/raw\_frames"  
FORMATTED\_DIR="/workspace/dataset\_formatado"  
OUTPUT\_DIR="/workspace/output"  
FPS\_RATE=2

\# Limpeza e preparação  
rm \-rf "$RAW\_DIR" "$FORMATTED\_DIR" "$OUTPUT\_DIR" /workspace/resultado.ply  
mkdir \-p "$RAW\_DIR" "$FORMATTED\_DIR" "$OUTPUT\_DIR"

echo "\>\>\> Iniciando extração de frames a ${FPS\_RATE} fps..."  
idx=1  
shopt \-s nullglob nocaseglob  
for video in "$INPUT\_DIR"/\*.{mp4,mov,mkv}; do  
&nbsp;&nbsp;echo "\>\>\> Extraindo: $(basename "$video")"  
&nbsp;&nbsp;vname=$(basename "$video" | cut \-f 1 \-d '.')  
&nbsp;&nbsp;ffmpeg \-v error \-i "$video" \-vf "fps=${FPS\_RATE}" \-q:v 2 "${RAW\_DIR}/vid${idx}\_${vname}\_%05d.jpg"  
&nbsp;&nbsp;((idx++))  
done  
shopt \-u nullglob nocaseglob

echo "\>\>\> Total de frames: $(ls "$RAW\_DIR" | wc \-l)"

echo "\>\>\> Rodando SfM com GLOMAP (Matching Exaustivo para Multi-video)..."  
ns-process-data images \\  
&nbsp;&nbsp;\--data "$RAW\_DIR" \\  
&nbsp;&nbsp;\--output-dir "$FORMATTED\_DIR" \\  
&nbsp;&nbsp;\--matching-method exhaustive \\  
&nbsp;&nbsp;\--sfm-tool glomap

echo "\>\>\> Iniciando treinamento 3DGS (splatfacto)..."  
ns-train splatfacto \\  
&nbsp;&nbsp;\--data "$FORMATTED\_DIR" \\  
&nbsp;&nbsp;\--output-dir "$OUTPUT\_DIR" \\  
&nbsp;&nbsp;\--vis tensorboard \\  
&nbsp;&nbsp;\--pipeline.model.cull-alpha-thresh 0.005 \\  
&nbsp;&nbsp;\--max-num-iterations 30000

echo "\>\>\> Copiando resultado final..."  
find "$OUTPUT\_DIR" \-name "splat.ply" \-exec cp {} /workspace/resultado.ply \\;  
echo "\>\>\> Pipeline Finalizado."

**Arquivo 2: handler.py** (A API Serverless do RunPod)

import os  
import runpod  
import subprocess  
import urllib.request  
import boto3  
from botocore.client import Config

S3\_ENDPOINT \= os.environ.get("S3\_ENDPOINT")  
S3\_BUCKET \= os.environ.get("S3\_BUCKET")  
AWS\_ACCESS\_KEY\_ID \= os.environ.get("AWS\_ACCESS\_KEY\_ID")  
AWS\_SECRET\_ACCESS\_KEY \= os.environ.get("AWS\_SECRET\_ACCESS\_KEY")

def upload\_to\_s3(file\_path, object\_name):  
&nbsp;&nbsp;&nbsp;&nbsp;s3 \= boto3.client('s3', endpoint\_url=S3\_ENDPOINT,  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;aws\_access\_key\_id=AWS\_ACCESS\_KEY\_ID,  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;aws\_secret\_access\_key=AWS\_SECRET\_ACCESS\_KEY,  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;config=Config(signature\_version='s3v4'))  
&nbsp;&nbsp;&nbsp;&nbsp;s3.upload\_file(file\_path, S3\_BUCKET, object\_name)  
&nbsp;&nbsp;&nbsp;&nbsp;return s3.generate\_presigned\_url('get\_object', Params={'Bucket': S3\_BUCKET, 'Key': object\_name}, ExpiresIn=604800)

def download\_videos(urls):  
&nbsp;&nbsp;&nbsp;&nbsp;os.makedirs("/workspace/input", exist\_ok=True)  
&nbsp;&nbsp;&nbsp;&nbsp;\# Limpa pasta de input anterior  
&nbsp;&nbsp;&nbsp;&nbsp;for f in os.listdir("/workspace/input"): os.remove(os.path.join("/workspace/input", f))  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;  
&nbsp;&nbsp;&nbsp;&nbsp;for idx, url in enumerate(urls):  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;dest \= f"/workspace/input/video\_{idx}.mp4"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print(f"Baixando {url}...")  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\# Adiciona User-Agent para evitar bloqueios simples de Storage  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;req \= urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;with urllib.request.urlopen(req) as response, open(dest, 'wb') as out\_file:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;out\_file.write(response.read())

def handler(job):  
&nbsp;&nbsp;&nbsp;&nbsp;job\_input \= job\['input'\]  
&nbsp;&nbsp;&nbsp;&nbsp;video\_urls \= job\_input.get('video\_urls', \[\])  
&nbsp;&nbsp;&nbsp;&nbsp;project\_id \= job\_input.get('project\_id', job\['id'\])  
&nbsp;&nbsp;&nbsp;&nbsp;  
&nbsp;&nbsp;&nbsp;&nbsp;if not video\_urls: return {"error": "Nenhuma 'video\_urls' fornecida."}  
&nbsp;&nbsp;&nbsp;&nbsp;  
&nbsp;&nbsp;&nbsp;&nbsp;try:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;download\_videos(video\_urls)  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print("Iniciando processamento bash (Extração \-\> GLOMAP \-\> Splatfacto)...")  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;subprocess.run(\["bash", "/workspace/process.sh"\], check=True)  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;ply\_path \= "/workspace/resultado.ply"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;if not os.path.exists(ply\_path): return {"error": "Arquivo .ply não foi gerado. Verifique os logs."}  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;object\_name \= f"splats/{project\_id}.ply"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;download\_url \= upload\_to\_s3(ply\_path, object\_name)  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;return {"status": "success", "download\_url": download\_url}  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;  
&nbsp;&nbsp;&nbsp;&nbsp;except subprocess.CalledProcessError as e:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;return {"error": f"Erro no script bash: código {e.returncode}"}  
&nbsp;&nbsp;&nbsp;&nbsp;except Exception as e:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;return {"error": f"Erro Python: {str(e)}"}

runpod.serverless.start({"handler": handler})

**Arquivo 3: Dockerfile** (Com Versões Fixas/Blindadas)

FROM pytorch/pytorch:2.4.1-cuda12.4-cudnn9-devel

ENV DEBIAN\_FRONTEND=noninteractive  
ENV CUDA\_HOME=/usr/local/cuda  
ENV PATH=${CUDA\_HOME}/bin:${PATH}

\# Instala pacotes do sistema  
RUN apt-get update \-qq && apt-get install \-y \-qq \\  
&nbsp;&nbsp;&nbsp;&nbsp;ffmpeg colmap ninja-build build-essential git libgl1 libglib2.0-0 wget \\  
&nbsp;&nbsp;&nbsp;&nbsp;&& rm \-rf /var/lib/apt/lists/\*

\# Atualiza ferramentas Python  
RUN pip install \--no-cache-dir \--upgrade pip setuptools wheel

\# Instalação FIXA para evitar quebra futura (Versões auditadas)  
RUN pip install \--no-cache-dir nerfstudio==1.1.5 gsplat==1.4.0 runpod boto3

WORKDIR /workspace  
COPY process.sh handler.py /workspace/  
RUN chmod \+x /workspace/process.sh

CMD \["python", "handler.py"\]

**Arquivo 4: .github/workflows/docker.yml**

*(Salve na pasta .github/workflows/)*

name: Build and Push Docker Image  
on:  
&nbsp;&nbsp;push:  
&nbsp;&nbsp;&nbsp;&nbsp;branches: \[ "main" \]  
jobs:  
&nbsp;&nbsp;build:  
&nbsp;&nbsp;&nbsp;&nbsp;runs-on: ubuntu-latest  
&nbsp;&nbsp;&nbsp;&nbsp;steps:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\- name: Checkout code  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;uses: actions/checkout@v3  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\- name: Free Disk Space  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;uses: jlumbroso/free-disk-space@main  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\- name: Login to Docker Hub  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;uses: docker/login-action@v2  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;with:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;username: ${{ secrets.DOCKERHUB\_USERNAME }}  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;password: ${{ secrets.DOCKERHUB\_TOKEN }}  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\- name: Build and push  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;uses: docker/build-push-action@v4  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;with:  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;context: .  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;push: true  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;tags: ${{ secrets.DOCKERHUB\_USERNAME }}/3dgs-serverless:v1

Ao salvar, o GitHub iniciará a compilação (pode demorar uns 15-20 minutos a primeira vez, pois PyTorch/CUDA são pesados). Monitore na aba **Actions**.

## **Passo 3: Configurando o Endpoint no RunPod**

Com a imagem no Docker Hub, crie a API:

1. No painel do RunPod, vá em **Serverless \> Endpoints** \> **New Endpoint**.  
2. **Name:** Gerador\_3DGS.  
3. **GPU Type:** Selecione "NVIDIA RTX A6000" ou 4090\.  
4. **Workers:** Min Workers: 0 (Zero custo ocioso), Max Workers: 3\.  
5. **Container Image:** Coloque seu\_usuario\_do\_dockerhub/3dgs-serverless:v1.  
6. **Environment Variables** (Credenciais de Upload):  
   * S3\_ENDPOINT (ex: https://...supabase.co/storage/v1/s3 ou URL da AWS/R2)  
   * S3\_BUCKET (Nome do seu bucket)  
   * AWS\_ACCESS\_KEY\_ID  
   * AWS\_SECRET\_ACCESS\_KEY  
7. Clique em **Create** e anote seu **Endpoint ID** (ex: abc123xyz).

## **Passo 4: Uso no Dia a Dia (Para Disparar e Acompanhar)**

Você pode disparar via N8N, Make, Postman ou Python. Abaixo está um script simples que você pode rodar em um **Google Colab** (ou no seu terminal local) sempre que quiser gerar um novo modelo.

### **Script Colab/Local:**

import requests  
import time

RUNPOD\_API\_KEY \= "SUA\_API\_KEY\_RUNPOD"  
ENDPOINT\_ID \= "SEU\_ENDPOINT\_ID" \# ex: abc123xyz

url \= f"https://api.runpod.ai/v2/{ENDPOINT\_ID}/run"  
headers \= {  
&nbsp;&nbsp;&nbsp;&nbsp;"Authorization": f"Bearer {RUNPOD\_API\_KEY}",  
&nbsp;&nbsp;&nbsp;&nbsp;"Content-Type": "application/json"  
}

\# Carga de processamento (Insira as URLs dos seus vídeos hospedados)  
payload \= {  
&nbsp;&nbsp;&nbsp;&nbsp;"input": {  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"project\_id": "sala\_de\_estar\_quinta\_feira",  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"video\_urls": \[  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"https://meu-storage.com/video\_frente.mp4",  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;"https://meu-storage.com/video\_tras.mp4"  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;\]  
&nbsp;&nbsp;&nbsp;&nbsp;}  
}

print("🚀 Enviando requisição para o RunPod...")  
response \= requests.post(url, json=payload, headers=headers)  
job\_data \= response.json()  
job\_id \= job\_data.get("id")  
print(f"✅ Job criado\! ID: {job\_id}")

\# Loop de monitoramento (O RunPod segura a requisição em /status)  
status\_url \= f"https://api.runpod.ai/v2/{ENDPOINT\_ID}/status/{job\_id}"  
print("⏳ Aguardando processamento (Isso pode levar de 15 a 40 minutos)...")

while True:  
&nbsp;&nbsp;&nbsp;&nbsp;res \= requests.get(status\_url, headers=headers).json()  
&nbsp;&nbsp;&nbsp;&nbsp;status \= res.get("status")  
&nbsp;&nbsp;&nbsp;&nbsp;  
&nbsp;&nbsp;&nbsp;&nbsp;if status \== "COMPLETED":  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print("\\n🎉 Modelo pronto e enviado para o Storage\!")  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print("📥 Baixe seu .ply aqui:", res\["output"\]\["download\_url"\])  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;break  
&nbsp;&nbsp;&nbsp;&nbsp;elif status \== "FAILED":  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;print("\\n❌ Falha no processamento:", res.get("error"))  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;break  
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;  
&nbsp;&nbsp;&nbsp;&nbsp;print(".", end="", flush=True)  
&nbsp;&nbsp;&nbsp;&nbsp;time.sleep(30) \# Evita spam na API

### **Acompanhando Logs (Opcional)**

Se a tela do script Python estiver demorando, você pode entrar no painel do RunPod \> **Serverless** \> **Requests**. Encontre seu Job ID e clique para ver os logs do terminal em tempo real (você verá o progresso do GLOMAP e as iterações do Treinamento passo a passo).