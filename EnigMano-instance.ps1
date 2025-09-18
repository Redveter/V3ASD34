param(
    [string]$Username,
    [string]$Password,
    [string]$InstanceLabel
)

$ErrorActionPreference = "Stop"

# Ensure TLS 1.2 is enabled for all web requests (Invoke-WebRequest/Invoke-RestMethod)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

function Timestamp { (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
function Log($msg) { Write-Host "[ENIGMANO $(Timestamp)] $msg" }
function Fail($msg) { Write-Error "[ENIGMANO-ERROR $(Timestamp)] $msg"; Exit 1 }

# === INPUT NORMALIZATION ===
if ([string]::IsNullOrWhiteSpace($InstanceLabel)) { $InstanceLabel = "Nex" }
if ([string]::IsNullOrWhiteSpace($Username))      { $Username      = "Nex" }
if ([string]::IsNullOrWhiteSpace($Password))      { $Password      = "Example#9943" }


# === ASCII BANNER ===
$now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host @"
----------------------------------------------------
       ENIGMANO INSTANCIA $env:INSTANCE_ID - $InstanceLabel
----------------------------------------------------
   ESTADO     : Inicializando secuencia de despliegue
   USUARIO    : $Username
   HORA       : $now
   ARQUITECTO : SHAHZAIB-YT
----------------------------------------------------
"@

# === ENVIRONMENT VARIABLES ===
$SECRET_SHAHZAIB = $env:SECRET_SHAHZAIB
$NGROK_SHAHZAIB  = $env:NGROK_SHAHZAIB
$INSTANCE_ID     = [int]$env:INSTANCE_ID
$NEXT_INSTANCE_ID = $INSTANCE_ID + 1
$WORKFLOW_FILE   = "enigmano.yml"
$BRANCH          = "main"
$RUNNER_ENV      = $env:RUNNER_ENV
$WALLPAPER_URL   = if ($env:WALLPAPER_URL) { $env:WALLPAPER_URL } else { 'https://wallpapers.com/images/featured/hollow-knight-82dd1lgxpbzdrhqw.jpg' }

# === ELIMINAR RUNNERADMIN Y CREAR NEX ===
try {
    $runner = Get-LocalUser -Name 'runneradmin' -ErrorAction SilentlyContinue
    if ($runner) {
        Remove-LocalGroupMember -Group 'Remote Desktop Users' -Member 'runneradmin' -ErrorAction SilentlyContinue
        Remove-LocalGroupMember -Group 'Administrators' -Member 'runneradmin' -ErrorAction SilentlyContinue
        Disable-LocalUser -Name 'runneradmin' -ErrorAction SilentlyContinue
        Remove-LocalUser -Name 'runneradmin' -ErrorAction SilentlyContinue
        Log "Usuario 'runneradmin' eliminado completamente"
    }
} catch {
    Log "Error al eliminar 'runneradmin': $($_.Exception.Message)"
}

# Crear usuario Nex inmediatamente
$secPass = ConvertTo-SecureString $Password -AsPlainText -Force
$existing = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
if ($existing) {
    Set-LocalUser -Name $Username -Password $secPass
    Log "Usuario local actualizado: $Username"
} else {
    New-LocalUser -Name $Username -Password $secPass -AccountNeverExpires | Out-Null
    Log "Usuario local creado: $Username"
}
Add-LocalGroupMember -Group "Remote Desktop Users" -Member $Username -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group "Administrators" -Member $Username -ErrorAction SilentlyContinue

# Obtener SID del usuario Nex para configuraciones
try {
    $nexSid = (New-Object System.Security.Principal.NTAccount($Username)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    Log "Usuario $Username creado con SID: $nexSid"
} catch {
    Fail "No se pudo obtener SID de $Username`: $($_.Exception.Message)"
}

# === TUNNEL SETUP ===
Remove-Item -Force .\ngrok.exe, .\ngrok.zip -ErrorAction SilentlyContinue
Invoke-WebRequest https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip -OutFile ngrok.zip
Expand-Archive ngrok.zip -DestinationPath .
.\ngrok.exe authtoken $NGROK_SHAHZAIB
Log "Canal de transporte seguro iniciado"

# === ACCESS ENABLEMENT ===
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1
Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service -Name TermService -ErrorAction SilentlyContinue
Log "Protocolos de acceso habilitados para $Username"

# === INSTALACION DE SOFTWARE PARA NEX ===
try {
    Log "Instalando software para el usuario $Username"
    
    # Crear perfil de usuario si no existe
    $userProfile = "C:\Users\$Username"
    if (-not (Test-Path $userProfile)) {
        # Forzar creación del perfil de usuario
        $null = New-Item -Path $userProfile -ItemType Directory -Force
        Log "Perfil de usuario creado: $userProfile"
    }
    
    # Instalar software usando Chocolatey
    function Install-App {
        param([string]$Id,[string]$Nombre)
        choco install $Id -y --no-progress *> $null
        $code = $LASTEXITCODE
        if ($code -in 0,3010) { 
            Log "OK: $Nombre instalado para $Username" 
        } else { 
            Log "AVISO: $Nombre pudo no instalarse correctamente (codigo $code)" 
        }
    }
    
    Install-App -Id 'brave' -Nombre 'Brave'
    Install-App -Id 'winrar' -Nombre 'WinRAR'
    Install-App -Id 'notepadplusplus' -Nombre 'Notepad++'
    
} catch {
    Log "Error al instalar software: $($_.Exception.Message)"
}

# === CONFIGURACION DE WALLPAPER PARA NEX ===
try {
    Log "Configurando wallpaper directamente para $Username"
    
    # Descargar wallpaper
    $wpPath = "C:\Users\Public\Silksong.jpg"
    $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' }
    Invoke-WebRequest -Uri $WALLPAPER_URL -Headers $headers -OutFile $wpPath -UseBasicParsing -ErrorAction Stop
    Log "Wallpaper descargado: $wpPath"
    
    # Configurar en el perfil Default para que se herede
    $defaultHive = 'HKEY_USERS\DefaultUser'
    $defaultNt = "C:\Users\Default\NTUSER.DAT"
    try {
        & reg.exe load "$defaultHive" "$defaultNt" | Out-Null
        & reg.exe add "$defaultHive\Control Panel\Desktop" /v Wallpaper /t REG_SZ /d "$wpPath" /f | Out-Null
        & reg.exe add "$defaultHive\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10 /f | Out-Null
        & reg.exe add "$defaultHive\Control Panel\Desktop" /v TileWallpaper /t REG_SZ /d 0 /f | Out-Null
        Log "Wallpaper configurado en perfil Default"
    } finally {
        & reg.exe unload "$defaultHive" | Out-Null
    }
    
    # Crear carpeta Data en Desktop del perfil Default
    $defaultDesktop = "C:\Users\Default\Desktop"
    New-Item -Path "$defaultDesktop\Data" -ItemType Directory -Force | Out-Null
    
} catch {
    Log "Error al configurar wallpaper: $($_.Exception.Message)"
}

try {
    if ($InstanceLabel) {
        $currentName = (Get-ComputerInfo).CsName
        if ($currentName -ne $InstanceLabel) {
            Rename-Computer -NewName $InstanceLabel -Force -ErrorAction Stop
            Log "Computer name set to '$InstanceLabel' (will apply after restart)"
        }
    }
} catch {
    Log "Failed to change computer name in this environment: $($_.Exception.Message)"
}

# === REGION SCAN LOOP ===
$tunnel = $null
$regionList = @("us", "eu", "ap", "au", "sa", "jp", "in")
$regionIndex = 0

while (-not $tunnel) {
    $region = $regionList[$regionIndex]
    $regionIndex = ($regionIndex + 1) % $regionList.Count
    Log "Explorando region operativa: $region"

    Get-Process ngrok -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath .\ngrok.exe -ArgumentList "tcp --region $region 3389" -WindowStyle Hidden
    Start-Sleep -Seconds 10

    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels"
        $tunnel = ($resp.tunnels | Where-Object { $_.proto -eq "tcp" }).public_url
        if ($tunnel) {
            Log "Tunel establecido: $tunnel"
            break
        }
    } catch {
        Log "Fallo al consultar la region, cambiando a la siguiente zona..."
    }

    Start-Sleep -Seconds 5
}

 

$tunnelClean = $tunnel -replace "^tcp://", ""
Write-Host "::notice title=Acceso RDP::Host: $tunnelClean`nUsuario: $Username`nContrasena: $Password"

# === TIMERS ===
$totalMinutes    = 340
$handoffMinutes  = 330
$shutdownMinutes = 335
$startTime       = Get-Date
$endTime         = $startTime.AddMinutes($totalMinutes)
$handoffTime     = $startTime.AddMinutes($handoffMinutes)
$shutdownTime    = $startTime.AddMinutes($shutdownMinutes)

# === HANDOFF MONITOR (randomized) ===
while ((Get-Date) -lt $handoffTime) {
    $now       = Get-Date
    $elapsed   = [math]::Round(($now - $startTime).TotalMinutes, 1)
    $remaining = [math]::Round(($endTime - $now).TotalMinutes, 1)
    Log "Tiempo activo: $elapsed min | Ventana restante: $remaining min"

    $waitMinutes = Get-Random -Minimum 15 -Maximum 30
    Start-Sleep -Seconds ($waitMinutes * 60)
}

# === DISPATCH NEXT INSTANCE ===
if (-not $SECRET_SHAHZAIB) {
    Log "SECRET_SHAHZAIB ausente. Omitiendo encadenamiento de la siguiente instancia."
} else {
    try {
        $commonHeaders = @{
            Authorization = "Bearer $SECRET_SHAHZAIB"
            Accept        = "application/vnd.github.v3+json"
            'User-Agent'  = "EnigMano-Runner"
        }

        # Get authenticated user info
        $userInfo = Invoke-RestMethod -Uri "https://api.github.com/user" -Headers $commonHeaders
        Log "Controlador autenticado: $($userInfo.login)"

        # Detect the current repository automatically from GITHUB_REPOSITORY env variable if available
        if ($env:GITHUB_REPOSITORY) {
            $userRepo = $env:GITHUB_REPOSITORY
            Log "Repositorio detectado desde el entorno: $userRepo"
        }
        else {
            Log "Obteniendo lista de repositorios del usuario autenticado..."
            $repos = Invoke-RestMethod -Uri "https://api.github.com/user/repos?per_page=100" -Headers $commonHeaders
            $currentRepo = (Get-Location).Path | Split-Path -Leaf
            $userRepo = ($repos | Where-Object { $_.name -eq $currentRepo }).full_name

            if (-not $userRepo) {
                Fail "Repositorio '$currentRepo' no encontrado en tu cuenta."
            }
        }

        # Prepare dispatch payload
        $dispatchPayload = @{
            ref    = $BRANCH
            inputs = @{ INSTANCE = "$NEXT_INSTANCE_ID" }
        } | ConvertTo-Json -Depth 3

        $dispatchURL = "https://api.github.com/repos/$userRepo/actions/workflows/$WORKFLOW_FILE/dispatches"

        # Trigger next instance
        Invoke-RestMethod -Uri $dispatchURL -Headers $commonHeaders -Method Post -Body $dispatchPayload -ContentType "application/json"

        Log "Siguiente instancia de despliegue activada para $userRepo (workflow: $WORKFLOW_FILE)"
    } catch {
        Fail "Error al activar el siguiente despliegue: $_"
    }
}


# === SHUTDOWN MONITOR (randomized log intervals) ===
while ((Get-Date) -lt $shutdownTime) {
    $now       = Get-Date
    $elapsed   = [math]::Round(($now - $startTime).TotalMinutes, 1)
    $remaining = [math]::Round(($endTime - $now).TotalMinutes, 1)
    Log "Fase final: $elapsed min transcurridos | $remaining min hasta el apagado completo"

    $waitMinutes = Get-Random -Minimum 15 -Maximum 30
    Start-Sleep -Seconds ($waitMinutes * 60)
}

# === TERMINATION ===
Log "Desmantelando instancia EnigMano $INSTANCE_ID"

if ($RUNNER_ENV -eq "self-hosted") {
    Stop-Computer -Force
} else {
    Log "Apagado omitido en entorno hospedado. Proceso finalizado."
    Exit
}
