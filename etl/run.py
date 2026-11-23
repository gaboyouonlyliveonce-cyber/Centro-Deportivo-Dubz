"""Ejecuta los 5 ETL de la Miscelánea III y verifica sus salidas Parquet.

Uso (dentro del contenedor pyspark):
    python /app/etl/run.py                      # los 5 ETL
    python /app/etl/run.py --solo ProgresoAtletasETL
    python /app/etl/run.py --params /ruta/otro.json
"""
import argparse
import importlib
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from config import cargar_parametros  # noqa: E402
from spark_utils import construir_spark  # noqa: E402


def asegurar_bucket(lh: dict) -> None:
    """Crea el bucket del lakehouse en ministack si no existe (boto3 contra el endpoint S3)."""
    import boto3
    from botocore.exceptions import ClientError

    s3 = boto3.client(
        "s3",
        endpoint_url=lh["endpoint"],
        aws_access_key_id=lh["access_key"],
        aws_secret_access_key=lh["secret_key"],
        region_name=lh["region"],
    )
    try:
        s3.head_bucket(Bucket=lh["bucket"])
    except ClientError:
        s3.create_bucket(Bucket=lh["bucket"])
        print(f"[run] bucket creado: s3://{lh['bucket']}")


def verificar_parquet_local(spark, ruta_local: str, tabla: str, filas_esperadas: int) -> dict:
    carpeta = Path(ruta_local) / tabla
    archivos = sorted(carpeta.rglob("*.parquet"))
    particiones = sorted({a.parent.name for a in archivos if a.parent != carpeta})
    filas = spark.read.parquet(str(carpeta)).count() if archivos else 0
    return {
        "ruta": str(carpeta),
        "archivos_parquet": len(archivos),
        "particiones": particiones,
        "bytes": sum(a.stat().st_size for a in archivos),
        "filas_leidas": filas,
        "ok": len(archivos) >= 1 and filas == filas_esperadas,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", default=None)
    ap.add_argument("--solo", default=None, help="nombre de la clase ETL a ejecutar")
    args = ap.parse_args()

    params = cargar_parametros(args.params)
    lh = params["lakehouse"]
    if "s3" in params["salida"]["destinos"] and lh.get("crear_bucket"):
        asegurar_bucket(lh)

    spark = construir_spark(params)
    resumen, fallos = [], 0
    for cfg in params["etls"]:
        if not cfg["habilitado"] or (args.solo and cfg["clase"] != args.solo):
            continue
        t0 = time.time()
        try:
            clase = getattr(importlib.import_module(cfg["clase"]), cfg["clase"])
            res = clase(spark, params, cfg).ejecutar()
            ver = (
                verificar_parquet_local(spark, params["salida"]["ruta_local"], res["tabla"], res["filas"])
                if "local" in params["salida"]["destinos"]
                else {"ok": True}
            )
            ok = ver["ok"]
            print(f"[{'OK' if ok else 'FALLO'}] {cfg['clase']:<32} -> {res['tabla']:<28} "
                  f"filas={res['filas']:<6} {time.time() - t0:5.1f}s  {ver}  iceberg={res['iceberg']}")
        except Exception as exc:  # noqa: BLE001  (se reporta y se sigue con el siguiente ETL)
            ok = False
            print(f"[FALLO] {cfg['clase']}: {type(exc).__name__}: {str(exc)[:500]}")
        fallos += 0 if ok else 1
        resumen.append((cfg["clase"], ok))

    spark.stop()
    print(f"[run] {len(resumen) - fallos}/{len(resumen)} ETL correctos")
    return 1 if fallos else 0


if __name__ == "__main__":
    sys.exit(main())
