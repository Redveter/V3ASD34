param(
    [string]$Username,
    [string]$Password,
    [string]$InstanceLabel
)

$ErrorActionPreference = "Stop"

function Timestamp { (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
function Log($msg) { Write-Host "[ENIGMANO $(Timestamp)] $msg" }
function Fail($msg) { Write-Error "[ENIGMANO-ERROR $(Timestamp)] $msg"; Exit 1 }

# === INPUT NORMALIZATION ===
if ([string]::IsNullOrWhiteSpace($InstanceLabel)) { $InstanceLabel = "Nex" }
if ([string]::IsNullOrWhiteSpace($Username))      { $Username      = "Nex" }
if ([string]::IsNullOrWhiteSpace($Password))      { $Password      = "Example#9943" }

Write-Host "::add-mask::$Password"

# === ASCII BANNER ===
$now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
 Write-Host @"
 ----------------------------------------------------
       ENIGMANO INSTANCIA $env:INSTANCE_ID — $InstanceLabel
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
 Log "Protocolos de acceso habilitados para la instancia"

 try {
     if ($InstanceLabel) {
         $currentName = (Get-ComputerInfo).CsName
         if ($currentName -ne $InstanceLabel) {
             Rename-Computer -NewName $InstanceLabel -Force -ErrorAction Stop
             Log "Nombre del equipo establecido a '$InstanceLabel' (se aplicará tras reinicio)"
         }
     }
 } catch {
     Log "No se pudo cambiar el nombre del equipo en este entorno: $($_.Exception.Message)"
 }

# === REGION SCAN LOOP ===
$tunnel = $null
$regionList = @("us", "eu", "ap", "au", "sa", "jp", "in")
$regionIndex = 0

while (-not $tunnel) {
    $region = $regionList[$regionIndex]
    $regionIndex = ($regionIndex + 1) % $regionList.Count
    Log "Explorando región operativa: $region"

    Get-Process ngrok -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath .\ngrok.exe -ArgumentList "tcp --region $region 3389" -WindowStyle Hidden
    Start-Sleep -Seconds 10

    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:4040/api/tunnels"
        $tunnel = ($resp.tunnels | Where-Object { $_.proto -eq "tcp" }).public_url
        if ($tunnel) {
        
            break
        }
    } catch {
        Log "Fallo al consultar la región, cambiando a la siguiente zona..."
    }

    Start-Sleep -Seconds 5
}

# === DATA VAULT CREATION ===
try {
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $dataFolderPath = Join-Path $desktopPath "Data"
    if (-not (Test-Path $dataFolderPath)) {
        New-Item -Path $dataFolderPath -ItemType Directory | Out-Null
        Log "Bóveda de datos creada en $dataFolderPath"
    } else {
        Log "La bóveda de datos ya existe en $dataFolderPath"
    }
} catch {
    Fail "Error al crear la bóveda de datos: $_"
}

$tunnelClean = $tunnel -replace "^tcp://", ""
Write-Host "::notice title=Acceso RDP::Host: $tunnelClean`nUsuario: $Username`nContraseña: $Password"

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
try {
    # Get authenticated user info
    $userInfo = Invoke-RestMethod -Uri "https://api.github.com/user" -Headers @{ Authorization = "Bearer $SECRET_SHAHZAIB" }
    Log "Controlador autenticado: $($userInfo.login)"

    # Detect the current repository automatically from GITHUB_REPOSITORY env variable if available
    if ($env:GITHUB_REPOSITORY) {
        $userRepo = $env:GITHUB_REPOSITORY
        Log "Repositorio detectado desde el entorno: $userRepo"
    }
    else {
        Log "Obteniendo lista de repositorios del usuario autenticado..."
        $repos = Invoke-RestMethod -Uri "https://api.github.com/user/repos?per_page=100" -Headers @{ Authorization = "Bearer $SECRET_SHAHZAIB" }
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
    Invoke-RestMethod -Uri $dispatchURL -Headers @{
        Authorization = "Bearer $SECRET_SHAHZAIB"
        Accept        = "application/vnd.github.v3+json"
    } -Method Post -Body $dispatchPayload -ContentType "application/json"

    Log "Siguiente instancia de despliegue activada para $userRepo (workflow: $WORKFLOW_FILE)"
} catch {
    Fail "Error al activar el siguiente despliegue: $_"
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
