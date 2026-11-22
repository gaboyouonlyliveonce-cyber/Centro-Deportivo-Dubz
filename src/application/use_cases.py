from datetime import date
from typing import Any, Dict, List
from src.domain.entities import (
    BloqueEntrenamiento,
    Cliente,
    Entrenamiento,
    HistorialMarca,
    RolSistema,
)
from src.domain.repositories import (
    ClienteRepository,
    EntrenamientoRepository,
    MembresiaRepository,
    RecepcionRepository,
)


class CentroDeportivoService:
    def __init__(
        self,
        cliente_repo: ClienteRepository,
        membresia_repo: MembresiaRepository,
        recepcion_repo: RecepcionRepository,
        entrenamiento_repo: EntrenamientoRepository,
    ) -> None:
        self.cliente_repo = cliente_repo
        self.membresia_repo = membresia_repo
        self.recepcion_repo = recepcion_repo
        self.entrenamiento_repo = entrenamiento_repo

    def registrar_nuevo_cliente(
        self,
        nombre: str,
        apellido: str,
        altura_cm: float,
        peso_inicial_kg: float,
        id_tipo_membresia: int,
        telefono: str | None = None,
    ) -> Dict[str, Any]:
        nuevo_cliente = Cliente(
            nombre=nombre,
            apellido=apellido,
            altura_cm=altura_cm,
            peso_inicial_kg=peso_inicial_kg,
            telefono=telefono,
        )
        id_cliente = self.cliente_repo.crear_cliente(nuevo_cliente)
        id_membresia = self.membresia_repo.asignar_membresia(
            id_cliente=id_cliente,
            id_tipo_membresia=id_tipo_membresia,
            fecha_inicio=date.today(),
        )
        return {
            "id_cliente": id_cliente,
            "id_membresia": id_membresia,
            "imc_inicial": nuevo_cliente.imc_actual,
        }

    def actualizar_atributos_fisicos(
        self,
        id_cliente: int,
        peso_kg: float,
        max_situps: int,
        max_pushups: int,
        max_pullups: int,
        observaciones: str | None = None,
    ) -> int:
        marca = HistorialMarca(
            fecha_medicion=date.today(),
            peso_kg=peso_kg,
            max_reps_situps=max_situps,
            max_reps_pushups=max_pushups,
            max_reps_pullups=max_pullups,
            observaciones=observaciones,
        )
        return self.cliente_repo.agregar_marca(id_cliente, marca)

    def anotar_producto_recepcion(self, id_cliente: int, id_producto: int, cantidad: int = 1) -> int:
        return self.recepcion_repo.anotar_consumo_pendiente(id_cliente, id_producto, cantidad)

    def obtener_recordatorios_amigables(self) -> List[Dict[str, Any]]:
        return self.membresia_repo.listar_recordatorios_pendientes()

    def subir_entrenamiento_head_coach(
        self,
        rol_usuario: RolSistema,
        id_coach: int,
        fecha_sesion: date,
        titulo: str,
        bloques: List[BloqueEntrenamiento],
        notas_coach: str | None = None,
    ) -> int:
        if rol_usuario != RolSistema.HEAD_COACH:
            raise PermissionError("Únicamente el Head Coach puede publicar o modificar entrenamientos.")
        sesion = Entrenamiento(
            id_coach=id_coach,
            fecha_sesion=fecha_sesion,
            titulo=titulo,
            bloques=bloques,
            notas_coach=notas_coach,
        )
        sesion.validar_sesion_una_hora()
        return self.entrenamiento_repo.guardar_entrenamiento_completo(sesion)