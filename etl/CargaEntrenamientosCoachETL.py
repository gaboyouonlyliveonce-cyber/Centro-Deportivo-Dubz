"""ETL 4 -> fact_entrenamientos_bloques

Fuentes: entrenamientos + bloques_entrenamiento + usuarios (coach).
Grano: coach x mes x tipo de bloque (CALENTAMIENTO, FUERZA, AIRE, WOD).
Mide la distribución REAL del tiempo (minutos y % del tiempo total del coach en el mes) y el
equipamiento utilizado (más frecuente y lista de equipos distintos).
"""
from typing import Dict

from pyspark.sql import DataFrame, Window, functions as F

import funciones as fx
from BaseETL import BaseETL


# ----------------------------------------------------------------- funciones puras
def unir_catalogos(entrenamientos: DataFrame, bloques: DataFrame, usuarios: DataFrame) -> DataFrame:
    return (
        bloques.join(entrenamientos.select("id_entrenamiento", "id_coach", "fecha_sesion"), "id_entrenamiento")
        .join(usuarios.select(F.col("id_usuario").alias("id_coach"), F.col("username").alias("coach")), "id_coach")
        .withColumn("mes", fx.mes_de("fecha_sesion"))
    )


def tiempo_por_bloque(df: DataFrame) -> DataFrame:
    base = df.groupBy("id_coach", "coach", "mes", "tipo_bloque").agg(
        F.countDistinct("id_entrenamiento").alias("sesiones"),
        F.sum("duracion_min").alias("minutos_totales"),
        F.round(F.avg("duracion_min"), 2).alias("minutos_promedio"),
    )
    total_coach_mes = Window.partitionBy("id_coach", "mes")
    return base.withColumn(
        "pct_tiempo_coach_mes", fx.razon(F.col("minutos_totales"), F.sum("minutos_totales").over(total_coach_mes))
    )


def equipamiento_por_bloque(df: DataFrame) -> DataFrame:
    """Un renglón por equipo usado; cuenta usos y resume el más frecuente y la lista distinta."""
    equipos = (
        df.withColumn("equipo", F.explode(F.split(F.coalesce(F.col("equipamiento_requerido"), F.lit("")), r",\s*")))
        .filter(F.col("equipo") != "")
        .groupBy("id_coach", "mes", "tipo_bloque", "equipo")
        .agg(F.count(F.lit(1)).alias("usos"))
    )
    return equipos.groupBy("id_coach", "mes", "tipo_bloque").agg(
        F.max_by("equipo", "usos").alias("equipo_mas_frecuente"),
        F.max("usos").alias("usos_equipo_mas_frecuente"),
        F.concat_ws(", ", F.array_sort(F.collect_set("equipo"))).alias("equipos_distintos"),
    )


# --------------------------------------------------------------------------- clase
class CargaEntrenamientosCoachETL(BaseETL):
    def extraer(self) -> Dict[str, DataFrame]:
        return {
            "entrenamientos": self.leer("entrenamientos").select(
                "id_entrenamiento", "id_coach", "fecha_sesion", "duracion_objetivo_min"
            ),
            "bloques": self.leer("bloques").select(
                "id_entrenamiento", "tipo_bloque", "duracion_min", "equipamiento_requerido"
            ),
            "usuarios": self.leer("usuarios").select("id_usuario", "username"),
        }

    def transformar(self, datos: Dict[str, DataFrame]) -> DataFrame:
        unido = unir_catalogos(datos["entrenamientos"], datos["bloques"], datos["usuarios"])
        return (
            tiempo_por_bloque(unido)
            .join(equipamiento_por_bloque(unido), ["id_coach", "mes", "tipo_bloque"], "left")
            .orderBy("coach", "mes", "tipo_bloque")
        )
