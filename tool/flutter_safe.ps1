param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$FlutterArgs
)

$ErrorActionPreference = 'Stop'

function Resolve-FlutterBinary {
  $command = Get-Command flutter -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $defaultFlutter = 'C:\src\flutter\bin\flutter.bat'
  if (Test-Path $defaultFlutter) {
    return $defaultFlutter
  }

  throw "Flutter binary not found. Add 'flutter' to PATH or install it at $defaultFlutter."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$safeRoot = Join-Path $env:TEMP 'lineage_safe_workspace'
$safeWorkspace = Join-Path $safeRoot 'repo'
$flutterBinary = Resolve-FlutterBinary

New-Item -ItemType Directory -Path $safeRoot -Force | Out-Null

if (Test-Path $safeWorkspace) {
  $existingItem = Get-Item -LiteralPath $safeWorkspace -Force
  $existingTarget = @($existingItem.Target)[0]
  if ($existingTarget -ne $repoRoot) {
    Remove-Item -LiteralPath $safeWorkspace -Force
  }
}

if (-not (Test-Path $safeWorkspace)) {
  New-Item -ItemType Junction -Path $safeWorkspace -Target $repoRoot | Out-Null
}

Push-Location $safeWorkspace
try {
  & $flutterBinary @FlutterArgs
  exit $LASTEXITCODE
}
finally {
  Pop-Location
}
