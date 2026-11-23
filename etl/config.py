"""Carga de parameters.json con resolución de variables de entorno (${VAR} y ${VAR:-defecto})."""
import json
import os
import re
from pathlib import Path
from typing import Any, Mapping, Optional

_PATRON = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")
RUTA_POR_DEFECTO = Path(__file__).with_name("parameters.json")


def resolver_variables(valor: Any, entorno: Optional[Mapping[str, str]] = None) -> Any:
    """Función pura: devuelve una copia de `valor` con las referencias ${VAR} sustituidas."""
    entorno = os.environ if entorno is None else entorno

    def reemplazo(m: "re.Match[str]") -> str:
        nombre, defecto = m.group(1), m.group(2)
        if entorno.get(nombre):
            return entorno[nombre]
        if defecto is not None:
            return defecto
        raise KeyError(f"Variable de entorno requerida y no definida: {nombre}")

    if isinstance(valor, str):
        return _PATRON.sub(reemplazo, valor)
    if isinstance(valor, dict):
        return {k: (v if k.startswith("_") else resolver_variables(v, entorno)) for k, v in valor.items()}
    if isinstance(valor, list):
        return [resolver_variables(v, entorno) for v in valor]
    return valor


def cargar_parametros(ruta: Optional[str] = None) -> dict:
    """Lee el JSON (ruta explícita > variable PARAMETERS_PATH > etl/parameters.json)."""
    destino = Path(ruta or os.environ.get("PARAMETERS_PATH") or RUTA_POR_DEFECTO)
    with destino.open(encoding="utf-8") as f:
        return resolver_variables(json.load(f))
