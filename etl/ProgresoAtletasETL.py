"""ETL 3 -> fact_progreso_atletas

Fuentes: historial_marcas_clientes + clientes.
Grano: atleta x mes. Para cada mes toma la última medición y calcula IMC, variación de peso
y de repeticiones máximas (sit ups, push ups, pull ups) contra el mes anterior y contra el
primer mes registrado.
"""
from typing import Dict

from pyspark.sql import DataFrame, Window, functions as F

import funciones as fx
from BaseETL import BaseETL

METRICAS = {  # columna de periodo -> alias de variación
    "peso_fin_mes": "peso",
    "max_situps": "situps",
    "max_pushups": "pushups",
    "max_pullups": "pullups",
}


# ----------------------------------------------------------------- funciones puras
def unir_clientes(historial: DataFrame, clientes: DataFrame) -> DataFrame:
    return historial.join(
        clientes.select("id_cliente", "nombre", "apellido", "altura_cm"), "id_cliente"
    )


def resumir_por_mes(df: DataFrame) -> DataFrame:
    return df.groupBy("id_cliente", "nombre", "apellido", "altura_cm", fx.mes_de("fecha_medicion").alias("mes")).agg(
        F.count(F.lit(1)).alias("mediciones"),
        F.max_by("peso_kg", "fecha_medicion").alias("peso_fin_mes"),
        F.max("max_reps_situps").alias("max_situps"),
        F.max("max_reps_pushups").alias("max_pushups"),
        F.max("max_reps_pullups").alias("max_pullups"),
        F.max("fecha_medicion").alias("ultima_medicion"),
    )


def con_imc(df: DataFrame) -> DataFrame:
    return df.withColumn("imc", fx.imc(F.col("peso_fin_mes"), F.col("altura_cm")))


def con_variaciones(df: DataFrame) -> DataFrame:
    """Variación contra el periodo anterior (var_*) y acumulada contra el primero (acum_*)."""
    ventana = Window.partitionBy("id_cliente").orderBy("mes")
    for columna, alias in METRICAS.items():
        df = df.withColumn(f"var_{alias}", F.round(F.col(columna) - F.lag(columna).over(ventana), 2)).withColumn(
            f"acum_{alias}", F.round(F.col(columna) - F.first(columna).over(ventana), 2)
        )
    return df.withColumn("variacion_imc", F.round(F.col("imc") - F.lag("imc").over(ventana), 2))


# --------------------------------------------------------------------------- clase
class ProgresoAtletasETL(BaseETL):
    def extraer(self) -> Dict[str, DataFrame]:
        return {
            "historial": self.leer("historial").select(
                "id_cliente", "fecha_medicion", "peso_kg", "max_reps_situps", "max_reps_pushups", "max_reps_pullups"
            ),
            "clientes": self.leer("clientes").select("id_cliente", "nombre", "apellido", "altura_cm", "peso_inicial_kg"),
        }

    def transformar(self, datos: Dict[str, DataFrame]) -> DataFrame:
        return (
            unir_clientes(datos["historial"], datos["clientes"])
            .transform(resumir_por_mes)
            .transform(con_imc)
            .transform(con_variaciones)
            .orderBy("id_cliente", "mes")
        )
