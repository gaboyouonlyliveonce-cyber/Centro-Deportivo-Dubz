-- ============================================================================
-- 05_optimizacion_miscelanea.sql - Miscelánea III, Sección 2.2 (Optimización)
-- Ejecutar con el usuario maestro en: centro_deportivo (definida en .env como POSTGRES_DB)
-- Nota: este script reemplaza como definitivo a 03_datos_masivos.sql para la Sección 2.2.
-- ============================================================================

-- 0. ASEGURAR VOLUMEN REALISTA PARA EVIDENCIAR SEQ SCAN VS. INDEX SCAN
--    (Solo inserta si la tabla tiene menos de 50,000 registros)
DO $$
DECLARE
    v_total      BIGINT;
    v_n_clientes INT;
    v_n_prods    INT;
BEGIN
    SELECT COUNT(*) INTO v_total      FROM consumos_pendientes;
    SELECT COUNT(*) INTO v_n_clientes FROM clientes;
    SELECT COUNT(*) INTO v_n_prods    FROM productos_recepcion;

    IF v_n_clientes = 0 OR v_n_prods = 0 THEN
        RAISE EXCEPTION 'Se requieren filas previas en clientes (%) y productos_recepcion (%) antes de la carga masiva.',
            v_n_clientes, v_n_prods;
    END IF;

    IF v_total < 50000 THEN
        RAISE NOTICE 'consumos_pendientes tiene % filas. Generando 100,000 filas de prueba...', v_total;

        PERFORM setseed(0.42);

        -- Desactivar temporalmente el trigger de stock para la carga masiva sintética
        ALTER TABLE consumos_pendientes DISABLE TRIGGER trg_antes_insertar_consumo;

        -- Nota matemática: se usan cocientes enteros desacoplados (g % n_prods, (g / n_prods) % n_clientes,
        -- (g / (n_prods * n_clientes)) % 20) para evitar la correlación modular gcd(10, 5) = 5 que dejaba
        -- a 'Electrolitos Sabor Mora 625ml' sin filas sintéticas con estado_pago = 'PENDIENTE'.
        INSERT INTO consumos_pendientes
            (id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago)
        SELECT
            c.id_cliente,
            p.id_producto,
            (1 + (g % 3))::INT AS cantidad,
            p.precio_unitario,
            CASE
                WHEN ((g / (v_n_prods * v_n_clientes)) % 10) = 0 THEN 'PENDIENTE'
                WHEN ((g / (v_n_prods * v_n_clientes)) % 20) = 1 THEN 'CONDONADO'
                ELSE 'PAGADO'
            END AS estado_pago,
            (NOW() - ((random() * 365)::INT || ' days')::INTERVAL
                   - ((random() * 86400)::INT || ' seconds')::INTERVAL) AS fecha_consumo,
            CASE
                WHEN ((g / (v_n_prods * v_n_clientes)) % 10) = 0 THEN NULL
                ELSE NOW() - ((random() * 30)::INT || ' days')::INTERVAL
            END AS fecha_pago
        FROM generate_series(1, 100000) AS g
        CROSS JOIN LATERAL (
            SELECT id_cliente
            FROM clientes
            ORDER BY id_cliente
            OFFSET ((g / v_n_prods) % v_n_clientes) LIMIT 1
        ) c
        CROSS JOIN LATERAL (
            SELECT id_producto, precio_unitario
            FROM productos_recepcion
            ORDER BY id_producto
            OFFSET (g % v_n_prods) LIMIT 1
        ) p;

        ALTER TABLE consumos_pendientes ENABLE TRIGGER trg_antes_insertar_consumo;
    ELSE
        RAISE NOTICE 'consumos_pendientes ya cuenta con % filas. Se reutilizan los datos actuales.', v_total;
    END IF;
END
$$;

-- Actualizar estadísticas del optimizador (CBO) y garantizar escenario limpio sin el nuevo índice
DROP INDEX IF EXISTS idx_consumos_pendientes_prod_fecha;
ANALYZE consumos_pendientes;
ANALYZE clientes;
ANALYZE productos_recepcion;

-- Resumen de distribución de datos cargados
SELECT estado_pago, COUNT(*) AS filas
FROM consumos_pendientes
GROUP BY estado_pago
ORDER BY filas DESC;

-- ============================================================================
-- (a) CONSULTA LENTA: SELECT *, funciones sobre fecha_consumo, subconsultas
--     innecesarias, JOIN y ORDER BY sobre columna sin índice adecuado
-- ============================================================================
\echo '=== PLAN (a): CONSULTA LENTA SIN INDICE ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT *,
       (SELECT p.nombre
        FROM productos_recepcion p
        WHERE p.id_producto = cp.id_producto) AS nombre_producto
FROM consumos_pendientes cp
JOIN clientes c ON c.id_cliente = cp.id_cliente
WHERE UPPER(cp.estado_pago) = 'PENDIENTE'
  AND cp.id_producto = (
      SELECT p2.id_producto
      FROM productos_recepcion p2
      WHERE p2.nombre = 'Electrolitos Sabor Mora 625ml'
  )
  AND EXTRACT(YEAR  FROM cp.fecha_consumo) = EXTRACT(YEAR  FROM CURRENT_DATE)
  AND EXTRACT(MONTH FROM cp.fecha_consumo) = EXTRACT(MONTH FROM CURRENT_DATE)
ORDER BY cp.fecha_consumo DESC;

-- ============================================================================
-- (b) CREACIÓN DEL ÍNDICE COMPUESTO PARCIAL Y ACTUALIZACIÓN DE ESTADÍSTICAS
-- ============================================================================
\echo '=== CREANDO INDICE COMPUESTO PARCIAL ==='
CREATE INDEX idx_consumos_pendientes_prod_fecha
    ON consumos_pendientes (id_producto, fecha_consumo DESC)
    WHERE estado_pago = 'PENDIENTE';

ANALYZE consumos_pendientes;

-- Comparación de tamaño de tabla vs. tamaño del índice parcial
SELECT
    pg_size_pretty(pg_relation_size('consumos_pendientes')) AS tamano_tabla,
    pg_size_pretty(pg_relation_size('idx_consumos_pendientes_prod_fecha')) AS tamano_indice_parcial;

-- ============================================================================
-- (c) y (d) CONSULTA REESCRITA (sin SELECT *, rango SARGable, sin subconsultas)
--           Y NUEVO PLAN DE EJECUCIÓN
-- ============================================================================
\echo '=== PLAN (d): CONSULTA OPTIMIZADA CON INDICE PARCIAL COMPUESTO ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    cp.id_consumo,
    c.nombre || ' ' || c.apellido AS cliente,
    p.nombre AS producto,
    cp.cantidad,
    cp.subtotal,
    cp.fecha_consumo
FROM consumos_pendientes cp
JOIN clientes c ON c.id_cliente = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE cp.estado_pago = 'PENDIENTE'
  AND p.nombre = 'Electrolitos Sabor Mora 625ml'
  AND cp.fecha_consumo >= date_trunc('month', CURRENT_DATE::TIMESTAMP)
  AND cp.fecha_consumo <  date_trunc('month', CURRENT_DATE::TIMESTAMP) + INTERVAL '1 month'
ORDER BY cp.fecha_consumo DESC;

-- ============================================================================
-- (e) COSTO DEL ÍNDICE SOBRE LAS ESCRITURAS (INSERT MASIVO DE 100,004 FILAS)
--     Se comparan 3 escenarios en tablas temporales idénticas a consumos_pendientes:
--       (e.1) Sin índice secundario
--       (e.2) Con el índice PARCIAL compuesto (WHERE estado_pago = 'PENDIENTE', ~10% de filas)
--       (e.3) Con un índice COMPLETO equivalente sin cláusula WHERE (100% de filas)
-- ============================================================================
CREATE TEMP TABLE tmp_warmup (LIKE consumos_pendientes INCLUDING DEFAULTS INCLUDING GENERATED);
INSERT INTO tmp_warmup (id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago)
SELECT id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago FROM consumos_pendientes;
DROP TABLE tmp_warmup;

\echo '=== (e.1) INSERT DE 100,004 FILAS SIN INDICE ==='
CREATE TEMP TABLE tmp_consumos_sin_idx (LIKE consumos_pendientes INCLUDING DEFAULTS INCLUDING GENERATED);

EXPLAIN (ANALYZE, BUFFERS)
INSERT INTO tmp_consumos_sin_idx
    (id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago)
SELECT id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago
FROM consumos_pendientes;

\echo '=== (e.2) INSERT DE 100,004 FILAS CON INDICE PARCIAL COMPUESTO (WHERE estado_pago = PENDIENTE) ==='
CREATE TEMP TABLE tmp_consumos_con_idx_parcial (LIKE consumos_pendientes INCLUDING DEFAULTS INCLUDING GENERATED);
CREATE INDEX tmp_idx_parcial
    ON tmp_consumos_con_idx_parcial (id_producto, fecha_consumo DESC)
    WHERE estado_pago = 'PENDIENTE';

EXPLAIN (ANALYZE, BUFFERS)
INSERT INTO tmp_consumos_con_idx_parcial
    (id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago)
SELECT id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago
FROM consumos_pendientes;

\echo '=== (e.3) INSERT DE 100,004 FILAS CON INDICE COMPLETO (SIN WHERE) ==='
CREATE TEMP TABLE tmp_consumos_con_idx_total (LIKE consumos_pendientes INCLUDING DEFAULTS INCLUDING GENERATED);
CREATE INDEX tmp_idx_total
    ON tmp_consumos_con_idx_total (id_producto, fecha_consumo DESC);

EXPLAIN (ANALYZE, BUFFERS)
INSERT INTO tmp_consumos_con_idx_total
    (id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago)
SELECT id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago
FROM consumos_pendientes;

SELECT
    pg_size_pretty(pg_relation_size('tmp_idx_parcial')) AS tamano_idx_parcial,
    pg_size_pretty(pg_relation_size('tmp_idx_total'))   AS tamano_idx_completo;

DROP TABLE tmp_consumos_sin_idx;
DROP TABLE tmp_consumos_con_idx_parcial;
DROP TABLE tmp_consumos_con_idx_total;