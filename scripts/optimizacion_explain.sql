-- ============================================================================
-- scripts/optimizacion_explain.sql  -  Miscelánea III, Sección 2 (Optimización)
-- Ejecutar como usuario maestro:
--   Get-Content scripts\optimizacion_explain.sql | docker exec -i postgres psql -U postgres -d centro_deportivo -v ON_ERROR_STOP=1
-- Requiere 03_datos_masivos.sql ya cargado. NO está en ./database para que initdb.d no lo ejecute
-- (el "antes" debe medirse sin el índice). Es repetible: siempre empieza sin índice.
-- Cada consulta se ejecuta 3 veces: la 1ª calienta caché; se reporta la 3ª (caché caliente).
-- ============================================================================
\set ON_ERROR_STOP on
\pset pager off

DROP INDEX IF EXISTS idx_consumos_pend_fecha;
DROP INDEX IF EXISTS idx_consumos_estado_fecha_alt;
ANALYZE consumos_pendientes;

\echo '=== 0. TAMAÑOS Y DISTRIBUCIÓN ==='
SELECT (SELECT count(*) FROM consumos_pendientes) AS filas_consumos,
       pg_size_pretty(pg_table_size('consumos_pendientes'))          AS tabla,
       pg_size_pretty(pg_indexes_size('consumos_pendientes'))        AS indices_existentes;
SELECT estado_pago, count(*) AS filas,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM consumos_pendientes GROUP BY estado_pago ORDER BY filas DESC;
SELECT count(*) AS pendientes_en_2026
FROM consumos_pendientes
WHERE estado_pago = 'PENDIENTE' AND fecha_consumo >= DATE '2026-01-01' AND fecha_consumo < DATE '2027-01-01';

\echo '=== A. CONSULTA LENTA, SIN ÍNDICE (SELECT *, EXTRACT sobre la columna, ORDER BY) ==='
\echo '--- A: corrida 1 (calentamiento)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.*, c.*, p.*, EXTRACT(YEAR FROM cp.fecha_consumo) AS anio
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE EXTRACT(YEAR FROM cp.fecha_consumo) = 2026
  AND cp.estado_pago = 'PENDIENTE'
ORDER BY cp.fecha_consumo DESC;
\echo '--- A: corrida 2'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.*, c.*, p.*, EXTRACT(YEAR FROM cp.fecha_consumo) AS anio
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE EXTRACT(YEAR FROM cp.fecha_consumo) = 2026
  AND cp.estado_pago = 'PENDIENTE'
ORDER BY cp.fecha_consumo DESC;
\echo '--- A: corrida 3 (la que se reporta)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.*, c.*, p.*, EXTRACT(YEAR FROM cp.fecha_consumo) AS anio
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE EXTRACT(YEAR FROM cp.fecha_consumo) = 2026
  AND cp.estado_pago = 'PENDIENTE'
ORDER BY cp.fecha_consumo DESC;

\echo '=== B. CONSULTA REESCRITA, SIN ÍNDICE (aísla el efecto de la reescritura) ==='
\echo '--- B: corrida 1 (calentamiento)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.id_consumo, cp.fecha_consumo, cp.cantidad, cp.subtotal,
       c.nombre, c.apellido, p.nombre AS producto, p.categoria
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE cp.estado_pago = 'PENDIENTE'
  AND cp.fecha_consumo >= DATE '2026-01-01' AND cp.fecha_consumo < DATE '2027-01-01'
ORDER BY cp.fecha_consumo DESC;
\echo '--- B: corrida 2'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.id_consumo, cp.fecha_consumo, cp.cantidad, cp.subtotal,
       c.nombre, c.apellido, p.nombre AS producto, p.categoria
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE cp.estado_pago = 'PENDIENTE'
  AND cp.fecha_consumo >= DATE '2026-01-01' AND cp.fecha_consumo < DATE '2027-01-01'
ORDER BY cp.fecha_consumo DESC;
\echo '--- B: corrida 3 (la que se reporta)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.id_consumo, cp.fecha_consumo, cp.cantidad, cp.subtotal,
       c.nombre, c.apellido, p.nombre AS producto, p.categoria
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE cp.estado_pago = 'PENDIENTE'
  AND cp.fecha_consumo >= DATE '2026-01-01' AND cp.fecha_consumo < DATE '2027-01-01'
ORDER BY cp.fecha_consumo DESC;

\echo '=== C. ÍNDICES CANDIDATOS: parcial (elegido) vs compuesto (alternativa) ==='
CREATE INDEX idx_consumos_pend_fecha
    ON consumos_pendientes (fecha_consumo DESC)
    INCLUDE (id_cliente, id_producto, cantidad, subtotal)
    WHERE estado_pago = 'PENDIENTE';
CREATE INDEX idx_consumos_estado_fecha_alt
    ON consumos_pendientes (estado_pago, fecha_consumo DESC)
    INCLUDE (id_cliente, id_producto, cantidad, subtotal);
ANALYZE consumos_pendientes;
SELECT indexrelname AS indice, pg_size_pretty(pg_relation_size(indexrelid)) AS tamano,
       pg_relation_size(indexrelid) AS bytes
FROM pg_stat_user_indexes
WHERE relname = 'consumos_pendientes' AND indexrelname IN ('idx_consumos_pend_fecha', 'idx_consumos_estado_fecha_alt')
ORDER BY indexrelname;
-- Se conserva solo el parcial: cubre la misma consulta con una fracción del tamaño
DROP INDEX idx_consumos_estado_fecha_alt;

\echo '=== D. CONSULTA LENTA CON ÍNDICE (el índice no ayuda: EXTRACT lo vuelve no SARGable) ==='
\echo '--- D: corrida 1 (calentamiento)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.*, c.*, p.*, EXTRACT(YEAR FROM cp.fecha_consumo) AS anio
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE EXTRACT(YEAR FROM cp.fecha_consumo) = 2026
  AND cp.estado_pago = 'PENDIENTE'
ORDER BY cp.fecha_consumo DESC;
\echo '--- D: corrida 2'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.*, c.*, p.*, EXTRACT(YEAR FROM cp.fecha_consumo) AS anio
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE EXTRACT(YEAR FROM cp.fecha_consumo) = 2026
  AND cp.estado_pago = 'PENDIENTE'
ORDER BY cp.fecha_consumo DESC;
\echo '--- D: corrida 3 (la que se reporta)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.*, c.*, p.*, EXTRACT(YEAR FROM cp.fecha_consumo) AS anio
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE EXTRACT(YEAR FROM cp.fecha_consumo) = 2026
  AND cp.estado_pago = 'PENDIENTE'
ORDER BY cp.fecha_consumo DESC;

\echo '=== E. CONSULTA REESCRITA CON ÍNDICE (solución final) ==='
\echo '--- E: corrida 1 (calentamiento)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.id_consumo, cp.fecha_consumo, cp.cantidad, cp.subtotal,
       c.nombre, c.apellido, p.nombre AS producto, p.categoria
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE cp.estado_pago = 'PENDIENTE'
  AND cp.fecha_consumo >= DATE '2026-01-01' AND cp.fecha_consumo < DATE '2027-01-01'
ORDER BY cp.fecha_consumo DESC;
\echo '--- E: corrida 2'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.id_consumo, cp.fecha_consumo, cp.cantidad, cp.subtotal,
       c.nombre, c.apellido, p.nombre AS producto, p.categoria
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE cp.estado_pago = 'PENDIENTE'
  AND cp.fecha_consumo >= DATE '2026-01-01' AND cp.fecha_consumo < DATE '2027-01-01'
ORDER BY cp.fecha_consumo DESC;
\echo '--- E: corrida 3 (la que se reporta)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT cp.id_consumo, cp.fecha_consumo, cp.cantidad, cp.subtotal,
       c.nombre, c.apellido, p.nombre AS producto, p.categoria
FROM consumos_pendientes cp
JOIN clientes c            ON c.id_cliente  = cp.id_cliente
JOIN productos_recepcion p ON p.id_producto = cp.id_producto
WHERE cp.estado_pago = 'PENDIENTE'
  AND cp.fecha_consumo >= DATE '2026-01-01' AND cp.fecha_consumo < DATE '2027-01-01'
ORDER BY cp.fecha_consumo DESC;

\echo '=== F. COSTO DEL ÍNDICE EN ESCRITURAS: insertar 100,000 filas con y sin el índice parcial ==='
-- Tablas temporales con la misma estructura; se inserta con id explícito (no toca la secuencia real)
CREATE TEMP TABLE bench_sin_indice (LIKE consumos_pendientes INCLUDING DEFAULTS INCLUDING GENERATED);
CREATE TEMP TABLE bench_con_indice (LIKE consumos_pendientes INCLUDING DEFAULTS INCLUDING GENERATED);
CREATE INDEX ON bench_con_indice (fecha_consumo DESC)
    INCLUDE (id_cliente, id_producto, cantidad, subtotal) WHERE estado_pago = 'PENDIENTE';

\echo '--- F: INSERT sin índice (corridas 1-3)'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) INSERT INTO bench_sin_indice (id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago)
SELECT id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago FROM consumos_pendientes;
TRUNCATE bench_sin_indice;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) INSERT INTO bench_sin_indice (id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago)
SELECT id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago FROM consumos_pendientes;
TRUNCATE bench_sin_indice;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) INSERT INTO bench_sin_indice (id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago)
SELECT id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago FROM consumos_pendientes;

\echo '--- F: INSERT con índice parcial (corridas 1-3)'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) INSERT INTO bench_con_indice (id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago)
SELECT id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago FROM consumos_pendientes;
TRUNCATE bench_con_indice;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) INSERT INTO bench_con_indice (id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago)
SELECT id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago FROM consumos_pendientes;
TRUNCATE bench_con_indice;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) INSERT INTO bench_con_indice (id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago)
SELECT id_consumo, id_cliente, id_producto, cantidad, precio_unitario_congelado, estado_pago, fecha_consumo, fecha_pago FROM consumos_pendientes;

SELECT 'sin_indice' AS tabla, pg_size_pretty(pg_table_size('bench_sin_indice'))  AS datos, pg_size_pretty(pg_indexes_size('bench_sin_indice'))  AS indices
UNION ALL
SELECT 'con_indice',          pg_size_pretty(pg_table_size('bench_con_indice')),          pg_size_pretty(pg_indexes_size('bench_con_indice'));

\echo '=== G. Índice final conservado ==='
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'consumos_pendientes' ORDER BY indexname;
