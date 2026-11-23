"""ETL 2 -> fact_retencion_membresias

Fuentes: membresias_clientes + tipos_membresia + clientes.
Grano: plan x mes de inicio (cohorte de membresías vendidas ese mes).
Una membresía cumplida (fecha_fin < fecha de corte) se considera RENOVADA si el mismo cliente
inicia otra dentro de `dias_gracia_renovacion` días después de su fecha_fin. Los estados
vigente/vencida se calculan con fechas (la columna `estado` del OLTP no se actualiza sola).
"""
from typing import Dict

from pyspark.sql import Column, DataFrame, Window, functions as F

import funciones as fx
from BaseETL import BaseETL


# ----------------------------------------------------------------- funciones puras
def unir_catalogos(membresias: DataFrame, tipos: DataFrame, clientes: DataFrame) -> DataFrame:
    return (
        membresias.filter(F.col("estado") != "CANCELADA")
        .join(tipos.select("id_tipo_membresia", "nombre_plan", "duracion_dias", "precio"), "id_tipo_membresia")
        .join(clientes.select("id_cliente", "activo"), "id_cliente")
    )


def marcar_ciclos(corte: Column, gracia_dias: int):
    def transformacion(df: DataFrame) -> DataFrame:
        por_cliente = Window.partitionBy("id_cliente").orderBy("fecha_inicio")
        return (
            df.withColumn("siguiente_inicio", F.lead("fecha_inicio").over(por_cliente))
            .withColumn("ciclo_cumplido", F.col("fecha_fin") < corte)
            .withColumn(
                "renovada",
                F.coalesce(
                    F.col("ciclo_cumplido")
                    & (F.datediff("siguiente_inicio", "fecha_fin") <= F.lit(gracia_dias)),
                    F.lit(False),
                ),
            )
            .withColumn("mes", fx.mes_de("fecha_inicio"))
        )

    return transformacion


def agregar_por_plan_y_mes(df: DataFrame) -> DataFrame:
    cumplida, renovada, recordada = F.col("ciclo_cumplido"), F.col("renovada"), F.col("recordatorio_enviado")
    return df.groupBy("mes", "id_tipo_membresia", "nombre_plan").agg(
        F.count(F.lit(1)).alias("membresias_vendidas"),
        F.sum("precio").alias("ingresos"),
        F.countDistinct("id_cliente").alias("clientes_distintos"),
        fx.cuenta_si(~cumplida).alias("membresias_activas"),
        fx.cuenta_si(cumplida).alias("membresias_vencidas"),
        fx.cuenta_si(renovada).alias("membresias_renovadas"),
        fx.cuenta_si(cumplida & recordada).alias("vencidas_con_recordatorio"),
        fx.cuenta_si(renovada & recordada).alias("renovadas_con_recordatorio"),
        fx.cuenta_si(cumplida & ~recordada).alias("vencidas_sin_recordatorio"),
        fx.cuenta_si(renovada & ~recordada).alias("renovadas_sin_recordatorio"),
    )


def con_tasas(df: DataFrame) -> DataFrame:
    c = F.col
    return (
        df.withColumn("tasa_renovacion", fx.razon(c("membresias_renovadas"), c("membresias_vencidas")))
        .withColumn("proporcion_activas", fx.razon(c("membresias_activas"), c("membresias_vendidas")))
        .withColumn("tasa_renovacion_con_recordatorio", fx.razon(c("renovadas_con_recordatorio"), c("vencidas_con_recordatorio")))
        .withColumn("tasa_renovacion_sin_recordatorio", fx.razon(c("renovadas_sin_recordatorio"), c("vencidas_sin_recordatorio")))
        .withColumn(
            "efectividad_recordatorio",
            F.round(c("tasa_renovacion_con_recordatorio") - c("tasa_renovacion_sin_recordatorio"), 4),
        )
    )


# --------------------------------------------------------------------------- clase
class RetencionMembresiasETL(BaseETL):
    def extraer(self) -> Dict[str, DataFrame]:
        return {
            "membresias": self.leer("membresias").select(
                "id_cliente", "id_tipo_membresia", "fecha_inicio", "fecha_fin", "estado", "recordatorio_enviado"
            ),
            "tipos": self.leer("tipos").select("id_tipo_membresia", "nombre_plan", "duracion_dias", "precio"),
            "clientes": self.leer("clientes").select("id_cliente", "activo"),
        }

    def transformar(self, datos: Dict[str, DataFrame]) -> DataFrame:
        neg = self.params["negocio"]
        corte = fx.fecha_referencia(neg["fecha_referencia"])
        return (
            unir_catalogos(datos["membresias"], datos["tipos"], datos["clientes"])
            .transform(marcar_ciclos(corte, int(neg["dias_gracia_renovacion"])))
            .transform(agregar_por_plan_y_mes)
            .transform(con_tasas)
            .orderBy("mes", "nombre_plan")
        )
