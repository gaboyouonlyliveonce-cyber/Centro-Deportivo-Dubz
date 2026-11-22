from dataclasses import dataclass, field
from datetime import date
from enum import Enum
from typing import List, Optional


class RolSistema(str, Enum):
    ADMIN = "ADMIN"
    HEAD_COACH = "HEAD_COACH"
    COACH = "COACH"
    CLIENTE = "CLIENTE"


class EstadoMembresia(str, Enum):
    ACTIVA = "ACTIVA"
    POR_VENCER = "POR_VENCER"
    VENCIDA = "VENCIDA"
    CANCELADA = "CANCELADA"


class CategoriaProducto(str, Enum):
    AGUA = "AGUA"
    ELECTROLITOS = "ELECTROLITOS"
    SNACKS = "SNACKS"


class TipoBloqueEntrenamiento(str, Enum):
    CALENTAMIENTO = "CALENTAMIENTO"
    FUERZA = "FUERZA"
    AIRE = "AIRE"
    WOD = "WOD"


@dataclass
class HistorialMarca:
    fecha_medicion: date
    peso_kg: float
    max_reps_situps: int
    max_reps_pushups: int
    max_reps_pullups: int
    observaciones: Optional[str] = None
    id_registro: Optional[int] = None

    def __post_init__(self) -> None:
        if any(r < 0 for r in (self.max_reps_situps, self.max_reps_pushups, self.max_reps_pullups)):
            raise ValueError("Las repeticiones máximas no pueden ser negativas.")
        if self.peso_kg <= 0:
            raise ValueError("El peso debe ser mayor a 0 kg.")


@dataclass
class Cliente:
    nombre: str
    apellido: str
    altura_cm: float
    peso_inicial_kg: float
    telefono: Optional[str] = None
    id_cliente: Optional[int] = None
    id_usuario: Optional[int] = None
    activo: bool = True
    historial_marcas: List[HistorialMarca] = field(default_factory=list)

    @property
    def nombre_completo(self) -> str:
        return f"{self.nombre} {self.apellido}".strip()

    @property
    def imc_actual(self) -> float:
        if self.historial_marcas:
            peso = max(self.historial_marcas, key=lambda m: m.fecha_medicion).peso_kg
        else:
            peso = self.peso_inicial_kg
        return round(peso / ((self.altura_cm / 100.0) ** 2), 2)


@dataclass
class BloqueEntrenamiento:
    tipo_bloque: TipoBloqueEntrenamiento
    orden_ejecucion: int
    duracion_min: int
    descripcion_ejercicios: str
    equipamiento_requerido: Optional[str] = None
    id_bloque: Optional[int] = None

    def __post_init__(self) -> None:
        if not (1 <= self.duracion_min <= 59):
            raise ValueError("Cada bloque debe durar entre 1 y 59 minutos.")


@dataclass
class Entrenamiento:
    id_coach: int
    fecha_sesion: date
    titulo: str
    bloques: List[BloqueEntrenamiento] = field(default_factory=list)
    notas_coach: Optional[str] = None
    id_entrenamiento: Optional[int] = None

    def validar_sesion_una_hora(self) -> None:
        if len(self.bloques) != 4:
            raise ValueError("La sesión debe tener exactamente 4 bloques: Calentamiento, Fuerza, Aire y WOD.")
        if len({b.tipo_bloque for b in self.bloques}) != 4:
            raise ValueError("No se pueden repetir tipos de bloque en la misma sesión.")
        total_min = sum(b.duracion_min for b in self.bloques)
        if total_min != 60:
            raise ValueError(f"La sesión suma {total_min} min; debe completar exactamente 60 minutos.")