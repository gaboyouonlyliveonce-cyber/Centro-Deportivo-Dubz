-- ============================================================================
-- 04_seguridad_miscelanea.sql  -  Miscelánea III, Sección 1 (Seguridad)
-- Se ejecuta con el usuario maestro (postgres) sobre la base del proyecto.
-- Es idempotente. Orden en initdb.d: después de 01 (esquema), 02 (seed) y 03 (masivos).
--
-- PROBLEMAS DE SEGURIDAD DETECTADOS EN EL DISEÑO REAL (1.1)
--   (1) Privilegios heredados del pseudo-rol PUBLIC: cualquier rol nuevo puede CONECTARSE a
--       la base, crear tablas temporales y usar el esquema public; y las funciones nacen con
--       EXECUTE para PUBLIC. En versiones <= 14 PUBLIC también tenía CREATE en public.
--       Combinado con GRANT SELECT amplios, usuarios, clientes y adeudos quedan expuestos.
--   (2) usuarios.password_hash guarda cadenas débiles/sin sal (seed: 'hash_admin_2026') y
--       no hay nada que obligue a usar un hash fuerte; PII (teléfono, correo) se lee en claro
--       por cualquier rol de consulta.
--   (3) Sin auditoría: cualquiera con UPDATE puede pasar consumos_pendientes.estado_pago a
--       'CONDONADO' (perdonar una deuda) sin dejar rastro de quién, cuándo ni desde dónde.
--
-- Las contraseñas de los usuarios de login NO están en este archivo (ver
-- scripts/asignar_passwords.ps1, que las toma de .env).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. EVIDENCIA "ANTES": qué hereda un rol recién creado, sin ningún GRANT, de PUBLIC
-- ----------------------------------------------------------------------------
DO $do$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rol_prueba_public') THEN
        CREATE ROLE rol_prueba_public LOGIN;
    END IF;
END
$do$;

SELECT 'inicio_del_script' AS momento,
       has_database_privilege('rol_prueba_public', current_database(), 'CONNECT')   AS puede_conectar,
       has_database_privilege('rol_prueba_public', current_database(), 'TEMPORARY') AS puede_crear_temporales,
       has_schema_privilege  ('rol_prueba_public', 'public', 'USAGE')               AS usage_en_public,
       has_schema_privilege  ('rol_prueba_public', 'public', 'CREATE')              AS create_en_public,
       has_function_privilege('rol_prueba_public', 'fn_validar_tiempo_bloques()', 'EXECUTE') AS execute_en_funciones;

-- ----------------------------------------------------------------------------
-- 1. (1.2 - paso 1) REVOKE de los permisos automáticos de PUBLIC
--    Principio de mínimo privilegio: nada se concede "por defecto a todos".
-- ----------------------------------------------------------------------------
DO $do$
BEGIN
    -- Acceso a la base: quita CONNECT y TEMPORARY a PUBLIC (hay que ser autorizado explícitamente)
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
END
$do$;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;            -- nadie crea objetos en public sin permiso
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

-- Objetos futuros: tampoco heredan privilegios de PUBLIC
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES    FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;   -- el EXECUTE a PUBLIC es global

-- ----------------------------------------------------------------------------
-- 2. (Problema 2) Hash fuerte con sal (bcrypt, costo 12) y enmascaramiento / cifrado de PII
-- ----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION fn_hash_password(p_plain TEXT)
RETURNS TEXT LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT crypt(p_plain, gen_salt('bf', 12)) $$;

CREATE OR REPLACE FUNCTION fn_verificar_password(p_username TEXT, p_plain TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
    SELECT COALESCE((SELECT u.password_hash = crypt(p_plain, u.password_hash)
                     FROM usuarios u WHERE u.username = p_username AND u.activo), FALSE)
$$;

-- Los hashes de relleno del seed no son bcrypt: se reemplazan por hashes con sal de un valor
-- aleatorio irrecuperable (cada usuario deberá restablecer su contraseña con fn_hash_password).
UPDATE usuarios
SET password_hash = fn_hash_password(gen_random_uuid()::TEXT)
WHERE password_hash !~ '^\$2[aby]\$[0-9]{2}\$';

-- Desde ahora la base rechaza cualquier hash que no tenga formato bcrypt con sal
DO $do$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_constraint WHERE conname = 'chk_password_hash_bcrypt') THEN
        ALTER TABLE usuarios ADD CONSTRAINT chk_password_hash_bcrypt
            CHECK (password_hash ~ '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$');
    END IF;
END
$do$;

-- Enmascaramiento de PII para consultas de reporting
CREATE OR REPLACE FUNCTION fn_enmascarar_telefono(p_tel TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE
AS $$ SELECT CASE WHEN p_tel IS NULL THEN NULL
                  WHEN length(p_tel) <= 4 THEN repeat('*', length(p_tel))
                  ELSE left(p_tel, 2) || repeat('*', length(p_tel) - 4) || right(p_tel, 2) END $$;

CREATE OR REPLACE FUNCTION fn_enmascarar_email(p_email TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE
AS $$ SELECT CASE WHEN p_email IS NULL THEN NULL
                  ELSE left(p_email, 1) || '***@' || split_part(p_email, '@', 2) END $$;

CREATE OR REPLACE VIEW vw_clientes_enmascarado AS
SELECT id_cliente, nombre, apellido,
       fn_enmascarar_telefono(telefono) AS telefono_enmascarado,
       altura_cm, peso_inicial_kg, fecha_registro, activo
FROM clientes;

CREATE OR REPLACE VIEW vw_usuarios_enmascarado AS
SELECT id_usuario, username,
       fn_enmascarar_email(email) AS email_enmascarado,
       '***HASH_PROTEGIDO***'::TEXT AS password_hash_enmascarado,
       rol, activo, creado_en
FROM usuarios;

-- Cifrado simétrico de PII (pgcrypto/PGP). La clave NO se guarda: la aporta la aplicación
-- en cada llamada (p. ej. desde un gestor de secretos).
CREATE OR REPLACE FUNCTION fn_cifrar_pii(p_texto TEXT, p_clave TEXT)
RETURNS BYTEA LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT pgp_sym_encrypt(p_texto, p_clave) $$;

CREATE OR REPLACE FUNCTION fn_descifrar_pii(p_cifrado BYTEA, p_clave TEXT)
RETURNS TEXT LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT pgp_sym_decrypt(p_cifrado, p_clave) $$;

-- ----------------------------------------------------------------------------
-- 3. (Problema 3) Auditoría de cambios de estado_pago en consumos_pendientes
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria_consumos (
    id_auditoria    BIGSERIAL PRIMARY KEY,
    id_consumo      INT         NOT NULL,
    id_cliente      INT         NOT NULL,
    subtotal        NUMERIC(10,2),
    estado_anterior VARCHAR(15) NOT NULL,
    estado_nuevo    VARCHAR(15) NOT NULL,
    es_condonacion  BOOLEAN     NOT NULL,
    usuario_sesion  TEXT        NOT NULL,   -- rol con el que se inició sesión (session_user)
    aplicacion      TEXT,                   -- application_name del cliente
    ip_cliente      INET,                   -- NULL si fue por socket local
    fecha_evento    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_auditoria_consumos_fecha     ON auditoria_consumos (fecha_evento DESC);
CREATE INDEX IF NOT EXISTS idx_auditoria_consumos_condonado ON auditoria_consumos (fecha_evento DESC)
    WHERE es_condonacion;

CREATE OR REPLACE FUNCTION fn_auditar_estado_pago()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO auditoria_consumos
        (id_consumo, id_cliente, subtotal, estado_anterior, estado_nuevo, es_condonacion,
         usuario_sesion, aplicacion, ip_cliente)
    VALUES
        (NEW.id_consumo, NEW.id_cliente, NEW.subtotal, OLD.estado_pago, NEW.estado_pago,
         NEW.estado_pago = 'CONDONADO', session_user,
         NULLIF(current_setting('application_name', true), ''), inet_client_addr());
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auditar_estado_pago ON consumos_pendientes;
CREATE TRIGGER trg_auditar_estado_pago
AFTER UPDATE OF estado_pago ON consumos_pendientes
FOR EACH ROW
WHEN (OLD.estado_pago IS DISTINCT FROM NEW.estado_pago)
EXECUTE FUNCTION fn_auditar_estado_pago();

-- La bitácora es de solo-inserción: ni UPDATE, DELETE ni TRUNCATE (ni siquiera el superusuario
-- puede alterarla sin antes deshabilitar el trigger, lo cual queda registrado en el log del servidor)
CREATE OR REPLACE FUNCTION fn_auditoria_inmutable()
RETURNS TRIGGER LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'auditoria_consumos es inmutable: % no permitido', TG_OP;
END;
$$;

DROP TRIGGER IF EXISTS trg_auditoria_inmutable_fila ON auditoria_consumos;
CREATE TRIGGER trg_auditoria_inmutable_fila
BEFORE UPDATE OR DELETE ON auditoria_consumos
FOR EACH ROW EXECUTE FUNCTION fn_auditoria_inmutable();

DROP TRIGGER IF EXISTS trg_auditoria_inmutable_truncate ON auditoria_consumos;
CREATE TRIGGER trg_auditoria_inmutable_truncate
BEFORE TRUNCATE ON auditoria_consumos
FOR EACH STATEMENT EXECUTE FUNCTION fn_auditoria_inmutable();

-- ----------------------------------------------------------------------------
-- 4. (1.2 - paso 2) Roles readonly / readwrite con permisos en los 3 niveles
-- ----------------------------------------------------------------------------
DO $do$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'readonly')  THEN CREATE ROLE readonly  NOLOGIN; END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'readwrite') THEN CREATE ROLE readwrite NOLOGIN; END IF;
END
$do$;

-- Nivel 1: BASE DE DATOS (los roles de negocio existentes también necesitan CONNECT tras el REVOKE)
DO $do$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO readonly, readwrite, rol_admin_centro, rol_head_coach, rol_coach, rol_cliente_atleta', current_database());
    EXECUTE format('GRANT TEMPORARY ON DATABASE %I TO readwrite', current_database());
END
$do$;

-- Nivel 2: ESQUEMA
GRANT USAGE ON SCHEMA public TO readonly, readwrite, rol_admin_centro, rol_head_coach, rol_coach, rol_cliente_atleta;
GRANT CREATE ON SCHEMA public TO readwrite;                   -- readwrite puede crear objetos

-- Nivel 3: TABLAS y SECUENCIAS existentes
GRANT SELECT                         ON ALL TABLES    IN SCHEMA public TO readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO readwrite;
GRANT SELECT                         ON ALL SEQUENCES IN SCHEMA public TO readonly;
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA public TO readwrite;
GRANT EXECUTE ON FUNCTION fn_hash_password(TEXT), fn_verificar_password(TEXT, TEXT),
                          fn_enmascarar_telefono(TEXT), fn_enmascarar_email(TEXT) TO readwrite;
GRANT EXECUTE ON FUNCTION fn_enmascarar_telefono(TEXT), fn_enmascarar_email(TEXT) TO readonly;
GRANT EXECUTE ON FUNCTION fn_cifrar_pii(TEXT, TEXT), fn_descifrar_pii(BYTEA, TEXT) TO readwrite;

-- Objetos FUTUROS (tablas y secuencias creadas después por el usuario maestro)
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT                         ON TABLES    TO readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO readwrite;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT                         ON SEQUENCES TO readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE          ON SEQUENCES TO readwrite;

-- El administrador del centro conserva acceso total, también a lo que se cree después
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO rol_admin_centro;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO rol_admin_centro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO rol_admin_centro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO rol_admin_centro;

-- Excepciones por sensibilidad (resuelven los problemas 1 y 2 para el rol de consulta):
-- readonly NO ve password_hash, correo ni teléfono reales: solo columnas no sensibles y vistas enmascaradas
REVOKE SELECT ON usuarios FROM readonly;
GRANT  SELECT (id_usuario, username, rol, activo, creado_en) ON usuarios TO readonly;
REVOKE SELECT ON clientes FROM readonly;
GRANT  SELECT (id_cliente, id_usuario, nombre, apellido, altura_cm, peso_inicial_kg, fecha_registro, activo)
       ON clientes TO readonly;
REVOKE SELECT ON vw_estado_cuenta_recepcion, vw_recordatorios_membresia FROM readonly;  -- exponen teléfono
-- La bitácora de auditoría solo la lee el administrador; nadie la modifica
REVOKE ALL ON auditoria_consumos FROM PUBLIC, readonly, readwrite;
REVOKE ALL ON SEQUENCE auditoria_consumos_id_auditoria_seq FROM PUBLIC, readonly, readwrite;
GRANT  SELECT ON auditoria_consumos TO rol_admin_centro;

-- ----------------------------------------------------------------------------
-- 5. (1.2 - paso 3) Usuarios y asignación de rol
-- ----------------------------------------------------------------------------
DO $do$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'reporting_user1') THEN
        CREATE ROLE reporting_user1 LOGIN CONNECTION LIMIT 5;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user1') THEN
        CREATE ROLE app_user1 LOGIN CONNECTION LIMIT 20;
    END IF;
END
$do$;

GRANT readonly  TO reporting_user1;
GRANT readwrite TO app_user1;
ALTER ROLE reporting_user1 SET statement_timeout = '30s';   -- evita consultas de reporting desbocadas

-- CÓMO REVOCAR un rol a un usuario (y volver a darlo):
--   REVOKE readonly FROM reporting_user1;      -- reporting_user1 pierde todo lo heredado de readonly
--   GRANT  readonly TO   reporting_user1;
-- Para dar de baja al usuario por completo:
--   REASSIGN OWNED BY reporting_user1 TO postgres; DROP OWNED BY reporting_user1; DROP ROLE reporting_user1;

-- ----------------------------------------------------------------------------
-- 6. (1.2 - paso 4) VERIFICACIÓN
-- ----------------------------------------------------------------------------
-- 6.1 Evidencia "DESPUÉS" del REVOKE sobre el mismo rol sin privilegios
SELECT 'despues_del_revoke' AS momento,
       has_database_privilege('rol_prueba_public', current_database(), 'CONNECT')   AS puede_conectar,
       has_database_privilege('rol_prueba_public', current_database(), 'TEMPORARY') AS puede_crear_temporales,
       has_schema_privilege  ('rol_prueba_public', 'public', 'USAGE')               AS usage_en_public,
       has_schema_privilege  ('rol_prueba_public', 'public', 'CREATE')              AS create_en_public,
       has_function_privilege('rol_prueba_public', 'fn_validar_tiempo_bloques()', 'EXECUTE') AS execute_en_funciones;

DROP ROLE IF EXISTS rol_prueba_public;

-- 6.2 Usuarios con sus roles (pg_roles + pg_auth_members)
SELECT u.rolname AS usuario,
       u.rolcanlogin AS puede_login,
       COALESCE(string_agg(r.rolname, ', ' ORDER BY r.rolname), '(sin roles)') AS roles_asignados
FROM pg_roles u
LEFT JOIN pg_auth_members m ON m.member = u.oid
LEFT JOIN pg_roles r        ON r.oid = m.roleid
WHERE u.rolname IN ('reporting_user1', 'app_user1')
GROUP BY u.rolname, u.rolcanlogin
ORDER BY u.rolname;

-- 6.3 Roles de negocio intactos
SELECT rolname AS rol_de_negocio, rolcanlogin AS puede_login
FROM pg_roles WHERE rolname LIKE 'rol\_%' ESCAPE '\' ORDER BY rolname;

-- 6.4 Matriz de privilegios efectivos en los 3 niveles
SELECT r.rol,
       has_database_privilege(r.rol, current_database(), 'CONNECT')               AS db_connect,
       has_schema_privilege  (r.rol, 'public', 'USAGE')                           AS esquema_usage,
       has_schema_privilege  (r.rol, 'public', 'CREATE')                          AS esquema_create,
       has_table_privilege   (r.rol, 'consumos_pendientes', 'SELECT')             AS consumos_select,
       has_table_privilege   (r.rol, 'consumos_pendientes', 'INSERT')             AS consumos_insert,
       has_table_privilege   (r.rol, 'consumos_pendientes', 'UPDATE')             AS consumos_update,
       has_table_privilege   (r.rol, 'consumos_pendientes', 'DELETE')             AS consumos_delete,
       has_column_privilege  (r.rol, 'usuarios', 'password_hash', 'SELECT')       AS lee_password_hash,
       has_column_privilege  (r.rol, 'clientes', 'telefono', 'SELECT')            AS lee_telefono,
       has_table_privilege   (r.rol, 'auditoria_consumos', 'SELECT')              AS lee_auditoria
FROM (VALUES ('readonly'), ('readwrite'), ('reporting_user1'), ('app_user1'),
             ('rol_admin_centro'), ('rol_cliente_atleta')) AS r(rol);

-- 6.5 Pruebas en vivo (dentro de la base). Cada intento prohibido DEBE fallar con
--     "permission denied"; cualquier éxito inesperado aborta el script con una excepción.
DO $do$
DECLARE
    v_n BIGINT;
BEGIN
    SET LOCAL ROLE reporting_user1;

    -- (a) consulta permitida
    SELECT count(*) INTO v_n FROM consumos_pendientes;
    RAISE NOTICE 'OK  reporting_user1 SELECT consumos_pendientes -> % filas', v_n;

    -- (b) INSERT prohibido
    BEGIN
        INSERT INTO productos_recepcion (nombre, categoria, precio_unitario)
        VALUES ('PRUEBA_SEGURIDAD', 'AGUA', 1);
        RAISE EXCEPTION 'FALLO DE SEGURIDAD: reporting_user1 pudo hacer INSERT';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'OK  INSERT bloqueado: %', SQLERRM;
    END;

    -- (c) CREATE TABLE prohibido
    BEGIN
        CREATE TABLE prueba_reporting (id INT);
        RAISE EXCEPTION 'FALLO DE SEGURIDAD: reporting_user1 pudo crear una tabla';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'OK  CREATE TABLE bloqueado: %', SQLERRM;
    END;

    -- (d) UPDATE / DELETE prohibidos
    BEGIN
        UPDATE consumos_pendientes SET estado_pago = 'CONDONADO' WHERE id_consumo = 1;
        RAISE EXCEPTION 'FALLO DE SEGURIDAD: reporting_user1 pudo hacer UPDATE';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'OK  UPDATE bloqueado: %', SQLERRM;
    END;
    BEGIN
        DELETE FROM consumos_pendientes WHERE id_consumo = 1;
        RAISE EXCEPTION 'FALLO DE SEGURIDAD: reporting_user1 pudo hacer DELETE';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'OK  DELETE bloqueado: %', SQLERRM;
    END;

    -- (e) PII y secretos no legibles
    BEGIN
        PERFORM password_hash FROM usuarios LIMIT 1;
        RAISE EXCEPTION 'FALLO DE SEGURIDAD: reporting_user1 pudo leer password_hash';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'OK  password_hash protegido: %', SQLERRM;
    END;
    BEGIN
        PERFORM telefono FROM clientes LIMIT 1;
        RAISE EXCEPTION 'FALLO DE SEGURIDAD: reporting_user1 pudo leer teléfonos reales';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'OK  telefono real protegido: %', SQLERRM;
    END;
    SELECT count(*) INTO v_n FROM vw_clientes_enmascarado;
    RAISE NOTICE 'OK  reporting_user1 ve % clientes con teléfono enmascarado', v_n;

    RESET ROLE;
END
$do$;

-- 6.6 app_user1 (readwrite): puede modificar y crear objetos; la auditoría se dispara.
--     Todo se revierte al final con una excepción controlada (P0001).
DO $do$
DECLARE
    v_id    INT;
    v_audit INT;
BEGIN
    BEGIN
        SET LOCAL ROLE app_user1;

        INSERT INTO productos_recepcion (nombre, categoria, precio_unitario)
        VALUES ('PRUEBA_READWRITE', 'AGUA', 1);
        RAISE NOTICE 'OK  app_user1 INSERT permitido';

        CREATE TABLE prueba_app_user (id INT);
        RAISE NOTICE 'OK  app_user1 CREATE TABLE permitido';
        DROP TABLE prueba_app_user;

        SELECT id_consumo INTO v_id FROM consumos_pendientes
        WHERE estado_pago = 'PENDIENTE' ORDER BY id_consumo LIMIT 1;
        UPDATE consumos_pendientes SET estado_pago = 'CONDONADO' WHERE id_consumo = v_id;
        RESET ROLE;

        SELECT count(*) INTO v_audit FROM auditoria_consumos
        WHERE id_consumo = v_id AND es_condonacion;
        RAISE NOTICE 'OK  auditoría: % registro(s) de condonación para el consumo %', v_audit, v_id;
        IF v_audit <> 1 THEN
            RAISE EXCEPTION 'FALLO: el trigger de auditoría no registró la condonación';
        END IF;

        RAISE EXCEPTION 'rollback de pruebas' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;   -- deshace INSERT, CREATE/DROP, UPDATE y la fila de auditoría de la prueba
    END;
END
$do$;

-- 6.7 Revocar y volver a otorgar un rol (demostración de 1.2 punto 3)
DO $do$
BEGIN
    REVOKE readonly FROM reporting_user1;
    SET LOCAL ROLE reporting_user1;
    BEGIN
        PERFORM 1 FROM consumos_pendientes LIMIT 1;
        RAISE EXCEPTION 'FALLO: reporting_user1 conserva acceso tras REVOKE readonly';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'OK  tras REVOKE readonly: %', SQLERRM;
    END;
    RESET ROLE;
    GRANT readonly TO reporting_user1;
END
$do$;

-- 6.8 Contraseña con sal y PII: pruebas funcionales
DO $do$
DECLARE
    v_h1  TEXT := fn_hash_password('Contrasena-De-Prueba-1');
    v_h2  TEXT := fn_hash_password('Contrasena-De-Prueba-1');
    v_key TEXT := gen_random_uuid()::TEXT;     -- clave efímera solo para esta prueba
    v_cif BYTEA;
BEGIN
    RAISE NOTICE 'OK  mismo texto, hashes distintos (sal): %', v_h1 <> v_h2;
    RAISE NOTICE 'OK  verificación correcta: %, incorrecta: %',
        v_h1 = crypt('Contrasena-De-Prueba-1', v_h1), v_h1 = crypt('otra', v_h1);
    v_cif := fn_cifrar_pii('5512345678', v_key);
    RAISE NOTICE 'OK  cifrado/descifrado de teléfono: % (cifrado=% bytes)',
        fn_descifrar_pii(v_cif, v_key) = '5512345678', length(v_cif);
    RAISE NOTICE 'OK  enmascarado: % | %', fn_enmascarar_telefono('5512345678'), fn_enmascarar_email('ana.m@correo.com');
END
$do$;

-- 6.9 Futuro: una tabla nueva hereda los permisos de los roles (ALTER DEFAULT PRIVILEGES)
DO $do$
BEGIN
    BEGIN
        CREATE TABLE prueba_futura (id INT);
        RAISE NOTICE 'OK  tabla futura -> readonly SELECT: %, readonly INSERT: %, readwrite INSERT: %',
            has_table_privilege('readonly', 'prueba_futura', 'SELECT'),
            has_table_privilege('readonly', 'prueba_futura', 'INSERT'),
            has_table_privilege('readwrite', 'prueba_futura', 'INSERT');
        RAISE EXCEPTION 'rollback de pruebas' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        NULL;
    END;
END
$do$;
