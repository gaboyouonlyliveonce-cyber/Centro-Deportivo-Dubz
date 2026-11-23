<#
 Asigna contraseñas a reporting_user1 y app_user1 tomándolas de .env
 (REPORTING_USER_PASSWORD y APP_USER_PASSWORD). Nunca se escriben en archivos del repo.
 Uso:  powershell -File scripts\asignar_passwords.ps1
#>
$ErrorActionPreference = 'Stop'
$env_ = @{}
Get-Content (Join-Path $PSScriptRoot '..\.env') | Where-Object { $_ -match '^\s*[A-Za-z_][A-Za-z0-9_]*=' } |
    ForEach-Object { $k, $v = $_ -split '=', 2; $env_[$k.Trim()] = $v.Trim() }

foreach ($par in @(@('reporting_user1', 'REPORTING_USER_PASSWORD'), @('app_user1', 'APP_USER_PASSWORD'))) {
    $usuario, $variable = $par
    if (-not $env_[$variable]) { throw "Falta $variable en .env" }
    $clave = $env_[$variable].Replace("'", "''")
    # la contraseña viaja por stdin (no aparece en la lista de procesos)
    "ALTER ROLE $usuario PASSWORD '$clave';" |
        docker exec -i postgres psql -U $env_['POSTGRES_USER'] -d $env_['POSTGRES_DB'] -v ON_ERROR_STOP=1 -q
    Write-Host "Contraseña asignada a $usuario"
}
