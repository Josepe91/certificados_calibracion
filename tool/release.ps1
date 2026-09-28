# Publica una versión nueva de la app para los técnicos.
#
# Uso (desde la carpeta del proyecto):
#   powershell -ExecutionPolicy Bypass -File tool\release.ps1 -Notas "Qué cambió"
#   ... -Version 1.2.0     # opcional: cambia también el nombre de versión
#
# Qué hace, en orden:
#   1. Sube el número de build del pubspec (1.1.0+2 -> 1.1.0+3).
#   2. Compila el APK con PUBLICAR_VERSION=true: al abrirse, ESTE build
#      sube config/app.version_minima en Firestore y los celulares con un
#      build anterior quedan bloqueados hasta actualizar (ver
#      lib/data/version_app.dart). Un APK compilado a mano sin este script
#      nunca bloquea a nadie.
#   3. Lo distribuye al grupo "tecnicos" por Firebase App Distribution.
#   4. Hace commit del pubspec, un tag git "v<version>+<build>" y lo sube
#      a GitHub (github.com/Josepe91/certificados_calibracion, privado).
param(
  [Parameter(Mandatory = $true)][string]$Notas,
  [string]$Version
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

if (git status --porcelain) {
  throw 'Hay cambios sin commit. Haz commit antes de publicar para que el tag corresponda al código distribuido.'
}

$pubspec = Get-Content pubspec.yaml -Raw -Encoding UTF8
if ($pubspec -notmatch '(?m)^version:\s*([0-9.]+)\+(\d+)\s*$') { throw 'No encontré "version: x.y.z+N" en pubspec.yaml' }
$nombre = if ($Version) { $Version } else { $Matches[1] }
$build = [int]$Matches[2] + 1
$pubspec = $pubspec -replace '(?m)^version:.*$', "version: $nombre+$build"
[IO.File]::WriteAllText((Resolve-Path pubspec.yaml), $pubspec, (New-Object Text.UTF8Encoding $false))
Write-Host "Versión: $nombre+$build" -ForegroundColor Cyan

flutter build apk --release --dart-define=PUBLICAR_VERSION=true
if ($LASTEXITCODE) { throw 'Falló la compilación' }

firebase appdistribution:distribute "build/app/outputs/flutter-apk/app-release.apk" `
  --app 1:1025261964154:android:99d53193eb69d0701924c3 `
  --groups "tecnicos" `
  --release-notes "v$nombre ($build): $Notas" `
  --project btmc-certificados
if ($LASTEXITCODE) { throw 'Falló la distribución (el pubspec quedó con el build nuevo; puedes reintentar solo el comando de firebase)' }

git add pubspec.yaml
git commit -m "Release v$nombre+$build`n`n$Notas"
git tag "v$nombre+$build"
# Respaldo en GitHub (privado). Si no hay señal no se cancela nada: la
# versión ya quedó distribuida; basta con correr `git push --follow-tags`
# después.
git push --follow-tags
if ($LASTEXITCODE) { Write-Warning 'No se pudo subir a GitHub; corre "git push --follow-tags" cuando haya señal.' }
Write-Host "Listo: v$nombre+$build distribuida y etiquetada." -ForegroundColor Green
