"""Clase base (POO) de los ETL: define el ciclo extraer -> transformar -> cargar."""
from abc import ABC, abstractmethod
from typing import Dict

from pyspark.sql import DataFrame, SparkSession


class BaseETL(ABC):
    """Cada ETL concreto implementa `extraer` y `transformar`; `cargar` es común."""

    def __init__(self, spark: SparkSession, params: dict, config_etl: dict) -> None:
        self.spark = spark
        self.params = params
        self.config = config_etl
        self.tabla_destino: str = config_etl["tabla_destino"]
        self.origen: Dict[str, str] = config_etl["origen"]

    # ---------------------------------------------------------------- extracción (JDBC)
    @property
    def url_jdbc(self) -> str:
        pg = self.params["postgres"]
        sslmode = pg.get("sslmode", "prefer")
        return f"jdbc:postgresql://{pg['host']}:{pg['port']}/{pg['database']}?sslmode={sslmode}"

    def leer(self, alias: str) -> DataFrame:
        """Lee una tabla o vista del OLTP por JDBC usando el alias definido en parameters.json."""
        pg = self.params["postgres"]
        return (
            self.spark.read.format("jdbc")
            .option("url", self.url_jdbc)
            .option("dbtable", self.origen[alias])
            .option("user", pg["user"])
            .option("password", pg["password"])
            .option("driver", pg["driver"])
            .option("fetchsize", str(pg["fetchsize"]))
            .load()
        )

    @abstractmethod
    def extraer(self) -> Dict[str, DataFrame]:
        """Devuelve los DataFrames de origen (con poda de columnas)."""

    @abstractmethod
    def transformar(self, datos: Dict[str, DataFrame]) -> DataFrame:
        """Aplica transformaciones puras encadenadas y devuelve la tabla de hechos/dimensión."""

    # ---------------------------------------------------------------------------- carga
    def cargar(self, df: DataFrame) -> dict:
        """Escribe Parquet (local y/o s3a://ministack) y, si está habilitado, la tabla Iceberg."""
        sal, lh = self.params["salida"], self.params["lakehouse"]
        modo = sal["modo_escritura"]
        df = df.cache()
        resultado = {"tabla": self.tabla_destino, "filas": df.count(), "rutas": [], "iceberg": None}
        particionado = df.coalesce(sal["archivos_por_tabla"])

        part_cols = self.config.get("particionar_por", [])

        def escribir_parquet(ruta: str) -> None:
            writer = particionado.write.mode(modo).option("compression", sal["compresion"])
            if part_cols:
                writer = writer.partitionBy(*part_cols)
            writer.parquet(ruta)
            resultado["rutas"].append(ruta)

        if "local" in sal["destinos"]:
            escribir_parquet(f"{sal['ruta_local'].rstrip('/')}/{self.tabla_destino}")
        if "s3" in sal["destinos"]:
            escribir_parquet(f"s3a://{lh['bucket']}/{lh['prefijo_parquet']}/{self.tabla_destino}")

        ice = lh["iceberg"]
        if ice["habilitado"]:
            destino = f"{ice['catalogo']}.{ice['namespace']}.{self.tabla_destino}"
            self.spark.sql(f"CREATE NAMESPACE IF NOT EXISTS {ice['catalogo']}.{ice['namespace']}")
            df.writeTo(destino).using("iceberg").createOrReplace()
            resultado["iceberg"] = destino
        df.unpersist()
        return resultado

    # -------------------------------------------------------------------- orquestación
    def ejecutar(self) -> dict:
        return self.cargar(self.transformar(self.extraer()))
