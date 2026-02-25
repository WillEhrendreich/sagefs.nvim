# sync-version.ps1 — Pull version from SageFs and update lua/sagefs/version.lua
# Usage: .\sync-version.ps1 [-SageFsDir ..\SageFs]

param(
  [string]$SageFsDir = (Join-Path $PSScriptRoot "..\SageFs")
)

$propsFile = Join-Path $SageFsDir "Directory.Build.props"
if (-not (Test-Path $propsFile)) {
  Write-Error "Cannot find $propsFile"
  exit 1
}

$xml = [xml](Get-Content $propsFile)
$version = $xml.Project.PropertyGroup.Version

if (-not $version) {
  Write-Error "Could not extract version from Directory.Build.props"
  exit 1
}

$versionFile = Join-Path $PSScriptRoot "lua\sagefs\version.lua"
Set-Content -Path $versionFile -Value "return `"$version`"`n" -NoNewline
Write-Host "Synced version to $version"
