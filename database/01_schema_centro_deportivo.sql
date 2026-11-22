-- ============================================================================
-- PROYECTO: CENTRO DEPORTIVO GABO-DUBZ
-- MATERIAS: Bases de Datos (3FN, Integridad, Vistas, Triggers) y
--           Administración de Bases de Datos (Roles, Grants, Índices)
-- ============================================================================

-- 1. ADMINISTRACIÓN DE ROLES Y PRIVILEGIOS (DCL)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'rol_admin_centro') THEN
        CREATE ROLE rol_admin_centro NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'rol_head_coach') THEN
        CREATE ROLE rol_head_coach NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'rol_coach') THEN
        CREATE ROLE rol_coach NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'rol_cliente_atleta') THEN
        CREATE ROLE rol_cliente_atleta NOLOGIN;
    END IF;
END
$$;

-- 2. TABLAS DEL NÚCLEO OPERATIVO (OLTP EN 3FN)

-- 2.1 Usuarios del sistema y control de perfil
CREATE TABLE IF NOT EXISTS usuarios (
    id_usuario SERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(120) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    rol VARCHAR(20) NOT NULL CHECK (rol IN ('ADMIN', 'HEAD_COACH', 'COACH', 'CLIENTE')),
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    creado_en TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 2.2 Clientes del centro deportivo
CREATE TABLE IF NOT EXISTS clientes (
    id_cliente SERIAL PRIMARY KEY,
    id_usuario INT UNIQUE REFERENCES usuarios(id_usuario) ON DELETE SET NULL,
    nombre VARCHAR(80) NOT NULL,
    apellido VARCHAR(80) NOT NULL,
    telefono VARCHAR(20),
    altura_cm NUMERIC(5,2) NOT NULL CHECK (altura_cm BETWEEN 100.00 AND 250.00),
    peso_inicial_kg NUMERIC(5,2) NOT NULL CHECK (peso_inicial_kg BETWEEN 30.00 AND 250.00),
    fecha_registro DATE NOT NULL DEFAULT CURRENT_DATE,
    activo BOOLEAN NOT NULL DEFAULT TRUE
);

-- 2.3 Bitácora evolutiva de peso y repeticiones máximas (Sit ups, Push ups, Pull ups)
CREATE TABLE IF NOT EXISTS historial_marcas_clientes (
    id_registro SERIAL PRIMARY KEY,
    id_cliente INT NOT NULL REFERENCES clientes(id_cliente) ON DELETE CASCADE,
    fecha_medicion DATE NOT NULL DEFAULT CURRENT_DATE,
    peso_kg NUMERIC(5,2) NOT NULL CHECK (peso_kg BETWEEN 30.00 AND 250.00),
    max_reps_situps INT NOT NULL DEFAULT 0 CHECK (max_reps_situps >= 0),
    max_reps_pushups INT NOT NULL DEFAULT 0 CHECK (max_reps_pushups >= 0),
    max_reps_pullups INT NOT NULL DEFAULT 0 CHECK (max_reps_pullups >= 0),
    observaciones VARCHAR(255),
    CONSTRAINT uq_cliente_fecha_medicion UNIQUE (id_cliente, fecha_medicion)
);

-- 2.4 Catálogo de planes de membresía
CREATE TABLE IF NOT EXISTS tipos_membresia (
    id_tipo_membresia SERIAL PRIMARY KEY,
    nombre_plan VARCHAR(60) NOT NULL UNIQUE,
    duracion_dias INT NOT NULL CHECK (duracion_dias > 0),
    precio NUMERIC(10,2) NOT NULL CHECK (precio >= 0),
    descripcion VARCHAR(255)
);

-- 2.5 Historial y vigencia de membresías por cliente
CREATE TABLE IF NOT EXISTS membresias_clientes (
    id_membresia SERIAL PRIMARY KEY,
    id_cliente INT NOT NULL REFERENCES clientes(id_cliente) ON DELETE CASCADE,
    id_tipo_membresia INT NOT NULL REFERENCES tipos_membresia(id_tipo_membresia) ON DELETE RESTRICT,
    fecha_inicio DATE NOT NULL,
    fecha_fin DATE NOT NULL,
    estado VARCHAR(20) NOT NULL DEFAULT 'ACTIVA'
        CHECK (estado IN ('ACTIVA', 'POR_VENCER', 'VENCIDA', 'CANCELADA')),
    recordatorio_enviado BOOLEAN NOT NULL DEFAULT FALSE,
    fecha_ultimo_recordatorio TIMESTAMP,
    CONSTRAINT chk_fechas_membresia CHECK (fecha_fin >= fecha_inicio)
);

-- 2.6 Productos disponibles en recepción (Agua, Electrolitos, Snacks)
CREATE TABLE IF NOT EXISTS productos_recepcion (
    id_producto SERIAL PRIMARY KEY,
    nombre VARCHAR(80) NOT NULL UNIQUE,
    categoria VARCHAR(30) NOT NULL CHECK (categoria IN ('AGUA', 'ELECTROLITOS', 'SNACKS')),
    precio_unitario NUMERIC(8,2) NOT NULL CHECK (precio_unitario >= 0),
    stock_actual INT NOT NULL DEFAULT 0 CHECK (stock_actual >= 0),
    stock_minimo INT NOT NULL DEFAULT 5 CHECK (stock_minimo >= 0),
    activo BOOLEAN NOT NULL DEFAULT TRUE
);

-- 2.7 Registro de consumos pendientes por pagar en recepción
CREATE TABLE IF NOT EXISTS consumos_pendientes (
    id_consumo SERIAL PRIMARY KEY,
    id_cliente INT NOT NULL REFERENCES clientes(id_cliente) ON DELETE RESTRICT,
    id_producto INT NOT NULL REFERENCES productos_recepcion(id_producto) ON DELETE RESTRICT,
    cantidad INT NOT NULL CHECK (cantidad > 0),
    precio_unitario_congelado NUMERIC(8,2) NOT NULL CHECK (precio_unitario_congelado >= 0),
    subtotal NUMERIC(10,2) GENERATED ALWAYS AS (cantidad * precio_unitario_congelado) STORED,
    estado_pago VARCHAR(15) NOT NULL DEFAULT 'PENDIENTE'
        CHECK (estado_pago IN ('PENDIENTE', 'PAGADO', 'CONDONADO')),
    fecha_consumo TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_pago TIMESTAMP
);

-- 2.8 Entrenamientos programados por el Head Coach (Sesiones de 60 minutos)
CREATE TABLE IF NOT EXISTS entrenamientos (
    id_entrenamiento SERIAL PRIMARY KEY,
    id_coach INT NOT NULL REFERENCES usuarios(id_usuario) ON DELETE RESTRICT,
    fecha_sesion DATE NOT NULL UNIQUE,
    titulo VARCHAR(100) NOT NULL,
    duracion_objetivo_min INT NOT NULL DEFAULT 60 CHECK (duracion_objetivo_min = 60),
    notas_coach TEXT,
    creado_en TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 2.9 Los 4 bloques obligatorios de cada entrenamiento (Calentamiento, Fuerza, Aire, WOD)
CREATE TABLE IF NOT EXISTS bloques_entrenamiento (
    id_bloque SERIAL PRIMARY KEY,
    id_entrenamiento INT NOT NULL REFERENCES entrenamientos(id_entrenamiento) ON DELETE CASCADE,
    tipo_bloque VARCHAR(20) NOT NULL
        CHECK (tipo_bloque IN ('CALENTAMIENTO', 'FUERZA', 'AIRE', 'WOD')),
    orden_ejecucion SMALLINT NOT NULL CHECK (orden_ejecucion BETWEEN 1 AND 4),
    duracion_min INT NOT NULL CHECK (duracion_min > 0 AND duracion_min < 60),
    descripcion_ejercicios TEXT NOT NULL,
    equipamiento_requerido VARCHAR(150),
    CONSTRAINT uq_entrenamiento_tipo_bloque UNIQUE (id_entrenamiento, tipo_bloque),
    CONSTRAINT uq_entrenamiento_orden UNIQUE (id_entrenamiento, orden_ejecucion)
);

-- 3. ÍNDICES DE AFINACIÓN (ADMINISTRACIÓN DE BASES DE DATOS)
CREATE INDEX IF NOT EXISTS idx_membresias_estado_fin ON membresias_clientes(estado, fecha_fin);
CREATE INDEX IF NOT EXISTS idx_consumos_cliente_estado ON consumos_pendientes(id_cliente, estado_pago);
CREATE INDEX IF NOT EXISTS idx_historial_marcas_cliente_fecha ON historial_marcas_clientes(id_cliente, fecha_medicion DESC);
CREATE INDEX IF NOT EXISTS idx_entrenamientos_fecha ON entrenamientos(fecha_sesion DESC);

-- 4. FUNCIONES Y DISPARADORES (TRIGGERS) DE INTEGRIDAD

-- 4.1 Congelar precio unitario y descontar inventario al anotar un producto pendiente
CREATE OR REPLACE FUNCTION fn_registrar_consumo_recepcion()
RETURNS TRIGGER AS $$
DECLARE
    v_precio NUMERIC(8,2);
    v_stock INT;
BEGIN
    SELECT precio_unitario, stock_actual
    INTO v_precio, v_stock
    FROM productos_recepcion
    WHERE id_producto = NEW.id_producto
    FOR UPDATE;

    IF v_stock < NEW.cantidad THEN
        RAISE EXCEPTION 'Stock insuficiente en recepción para el producto ID %. Disponible: %, Solicitado: %',
            NEW.id_producto, v_stock, NEW.cantidad;
    END IF;

    IF NEW.precio_unitario_congelado IS NULL OR NEW.precio_unitario_congelado = 0 THEN
        NEW.precio_unitario_congelado := v_precio;
    END IF;

    UPDATE productos_recepcion
    SET stock_actual = stock_actual - NEW.cantidad
    WHERE id_producto = NEW.id_producto;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_antes_insertar_consumo ON consumos_pendientes;
CREATE TRIGGER trg_antes_insertar_consumo
BEFORE INSERT ON consumos_pendientes
FOR EACH ROW
EXECUTE FUNCTION fn_registrar_consumo_recepcion();

-- 4.2 Validar que los 4 bloques de un entrenamiento no excedan los 60 minutos
CREATE OR REPLACE FUNCTION fn_validar_tiempo_bloques()
RETURNS TRIGGER AS $$
DECLARE
    v_suma_minutos INT;
BEGIN
    SELECT COALESCE(SUM(duracion_min), 0)
    INTO v_suma_minutos
    FROM bloques_entrenamiento
    WHERE id_entrenamiento = NEW.id_entrenamiento;

    IF v_suma_minutos > 60 THEN
        RAISE EXCEPTION 'La suma de los bloques (% min) excede la duración de 1 hora (60 min) del entrenamiento ID %',
            v_suma_minutos, NEW.id_entrenamiento;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validar_duracion_entrenamiento ON bloques_entrenamiento;
CREATE TRIGGER trg_validar_duracion_entrenamiento
AFTER INSERT OR UPDATE ON bloques_entrenamiento
FOR EACH ROW
EXECUTE FUNCTION fn_validar_tiempo_bloques();

-- 5. VISTAS OPERATIVAS Y ANALÍTICAS

-- 5.1 Vista de estado de cuenta de productos pendientes en recepción por cliente
CREATE OR REPLACE VIEW vw_estado_cuenta_recepcion AS
SELECT
    c.id_cliente,
    c.nombre || ' ' || c.apellido AS nombre_completo,
    c.telefono,
    COUNT(cp.id_consumo) AS articulos_pendientes,
    COALESCE(SUM(cp.subtotal), 0.00) AS total_adeudo_mxn
FROM clientes c
LEFT JOIN consumos_pendientes cp
    ON c.id_cliente = cp.id_cliente AND cp.estado_pago = 'PENDIENTE'
GROUP BY c.id_cliente, c.nombre, c.apellido, c.telefono;

-- 5.2 Vista de recordatorios amigables para clientes con membresía vencida o por vencer
CREATE OR REPLACE VIEW vw_recordatorios_membresia AS
SELECT
    c.id_cliente,
    c.nombre,
    c.apellido,
    c.telefono,
    tm.nombre_plan,
    m.fecha_fin,
    (CURRENT_DATE - m.fecha_fin) AS dias_vencida,
    m.recordatorio_enviado,
    ec.total_adeudo_mxn,
    CASE
        WHEN m.fecha_fin < CURRENT_DATE THEN
            'Hola ' || c.nombre || ', te extrañamos en el box. Tu membresía ' || tm.nombre_plan ||
            ' venció el ' || m.fecha_fin || '. ¡Te esperamos de vuelta cuando gustes!'
        ELSE
            'Hola ' || c.nombre || ', te recordamos amigablemente que tu membresía ' || tm.nombre_plan ||
            ' vence el ' || m.fecha_fin || '. ¡Sigue entrenando con todo!'
    END AS mensaje_recordatorio
FROM clientes c
-- Solo la membresía más reciente (no cancelada) de cada cliente: si ya renovó, no se le recuerda
JOIN LATERAL (
    SELECT mc.*
    FROM membresias_clientes mc
    WHERE mc.id_cliente = c.id_cliente
      AND mc.estado <> 'CANCELADA'
    ORDER BY mc.fecha_fin DESC
    LIMIT 1
) m ON TRUE
JOIN tipos_membresia tm ON m.id_tipo_membresia = tm.id_tipo_membresia
LEFT JOIN vw_estado_cuenta_recepcion ec ON c.id_cliente = ec.id_cliente
WHERE c.activo = TRUE
  AND m.fecha_fin <= (CURRENT_DATE + INTERVAL '3 days');

-- 5.3 Vista con las últimas marcas personales vigentes de cada cliente
CREATE OR REPLACE VIEW vw_marcas_actuales_clientes AS
SELECT DISTINCT ON (c.id_cliente)
    c.id_cliente,
    c.nombre,
    c.apellido,
    c.altura_cm,
    COALESCE(h.peso_kg, c.peso_inicial_kg) AS peso_actual_kg,
    COALESCE(h.max_reps_situps, 0) AS max_situps,
    COALESCE(h.max_reps_pushups, 0) AS max_pushups,
    COALESCE(h.max_reps_pullups, 0) AS max_pullups,
    h.fecha_medicion AS ultima_actualizacion
FROM clientes c
LEFT JOIN historial_marcas_clientes h ON c.id_cliente = h.id_cliente
ORDER BY c.id_cliente, h.fecha_medicion DESC NULLS LAST;

-- 5.4 Vista de entrenamiento completo (1 hora dividida en 4 bloques)
CREATE OR REPLACE VIEW vw_entrenamiento_completo AS
SELECT
    e.id_entrenamiento,
    e.fecha_sesion,
    e.titulo,
    u.username AS head_coach,
    b.orden_ejecucion,
    b.tipo_bloque,
    b.duracion_min,
    b.descripcion_ejercicios,
    b.equipamiento_requerido,
    SUM(b.duracion_min) OVER (PARTITION BY e.id_entrenamiento) AS duracion_acumulada_min
FROM entrenamientos e
JOIN usuarios u ON e.id_coach = u.id_usuario
JOIN bloques_entrenamiento b ON e.id_entrenamiento = b.id_entrenamiento
ORDER BY e.fecha_sesion DESC, b.orden_ejecucion ASC;

-- 6. ASIGNACIÓN DE PERMISOS POR ROL (DBA)
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO rol_admin_centro;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO rol_admin_centro;


GRANT SELECT ON clientes, historial_marcas_clientes, vw_marcas_actuales_clientes TO rol_coach;
GRANT SELECT ON entrenamientos, bloques_entrenamiento, vw_entrenamiento_completo TO rol_coach;
GRANT SELECT ON clientes, historial_marcas_clientes, vw_marcas_actuales_clientes TO rol_head_coach;
GRANT SELECT, INSERT, UPDATE, DELETE ON entrenamientos, bloques_entrenamiento TO rol_head_coach;
GRANT SELECT ON vw_entrenamiento_completo TO rol_head_coach;
GRANT USAGE, SELECT ON SEQUENCE entrenamientos_id_entrenamiento_seq, bloques_entrenamiento_id_bloque_seq TO rol_head_coach;

-- Los usuarios cliente tienen acceso ÚNICAMENTE al entrenamiento
GRANT SELECT ON entrenamientos, bloques_entrenamiento, vw_entrenamiento_completo TO rol_cliente_atleta;