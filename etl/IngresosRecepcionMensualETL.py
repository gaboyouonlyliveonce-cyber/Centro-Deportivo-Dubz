"""ETL 1 -> fact_ingresos_recepcion

Fuentes: consumos_pendientes + productos_recepcion + clientes.
Grano: mes x categoría (AGUA, ELECTROLITOS, SNACKS).
Métricas: ventas cobradas, montos pendientes y condonados, unidades, clientes distintos y
rotación de inventario (unidades cobradas / stock actual de la categoría).
"""
from typing import Dict

from pyspark.sql import DataFrame, functions as F

import funciones as fx
from BaseETL import BaseETL


# ----------------------------------------------------------------- funciones puras
def unir_catalogos(consumos: DataFrame, productos: DataFrame, clientes: DataFrame) -> DataFrame:
    return consumos.join(productos.select("id_producto", "categoria"), "id_producto").join(
        clientes.select("id_cliente", "activo"), "id_cliente"
    )


def agregar_mensual_por_categoria(df: DataFrame) -> DataFrame:
    pagado, pendiente, condonado = (F.col("estado_pago") == e for e in ("PAGADO", "PENDIENTE", "CONDONADO"))
    return df.groupBy("mes", "categoria").agg(
        F.count(F.lit(1)).alias("num_consumos"),
        F.sum("cantidad").alias("unidades_totales"),
        fx.suma_si(pagado, F.col("cantidad")).alias("unidades_cobradas"),
        fx.suma_si(pagado, F.col("subtotal")).alias("ventas_cobradas"),
        fx.suma_si(pendiente, F.col("subtotal")).alias("monto_pendiente"),
        fx.suma_si(condonado, F.col("subtotal")).alias("monto_condonado"),
        F.countDistinct("id_cliente").alias("clientes_distintos"),
        F.countDistinct(F.when(F.col("activo"), F.col("id_cliente"))).alias("clientes_activos_distintos"),
    )


def stock_por_categoria(productos: DataFrame) -> DataFrame:
    return productos.groupBy("categoria").agg(
        F.sum("stock_actual").alias("stock_actual_categoria"),
        F.sum("stock_minimo").alias("stock_minimo_categoria"),
    )


def con_rotacion_y_cobranza(stock: DataFrame):
    """Devuelve una transformación (cierre) que agrega rotación de inventario y % de cobranza."""

    def transformacion(df: DataFrame) -> DataFrame:
        facturado = F.col("ventas_cobradas") + F.col("monto_pendiente") + F.col("monto_condonado")
        return (
            df.join(stock, "categoria", "left")
            .withColumn("rotacion_inventario", fx.razon(F.col("unidades_cobradas"), F.col("stock_actual_categoria")))
            .withColumn("porcentaje_cobranza", fx.razon(F.col("ventas_cobradas"), facturado))
        )

    return transformacion


# --------------------------------------------------------------------------- clase
class IngresosRecepcionMensualETL(BaseETL):
    def extraer(self) -> Dict[str, DataFrame]:
        return {
            "consumos": self.leer("consumos").select(
                "id_cliente", "id_producto", "cantidad", "subtotal", "estado_pago", "fecha_consumo"
            ),
            "productos": self.leer("productos").select("id_producto", "categoria", "stock_actual", "stock_minimo"),
            "clientes": self.leer("clientes").select("id_cliente", "activo"),
        }

    def transformar(self, datos: Dict[str, DataFrame]) -> DataFrame:
        return (
            unir_catalogos(datos["consumos"], datos["productos"], datos["clientes"])
            .transform(fx.con_columna("mes", fx.mes_de("fecha_consumo")))
            .transform(agregar_mensual_por_categoria)
            .transform(con_rotacion_y_cobranza(stock_por_categoria(datos["productos"])))
            .orderBy("mes", "categoria")
        )
