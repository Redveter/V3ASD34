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

# === LOCK DOWN DEFAULT RUNNER USER FIRST ===
try {
    $runner = Get-LocalUser -Name 'runneradmin' -ErrorAction SilentlyContinue
    if ($runner) {
        Remove-LocalGroupMember -Group 'Remote Desktop Users' -Member 'runneradmin' -ErrorAction SilentlyContinue
        Disable-LocalUser -Name 'runneradmin' -ErrorAction SilentlyContinue
        try { Remove-LocalUser -Name 'runneradmin' -ErrorAction SilentlyContinue } catch {}
        Log "Usuario 'runneradmin' deshabilitado, removido de RDP y eliminado (si fue posible)"
    }
} catch {
    Log "No se pudo modificar 'runneradmin' (fase inicial): $($_.Exception.Message)"
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

 # Ensure the Remote Desktop service is running and set to Automatic
 Set-Service -Name TermService -StartupType Automatic -ErrorAction SilentlyContinue
 Start-Service -Name TermService -ErrorAction SilentlyContinue

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

 # Identidad de sesion actual y del usuario destino (para trazabilidad)
 try {
     $currUser = $env:USERNAME
     $currSid  = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
     Log ("Sesion actual -> Usuario: {0} | SID: {1}" -f $currUser, $currSid)
 } catch {}

 try {
     $targetSid = (New-Object System.Security.Principal.NTAccount($Username)).Translate([System.Security.Principal.SecurityIdentifier]).Value
     Log ("Usuario destino -> {0} | SID: {1}" -f $Username, $targetSid)
 } catch {
     Log ("No se pudo resolver SID de {0}: {1}" -f $Username, $_.Exception.Message)
 }

# === WALLPAPER (estilo personalize.ps1, sin tareas ni lanzadores) ===
try {
    Log ("Aplicando wallpaper al estilo personalize.ps1 (preconfiguracion para {0})" -f $Username)

    $wpRoot = "C:\\Users\\Public\\$Username"
    New-Item -Path $wpRoot -ItemType Directory -Force | Out-Null

    $ext = [IO.Path]::GetExtension(([Uri]$WALLPAPER_URL).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($ext)) { $ext = '.jpg' }
    $wpPath = Join-Path $wpRoot ("Silksong" + $ext)

    $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0 Safari/537.36' }
    Invoke-WebRequest -Uri $WALLPAPER_URL -Headers $headers -OutFile $wpPath -UseBasicParsing -ErrorAction Stop
    Log "Wallpaper descargado en $wpPath"

    if (Test-Path $wpPath) {
        # Preconfigurar para nuevas sesiones montando el perfil por defecto (C:\Users\Default)
        $defaultHive = 'HKEY_USERS\DefaultUser'
        $defaultNt   = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
        try {
            & reg.exe load "$defaultHive" "$defaultNt" | Out-Null
            & reg.exe add "$defaultHive\Control Panel\Desktop" /v Wallpaper /t REG_SZ /d "$wpPath" /f | Out-Null
            & reg.exe add "$defaultHive\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10 /f | Out-Null
            & reg.exe add "$defaultHive\Control Panel\Desktop" /v TileWallpaper /t REG_SZ /d 0 /f | Out-Null
            Log "Valores por defecto establecidos en el perfil base (Default)"
        } finally {
            & reg.exe unload "$defaultHive" | Out-Null
        }

        # Copiar tambien a TranscodedWallpaper del perfil Default para que se herede el archivo
        try {
            $defThemes = Join-Path $env:SystemDrive 'Users\Default\AppData\Roaming\Microsoft\Windows\Themes'
            New-Item -Path $defThemes -ItemType Directory -Force | Out-Null
            Copy-Item -Path $wpPath -Destination (Join-Path $defThemes 'TranscodedWallpaper') -Force
            Log "TranscodedWallpaper precreado en perfil Default"
        } catch {
            Log ("No se pudo preparar TranscodedWallpaper en Default: {0}" -f $_.Exception.Message)
        }

        # Si el perfil de $Username ya existe, intente preconfigurarlo directamente usando su SID real
        $userNt = Join-Path $env:SystemDrive ("Users\{0}\NTUSER.DAT" -f $Username)
        if (Test-Path $userNt) {
            try {
                $sid = (New-Object System.Security.Principal.NTAccount($Username)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                $targetHive = "HKEY_USERS\$sid"
                & reg.exe load "$targetHive" "$userNt" | Out-Null
                & reg.exe add "$targetHive\Control Panel\Desktop" /v Wallpaper /t REG_SZ /d "$wpPath" /f | Out-Null
                & reg.exe add "$targetHive\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10 /f | Out-Null
                & reg.exe add "$targetHive\Control Panel\Desktop" /v TileWallpaper /t REG_SZ /d 0 /f | Out-Null
                Log ("Perfil existente de {0} preconfigurado exitosamente (SID: {1})" -f $Username, $sid)
            } catch {
                Log ("No se pudo preconfigurar el hive de {0}: {1}" -f $Username, $_.Exception.Message)
            } finally {
                try { & reg.exe unload "$targetHive" | Out-Null } catch {}
            }

            # Adicional: copiar TranscodedWallpaper al perfil del usuario si ya existe
            try {
                $userThemes = Join-Path $env:SystemDrive ("Users\{0}\AppData\Roaming\Microsoft\Windows\Themes" -f $Username)
                New-Item -Path $userThemes -ItemType Directory -Force | Out-Null
                Copy-Item -Path $wpPath -Destination (Join-Path $userThemes 'TranscodedWallpaper') -Force
                Log "TranscodedWallpaper copiado al perfil existente de $Username"
            } catch {
                Log ("No se pudo copiar TranscodedWallpaper al perfil de {0}: {1}" -f $Username, $_.Exception.Message)
            }
        }

        # Crear carpeta Data en el Desktop del perfil por defecto (se heredara a Nex en primer logon)
        $defaultDesktop = Join-Path $env:SystemDrive 'Users\Default\Desktop'
        try { New-Item -Path (Join-Path $defaultDesktop 'Data') -ItemType Directory -Force | Out-Null } catch {}

        # Nota: Se omite establecer politica HKLM para evitar errores de privilegios en runners hospedados

        # Si el script corre ya en la sesion de destino ($Username), aplicar de inmediato en HKCU
        try {
            if ($env:USERNAME -and ($env:USERNAME -ieq $Username)) {
                $themes     = Join-Path $env:APPDATA 'Microsoft\\Windows\\Themes'
                $transcoded = Join-Path $themes 'TranscodedWallpaper'
                New-Item -Path $themes -ItemType Directory -Force | Out-Null
                Copy-Item -Path $wpPath -Destination $transcoded -Force

                $reg = 'HKCU:\\Control Panel\\Desktop'
                Set-ItemProperty -Path $reg -Name Wallpaper -Value $transcoded
                Set-ItemProperty -Path $reg -Name WallpaperStyle -Value 10
                Set-ItemProperty -Path $reg -Name TileWallpaper -Value 0

                $member = '[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);'
                Add-Type -Namespace Win32 -Name Native -MemberDefinition $member -ErrorAction SilentlyContinue | Out-Null
                [Win32.Native]::SystemParametersInfo(0x0014, 0, $transcoded, 0x0001 -bor 0x0002) | Out-Null
                rundll32 user32.dll,UpdatePerUserSystemParameters 1,True

                Log ("Wallpaper aplicado inmediatamente en HKCU para {0}" -f $Username)
            } else {
                Log ("Wallpaper preconfigurado; se aplicara al iniciar sesion {0}" -f $Username)
            }
        } catch {
            Log ("No se pudo aplicar en HKCU durante la instalacion: {0}" -f $_.Exception.Message)
        }
    }
} catch {
    Log "Error al aplicar wallpaper: $($_.Exception.Message)"
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
