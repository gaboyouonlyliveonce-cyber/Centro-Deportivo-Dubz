"""Funciones PURAS reutilizables por los ETL (sin estado ni efectos secundarios).

Todas reciben/devuelven columnas o DataFrames, de modo que se componen con
`DataFrame.transform(...)` y se pueden probar de forma aislada.
"""
from typing import Callable, Optional

from pyspark.sql import Column, DataFrame, functions as F

Transformacion = Callable[[DataFrame], DataFrame]


def fecha_referencia(valor: Optional[str]) -> Column:
    """Fecha de corte del ETL: la indicada (YYYY-MM-DD) o la fecha actual si es nula."""
    return F.to_date(F.lit(valor)) if valor else F.current_date()


def mes_de(columna: str) -> Column:
    """Primer día del mes de una fecha/timestamp."""
    return F.date_trunc("month", F.col(columna)).cast("date")


def razon(numerador: Column, denominador: Column, decimales: int = 4) -> Column:
    """num/den redondeado; NULL (no error) cuando el denominador es 0 o NULL."""
    num, den = numerador.cast("double"), denominador.cast("double")
    return F.round(num / F.when(den != 0, den), decimales)


def suma_si(condicion: Column, valor: Column) -> Column:
    """SUM(valor) solo de las filas que cumplen la condición (0 si ninguna)."""
    return F.sum(F.when(condicion, valor).otherwise(F.lit(0)))


def cuenta_si(condicion: Column) -> Column:
    return F.sum(F.when(condicion, F.lit(1)).otherwise(F.lit(0)))


def imc(peso_kg: Column, altura_cm: Column) -> Column:
    return F.round(peso_kg.cast("double") / F.pow(altura_cm.cast("double") / 100.0, 2), 2)


def telefono_enmascarado(columna: str) -> Column:
    """Mismo criterio que fn_enmascarar_telefono() de PostgreSQL: 55******78."""
    c = columna
    return F.expr(
        f"CASE WHEN {c} IS NULL THEN NULL "
        f"WHEN length({c}) <= 4 THEN repeat('*', length({c})) "
        f"ELSE concat(substring({c}, 1, 2), repeat('*', length({c}) - 4), "
        f"substring({c}, length({c}) - 1, 2)) END"
    )


def con_columna(nombre: str, expresion: Column) -> Transformacion:
    """Convierte withColumn en una transformación componible."""
    return lambda df: df.withColumn(nombre, expresion)


def seleccionar(*columnas: str) -> Transformacion:
    return lambda df: df.select(*columnas)
