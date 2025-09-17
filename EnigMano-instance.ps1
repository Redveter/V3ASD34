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
# Configure ngrok using a system-wide config to avoid runneradmin profile writes
try {
    $ngrokDir = Join-Path $env:ProgramData 'ngrok'
    New-Item -Path $ngrokDir -ItemType Directory -Force | Out-Null
    $ngrokCfg = Join-Path $ngrokDir 'ngrok.yml'
    $env:NGROK_CONFIG = $ngrokCfg
    try {
        .\ngrok.exe config add-authtoken $NGROK_SHAHZAIB | Out-Null
    } catch {
        # fallback for older syntax
        .\ngrok.exe authtoken $NGROK_SHAHZAIB | Out-Null
    }
    Log "Canal de transporte seguro iniciado"
} catch {
    Log ("Fallo configurando ngrok: {0}" -f $_.Exception.Message)
}

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

 # Asegurar creacion de perfil del usuario objetivo antes de aplicar wallpaper (offline)
 try {
     $userNt = Join-Path $env:SystemDrive ("Users\{0}\NTUSER.DAT" -f $Username)
     if (-not (Test-Path $userNt) -and $targetSid) {
         $cs = @"
 using System;
 using System.Text;
 using System.Runtime.InteropServices;
 public static class UserEnvNative {
   [DllImport("userenv.dll", CharSet=CharSet.Unicode, SetLastError=true)]
   public static extern int CreateProfile(string pszUserSid, string pszUserName, StringBuilder pszProfilePath, uint cchProfilePath);
 }
 "@
         Add-Type -TypeDefinition $cs -ErrorAction SilentlyContinue | Out-Null
         $sb = New-Object System.Text.StringBuilder 512
         $hr = [UserEnvNative]::CreateProfile($targetSid, $Username, $sb, [uint32]$sb.Capacity)
         if ($hr -eq 0) {
             $createdPath = $sb.ToString()
             Log ("Perfil base creado/asegurado para {0} en: {1}" -f $Username, $createdPath)
         } else {
             Log ("CreateProfile devolvio codigo {0} (puede ser ya existente)" -f $hr)
         }
     }
 } catch {
     Log ("No se pudo crear/asegurar el perfil de {0}: {1}" -f $Username, $_.Exception.Message)
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
        # Bandera para habilitar/deshabilitar refuerzo RunOnce sin tareas/launchers (por defecto: habilitado)
        $enableRunOnce = $env:APPLY_WALLPAPER_RUNONCE
        if ([string]::IsNullOrWhiteSpace($enableRunOnce)) { $enableRunOnce = 'true' }
        $enableRunOnce = ($enableRunOnce -match '^(?i:true|1|yes)$')

        # Script de refuerzo que aplica el wallpaper en HKCU al iniciar sesion del usuario (via RunOnce)
        $applyScriptPath = Join-Path $wpRoot 'ApplyUserWallpaper.ps1'
        $psApplyContent = @"
param()
try {
  $img    = '$wpPath'
  $themes = Join-Path $env:APPDATA 'Microsoft\Windows\Themes'
  New-Item -Path $themes -ItemType Directory -Force | Out-Null
  Copy-Item -Path $img -Destination (Join-Path $themes 'TranscodedWallpaper') -Force

  $reg = 'HKCU:\Control Panel\Desktop'
  Set-ItemProperty -Path $reg -Name Wallpaper -Value $img
  Set-ItemProperty -Path $reg -Name WallpaperStyle -Value 10
  Set-ItemProperty -Path $reg -Name TileWallpaper -Value 0

  $code = @'
using System.Runtime.InteropServices;
public static class Win32 {
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
  Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue | Out-Null
  [Win32]::SystemParametersInfo(0x0014, 0, $img, 0x0001 -bor 0x0002) | Out-Null
  rundll32 user32.dll,UpdatePerUserSystemParameters 1,True
} catch {}
"@
        Set-Content -Path $applyScriptPath -Value $psApplyContent -Encoding UTF8
        Log "Script de refuerzo creado: $applyScriptPath"

        # Garantizar aplicacion en primer logon del usuario objetivo via Tarea Programada
        try {
            $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$applyScriptPath`""
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Username
            Register-ScheduledTask -TaskName "ApplyWallpaperOnLogon-$Username" -Action $action -Trigger $trigger -Description "Aplica wallpaper en primer logon" -User $Username -Password $Password -RunLevel Highest -Force | Out-Null
            Log ("Tarea programada creada para aplicar wallpaper al iniciar sesion de {0}" -f $Username)
        } catch {
            Log ("No se pudo crear la tarea programada de wallpaper: {0}" -f $_.Exception.Message)
        }

        # Preconfigurar para nuevas sesiones montando el perfil por defecto (C:\Users\Default)
        $defaultHive = 'HKEY_USERS\DefaultUser'
        $defaultNt   = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
        try {
            & reg.exe load "$defaultHive" "$defaultNt" | Out-Null
            & reg.exe add "$defaultHive\Control Panel\Desktop" /v Wallpaper /t REG_SZ /d "$wpPath" /f | Out-Null
            & reg.exe add "$defaultHive\Control Panel\Desktop" /v WallpaperStyle /t REG_SZ /d 10 /f | Out-Null
            & reg.exe add "$defaultHive\Control Panel\Desktop" /v TileWallpaper /t REG_SZ /d 0 /f | Out-Null
            Log "Valores por defecto establecidos en el perfil base (Default)"

            if ($enableRunOnce) {
                $runOnceCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$applyScriptPath`""
                & reg.exe add "$defaultHive\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "ApplyWallpaperOnce" /t REG_SZ /d "$runOnceCmd" /f | Out-Null
                Log "RunOnce heredado configurado en perfil Default"
            }
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

                if ($enableRunOnce) {
                    $runOnceCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$applyScriptPath`""
                    & reg.exe add "$targetHive\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "ApplyWallpaperOnce" /t REG_SZ /d "$runOnceCmd" /f | Out-Null
                    Log ("RunOnce configurado para {0}" -f $Username)
                }

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
    } # end if (Test-Path $wpPath)
} catch {
    Log "Error al aplicar wallpaper: $($_.Exception.Message)"
}

# === SOFTWARE INSTALLATION (Chocolatey + Apps) ===
try {
    Log "Instalando software base (Chocolatey, Brave, WinRAR, Notepad++)"
    $ProgressPreference = 'SilentlyContinue'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        choco --version | Out-Null
        Log "Chocolatey instalado"
    } else {
        Log "Chocolatey ya presente"
    }

    function Install-App {
        param([string]$Id,[string]$Nombre)
        choco install $Id -y --no-progress *> $null
        $code = $LASTEXITCODE
        if ($code -in 0,3010) { Log ("OK: {0} instalado" -f $Nombre) }
        else { Log ("AVISO: {0} pudo no instalarse correctamente (codigo {1})" -f $Nombre,$code) }
    }

    Install-App -Id 'brave' -Nombre 'Brave'
    Install-App -Id 'winrar' -Nombre 'WinRAR'
    Install-App -Id 'notepadplusplus' -Nombre 'Notepad++'

    # Politica HKLM para forzar uBlock Origin en Brave
    try {
        $policyPath = "HKLM:\\Software\\Policies\\BraveSoftware\\Brave\\ExtensionInstallForcelist"
        New-Item -Path $policyPath -Force | Out-Null
        New-ItemProperty -Path $policyPath -Name "1" -Value "cjpalhdlnbpafiamejdnhcphjbkeiagm;https://clients2.google.com/service/update2/crx" -PropertyType String -Force | Out-Null
        Log "Politica uBlock Origin para Brave aplicada"
    } catch {
        Log ("No se pudo aplicar politica de Brave: {0}" -f $_.Exception.Message)
    }

} catch {
    Log ("Error durante instalacion de software: {0}" -f $_.Exception.Message)
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
