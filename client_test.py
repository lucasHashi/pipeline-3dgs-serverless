#!/usr/bin/env python3
"""
client_test.py
Script para testar e monitorar requisições ao Endpoint Serverless 3DGS no RunPod.
Compatível com execução local (Windows/Mac/Linux) e Google Colab.
"""

import os
import sys
import time
import requests

# ==============================================================================
# CONFIGURAÇÕES (Preencha aqui ou configure via variáveis de ambiente)
# ==============================================================================
RUNPOD_API_KEY = os.environ.get("RUNPOD_API_KEY", "SUA_API_KEY_DO_RUNPOD")
ENDPOINT_ID = os.environ.get("ENDPOINT_ID", "SEU_ENDPOINT_ID")  # Exemplo: abc123xyz

# Exemplo de payload com URLs hospedadas no Cloudflare R2 ou qualquer storage HTTP/S
DEFAULT_PAYLOAD = {
    "input": {
        "project_id": f"teste_sala_{int(time.time())}",
        "video_urls": [
            # Substitua pelas URLs reais dos seus vídeos no Cloudflare R2:
            "https://meu-storage-r2.com/videos/video_frente.mp4",
            "https://meu-storage-r2.com/videos/video_tras.mp4",
        ],
        # Parâmetros opcionais de ajuste fino:
        "fps": 2,               # Frames por segundo extraídos de cada vídeo
        "max_iterations": 30000 # Iterações de treino do splatfacto (30k é o padrão de alta fidelidade)
    }
}
# ==============================================================================


def run_pipeline(payload: dict = None):
    if payload is None:
        payload = DEFAULT_PAYLOAD

    if RUNPOD_API_KEY == "SUA_API_KEY_DO_RUNPOD" or ENDPOINT_ID == "SEU_ENDPOINT_ID":
        print("❌ ATENÇÃO: Configure seu RUNPOD_API_KEY e ENDPOINT_ID antes de rodar.")
        print("   Você pode definir via variáveis de ambiente ou editar diretamente no topo deste script.")
        sys.exit(1)

    headers = {
        "Authorization": f"Bearer {RUNPOD_API_KEY}",
        "Content-Type": "application/json",
    }

    run_url = f"https://api.runpod.ai/v2/{ENDPOINT_ID}/run"

    print("🚀 Enviando requisição para o RunPod Serverless...")
    print(f"   Endpoint: {ENDPOINT_ID}")
    print(f"   Project ID: {payload['input'].get('project_id')}")
    print(f"   Vídeos: {len(payload['input'].get('video_urls', []))} arquivo(s)")

    try:
        response = requests.post(run_url, json=payload, headers=headers, timeout=30)
        response.raise_for_status()
        job_data = response.json()
    except Exception as e:
        print(f"❌ Erro ao disparar o job: {e}")
        sys.exit(1)

    job_id = job_data.get("id")
    if not job_id:
        print(f"❌ Resposta inesperada do RunPod: {job_data}")
        sys.exit(1)

    print(f"✅ Job criado com sucesso! ID: {job_id}")
    print("⏳ Aguardando processamento...")
    print("   (Extração de frames -> COLMAP SfM -> Treinamento 3DGS -> Exportação .ply)")

    status_url = f"https://api.runpod.ai/v2/{ENDPOINT_ID}/status/{job_id}"
    start_time = time.time()
    last_status = None

    while True:
        try:
            res = requests.get(status_url, headers=headers, timeout=30).json()
            status = res.get("status")
        except Exception as e:
            print(f"\n⚠️ Falha temporária de conexão ao consultar status ({e}), tentando novamente...")
            time.sleep(15)
            continue

        if status != last_status:
            mins_elapsed = round((time.time() - start_time) / 60, 1)
            print(f"\n[{mins_elapsed} min] Status atual: {status}")
            last_status = status

        if status == "COMPLETED":
            output = res.get("output", {})
            total_time = round((time.time() - start_time) / 60, 2)
            print("\n" + "=" * 60)
            print(f"🎉 SUCESSO! Modelo 3DGS gerado em {total_time} minutos.")
            print(f"📦 Arquivo: {output.get('object_name')}")
            print(f"📊 Tamanho: {output.get('size_mb')} MB")
            print(f"🔗 Link para Download (Válido por 7 dias):")
            print(f"   {output.get('download_url')}")

            if output.get("public_url"):
                print(f"🌐 Link Público R2:")
                print(f"   {output.get('public_url')}")
            print("=" * 60)
            break

        elif status == "FAILED":
            print("\n" + "=" * 60)
            print("❌ Falha no processamento do Job no RunPod.")
            print(f"Erro reportado: {res.get('error')}")
            print("Consulte a aba Serverless > Requests no painel do RunPod para ver os logs completos do container.")
            print("=" * 60)
            break

        else:
            # Em progresso: IN_QUEUE ou IN_PROGRESS
            print(".", end="", flush=True)
            time.sleep(20)


if __name__ == "__main__":
    run_pipeline()
