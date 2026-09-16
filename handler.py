import os
import shutil
import subprocess
import time
import urllib.request
import boto3
from botocore.client import Config
import runpod

# Configuração de Storage (Cloudflare R2 / S3-compatible)
R2_ENDPOINT = os.environ.get("R2_ENDPOINT") or os.environ.get("S3_ENDPOINT")
R2_BUCKET = os.environ.get("R2_BUCKET") or os.environ.get("S3_BUCKET")
R2_ACCESS_KEY_ID = os.environ.get("R2_ACCESS_KEY_ID") or os.environ.get("AWS_ACCESS_KEY_ID")
R2_SECRET_ACCESS_KEY = os.environ.get("R2_SECRET_ACCESS_KEY") or os.environ.get("AWS_SECRET_ACCESS_KEY")
R2_REGION = os.environ.get("R2_REGION") or os.environ.get("AWS_REGION", "auto")
R2_PUBLIC_URL = os.environ.get("R2_PUBLIC_URL")  # Ex: https://pub-xxx.r2.dev ou https://cdn.seudominio.com


def get_s3_client():
    if not all([R2_ENDPOINT, R2_BUCKET, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY]):
        raise ValueError(
            "Credenciais do Storage incompletas. Verifique as variáveis de ambiente: "
            "R2_ENDPOINT (ou S3_ENDPOINT), R2_BUCKET, R2_ACCESS_KEY_ID e R2_SECRET_ACCESS_KEY."
        )

    return boto3.client(
        "s3",
        endpoint_url=R2_ENDPOINT,
        aws_access_key_id=R2_ACCESS_KEY_ID,
        aws_secret_access_key=R2_SECRET_ACCESS_KEY,
        region_name=R2_REGION,
        config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    )


def upload_to_storage(file_path: str, object_name: str) -> dict:
    print(f">>> [Storage] Enviando {file_path} para bucket '{R2_BUCKET}' como '{object_name}'...")
    s3 = get_s3_client()

    file_size = os.path.getsize(file_path)
    extra_args = {"ContentType": "application/octet-stream"}

    s3.upload_file(file_path, R2_BUCKET, object_name, ExtraArgs=extra_args)

    # URL pré-assinada válida por 7 dias (604800 segundos)
    presigned_url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": R2_BUCKET, "Key": object_name},
        ExpiresIn=604800,
    )

    result = {
        "bucket": R2_BUCKET,
        "object_name": object_name,
        "size_bytes": file_size,
        "size_mb": round(file_size / (1024 * 1024), 2),
        "download_url": presigned_url,
    }

    # Se houver um domínio público R2 configurado, inclui o link direto
    if R2_PUBLIC_URL:
        clean_base = R2_PUBLIC_URL.rstrip("/")
        result["public_url"] = f"{clean_base}/{object_name}"

    print(f">>> [Storage] Upload concluído! Tamanho: {result['size_mb']} MB")
    return result


def download_videos(urls: list, input_dir: str = "/workspace/input") -> list:
    os.makedirs(input_dir, exist_ok=True)

    # Limpeza de arquivos anteriores
    for f in os.listdir(input_dir):
        fp = os.path.join(input_dir, f)
        if os.path.isfile(fp):
            os.remove(fp)

    downloaded_paths = []
    print(f">>> [Download] Baixando {len(urls)} vídeo(s) para {input_dir}...")

    for idx, url in enumerate(urls):
        # Determina extensão ou usa .mp4 como fallback
        ext = ".mp4"
        clean_url = url.split("?")[0]
        for candidate_ext in [".mp4", ".mov", ".mkv", ".avi", ".webm"]:
            if clean_url.lower().endswith(candidate_ext):
                ext = candidate_ext
                break

        dest = os.path.join(input_dir, f"video_{idx}{ext}")
        print(f"    [{idx + 1}/{len(urls)}] Baixando de {url[:60]}... -> {os.path.basename(dest)}")

        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "Mozilla/5.0 (RunPod-Serverless-3DGS/1.0)",
                "Accept": "*/*",
            },
        )

        with urllib.request.urlopen(req) as response, open(dest, "wb") as out_file:
            # Streaming em blocos de 1MB para não estourar a memória RAM
            shutil.copyfileobj(response, out_file, length=1024 * 1024)

        dest_size = os.path.getsize(dest)
        print(f"    -> Concluído ({round(dest_size / (1024 * 1024), 2)} MB)")
        downloaded_paths.append(dest)

    return downloaded_paths


def handler(job: dict) -> dict:
    job_input = job.get("input", {})

    # Validação de entrada
    video_urls = job_input.get("video_urls")
    if not video_urls:
        # Suporte a chave singular 'video_url'
        single_url = job_input.get("video_url")
        if single_url:
            video_urls = [single_url]

    if not video_urls or not isinstance(video_urls, list):
        return {"error": "Formato inválido. 'video_urls' deve ser uma lista não-vazia de URLs."}

    project_id = str(job_input.get("project_id", job.get("id", f"job_{int(time.time())}")))

    # Parâmetros opcionais de processamento com valores padrão
    fps_rate = str(job_input.get("fps", 2))
    max_iterations = str(job_input.get("max_iterations", 30000))
    sfm_tool = str(job_input.get("sfm_tool", "colmap"))
    matching_method = str(job_input.get("matching_method", "exhaustive"))
    cull_alpha_thresh = str(job_input.get("cull_alpha_thresh", "0.005"))

    # Configuração de variáveis de ambiente para o script bash
    env = os.environ.copy()
    env["FPS_RATE"] = fps_rate
    env["MAX_ITERATIONS"] = max_iterations
    env["SFM_TOOL"] = sfm_tool
    env["MATCHING_METHOD"] = matching_method
    env["CULL_ALPHA_THRESH"] = cull_alpha_thresh

    start_time = time.time()

    try:
        # 1. Download dos vídeos via streaming
        download_videos(video_urls)

        # 2. Execução do pipeline bash (Extração -> SfM -> Treinamento -> Exportação)
        print(">>> [Process] Iniciando script de processamento 3DGS...")
        subprocess.run(["bash", "/workspace/process.sh"], check=True, env=env)

        # 3. Verificação do arquivo gerado
        ply_path = "/workspace/resultado.ply"
        if not os.path.exists(ply_path) or os.path.getsize(ply_path) == 0:
            return {
                "error": "O arquivo resultado.ply não foi encontrado ou está vazio após a execução. Verifique os logs de treino."
            }

        # 4. Upload para o Cloudflare R2 / S3
        object_name = f"splats/{project_id}.ply"
        storage_result = upload_to_storage(ply_path, object_name)

        elapsed_minutes = round((time.time() - start_time) / 60, 2)
        print(f">>> [Job Concluído] Tempo total: {elapsed_minutes} minutos.")

        return {
            "status": "success",
            "project_id": project_id,
            "elapsed_minutes": elapsed_minutes,
            **storage_result,
        }

    except subprocess.CalledProcessError as e:
        error_msg = f"Erro na execução do process.sh (código de saída: {e.returncode})"
        print(f"ERRO: {error_msg}")
        return {"error": error_msg}
    except Exception as e:
        error_msg = f"Exceção durante processamento: {str(e)}"
        print(f"ERRO: {error_msg}")
        return {"error": error_msg}


if __name__ == "__main__":
    runpod.serverless.start({"handler": handler})
