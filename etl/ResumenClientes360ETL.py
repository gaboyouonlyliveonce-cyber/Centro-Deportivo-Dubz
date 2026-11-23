"""ETL 5 -> dim_clientes_360

Fuentes: clientes + membresias_clientes + tipos_membresia + consumos_pendientes + historial_marcas.
Grano: un renglón por cliente, desnormalizado para reportes ejecutivos sin tocar el OLTP:
antigüedad, membresía vigente (estado calculado por fechas), adeudo total en recepción y
últimas marcas personales. El teléfono solo se publica enmascarado (PII).
"""
from typing import Dict

from pyspark.sql import Column, DataFrame, Window, functions as F

import funciones as fx
from BaseETL import BaseETL


# ----------------------------------------------------------------- funciones puras
def ultima_fila_por_cliente(df: DataFrame, orden: Column) -> DataFrame:
    ventana = Window.partitionBy("id_cliente").orderBy(orden)
    return df.withColumn("_rn", F.row_number().over(ventana)).filter(F.col("_rn") == 1).drop("_rn")


def membresia_vigente(membresias: DataFrame, tipos: DataFrame, corte: Column, dias_por_vencer: int) -> DataFrame:
    """Membresía no cancelada con la fecha_fin más reciente + estado calculado con fechas."""
    ultima = ultima_fila_por_cliente(
        membresias.filter(F.col("estado") != "CANCELADA").join(
            tipos.select("id_tipo_membresia", "nombre_plan"), "id_tipo_membresia"
        ),
        F.col("fecha_fin").desc(),
    )
    dias_restantes = F.datediff("fecha_fin", corte)
    return ultima.select(
        "id_cliente",
        F.col("nombre_plan").alias("plan_vigente"),
        F.col("fecha_fin").alias("membresia_fecha_fin"),
        dias_restantes.alias("dias_para_vencer"),
        F.when(dias_restantes < 0, "VENCIDA")
        .when(dias_restantes <= dias_por_vencer, "POR_VENCER")
        .otherwise("ACTIVA")
        .alias("estado_membresia"),
    )


def adeudo_recepcion(consumos: DataFrame) -> DataFrame:
    return (
        consumos.filter(F.col("estado_pago") == "PENDIENTE")
        .groupBy("id_cliente")
        .agg(
            F.sum("subtotal").alias("adeudo_total_recepcion"),
            F.count(F.lit(1)).alias("articulos_pendientes"),
        )
    )


def ultimas_marcas(historial: DataFrame) -> DataFrame:
    return ultima_fila_por_cliente(historial, F.col("fecha_medicion").desc()).select(
        "id_cliente",
        F.col("fecha_medicion").alias("fecha_ultima_marca"),
        F.col("peso_kg").alias("peso_actual_kg"),
        F.col("max_reps_situps").alias("max_situps"),
        F.col("max_reps_pushups").alias("max_pushups"),
        F.col("max_reps_pullups").alias("max_pullups"),
    )


def armar_dimension(corte: Column):
    def transformacion(clientes: DataFrame) -> DataFrame:
        col_tel = (
            F.col("telefono_enmascarado")
            if "telefono_enmascarado" in clientes.columns
            else fx.telefono_enmascarado("telefono").alias("telefono_enmascarado")
        )
        return clientes.select(
            "id_cliente",
            F.concat_ws(" ", "nombre", "apellido").alias("nombre_completo"),
            col_tel,
            "altura_cm",
            "peso_inicial_kg",
            "fecha_registro",
            "activo",
            F.datediff(corte, F.col("fecha_registro")).alias("antiguedad_dias"),
        )

    return transformacion


# --------------------------------------------------------------------------- clase
class ResumenClientes360ETL(BaseETL):
    def extraer(self) -> Dict[str, DataFrame]:
        df_clientes = self.leer("clientes")
        col_tel = "telefono_enmascarado" if "telefono_enmascarado" in df_clientes.columns else "telefono"
        return {
            "clientes": df_clientes.select(
                "id_cliente", "nombre", "apellido", col_tel, "altura_cm", "peso_inicial_kg", "fecha_registro", "activo"
            ),
            "membresias": self.leer("membresias").select("id_cliente", "id_tipo_membresia", "fecha_fin", "estado"),
            "tipos": self.leer("tipos").select("id_tipo_membresia", "nombre_plan"),
            "consumos": self.leer("consumos").select("id_cliente", "subtotal", "estado_pago"),
            "historial": self.leer("historial").select(
                "id_cliente", "fecha_medicion", "peso_kg", "max_reps_situps", "max_reps_pushups", "max_reps_pullups"
            ),
        }

    def transformar(self, datos: Dict[str, DataFrame]) -> DataFrame:
        neg = self.params["negocio"]
        corte = fx.fecha_referencia(neg["fecha_referencia"])
        return (
            datos["clientes"]
            .transform(armar_dimension(corte))
            .join(membresia_vigente(datos["membresias"], datos["tipos"], corte, int(neg["dias_por_vencer"])), "id_cliente", "left")
            .join(adeudo_recepcion(datos["consumos"]), "id_cliente", "left")
            .join(ultimas_marcas(datos["historial"]), "id_cliente", "left")
            .withColumn("estado_membresia", F.coalesce(F.col("estado_membresia"), F.lit("SIN_MEMBRESIA")))
            .withColumn("adeudo_total_recepcion", F.coalesce(F.col("adeudo_total_recepcion"), F.lit(0)).cast("decimal(12,2)"))
            .withColumn("articulos_pendientes", F.coalesce(F.col("articulos_pendientes"), F.lit(0)))
            .withColumn("imc_actual", fx.imc(F.coalesce(F.col("peso_actual_kg"), F.col("peso_inicial_kg")), F.col("altura_cm")))
            .orderBy("id_cliente")
        )
