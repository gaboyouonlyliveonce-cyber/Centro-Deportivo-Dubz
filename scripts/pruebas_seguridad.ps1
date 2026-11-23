<#
 Pruebas de seguridad EN VIVO contra el contenedor postgres, con sesiones reales de
 reporting_user1 (readonly) y app_user1 (readwrite). Cada intento prohibido debe fallar.
 Uso:  powershell -File scripts\pruebas_seguridad.ps1
#>
$db = 'centro_deportivo'
function Probar($usuario, $descripcion, $sql) {
    Write-Host "`n>>> [$usuario] $descripcion" -ForegroundColor Cyan
    Write-Host "    SQL: $sql"
    docker exec postgres psql -U $usuario -d $db -v ON_ERROR_STOP=0 -c $sql 2>&1 | ForEach-Object { "    $_" }
}

Write-Host '===== reporting_user1 (rol readonly) ====='
Probar 'reporting_user1' 'SELECT permitido'                   'SELECT count(*) AS consumos FROM consumos_pendientes;'
Probar 'reporting_user1' 'INSERT debe FALLAR'                 "INSERT INTO productos_recepcion (nombre, categoria, precio_unitario) VALUES ('X', 'AGUA', 1);"
Probar 'reporting_user1' 'CREATE TABLE debe FALLAR'           'CREATE TABLE prueba_reporting (id INT);'
Probar 'reporting_user1' 'UPDATE debe FALLAR'                 "UPDATE consumos_pendientes SET estado_pago = 'CONDONADO' WHERE id_consumo = 1;"
Probar 'reporting_user1' 'DELETE debe FALLAR'                 'DELETE FROM consumos_pendientes WHERE id_consumo = 1;'
Probar 'reporting_user1' 'leer password_hash debe FALLAR'     'SELECT password_hash FROM usuarios;'
Probar 'reporting_user1' 'leer teléfono real debe FALLAR'     'SELECT telefono FROM clientes LIMIT 3;'
Probar 'reporting_user1' 'vista enmascarada permitida'        'SELECT id_cliente, nombre, telefono_enmascarado FROM vw_clientes_enmascarado ORDER BY id_cliente LIMIT 3;'
Probar 'reporting_user1' 'leer auditoría debe FALLAR'         'SELECT * FROM auditoria_consumos;'

Write-Host "`n===== app_user1 (rol readwrite) ====="
Probar 'app_user1' 'CREATE TABLE permitido (y se elimina)'    'CREATE TABLE prueba_app (id INT); DROP TABLE prueba_app;'
Probar 'app_user1' 'leer auditoría debe FALLAR'               'SELECT * FROM auditoria_consumos;'
# Condonación REAL hecha con la sesión de app_user1 y revertida después (ambos cambios quedan en la bitácora)
$id = (docker exec postgres psql -U postgres -d $db -t -A -c "SELECT min(id_consumo) FROM consumos_pendientes WHERE estado_pago='PENDIENTE';").Trim()
Probar 'app_user1' "condonar la deuda del consumo $id (UPDATE permitido)" "UPDATE consumos_pendientes SET estado_pago = 'CONDONADO' WHERE id_consumo = $id;"
Probar 'app_user1' "restaurar el consumo $id a PENDIENTE (también se audita)" "UPDATE consumos_pendientes SET estado_pago = 'PENDIENTE' WHERE id_consumo = $id;"
Probar 'app_user1' 'intentar borrar la bitácora debe FALLAR' 'DELETE FROM auditoria_consumos;'

Write-Host "`n===== Bitácora de auditoría (leída por el usuario maestro) =====" -ForegroundColor Cyan
docker exec postgres psql -U postgres -d $db -c "SELECT id_auditoria, id_consumo, estado_anterior, estado_nuevo, es_condonacion, usuario_sesion, fecha_evento FROM auditoria_consumos ORDER BY id_auditoria DESC LIMIT 5;" 2>&1
Probar 'postgres' 'incluso el superusuario NO puede alterar la bitácora (trigger de inmutabilidad)' "UPDATE auditoria_consumos SET es_condonacion = FALSE;"