$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$flutterSafe = Join-Path $repoRoot "tool\flutter_safe.ps1"

if (-not (Test-Path $flutterSafe)) {
  throw "flutter_safe.ps1 not found: $flutterSafe"
}

if (-not $env:LINEAGE_RELEASE_SIGNING_PROPERTIES -and -not $env:LINEAGE_KEYSTORE_FILE) {
  Write-Warning "Release signing is not configured. Set LINEAGE_RELEASE_SIGNING_PROPERTIES or LINEAGE_KEYSTORE_* env vars before building."
}

$defines = @(
  "--dart-define=LINEAGE_RUNTIME_PRESET=prod_custom_api",
  "--dart-define=LINEAGE_ENABLE_LEGACY_DYNAMIC_LINKS=false"
)

$buildArgs = @("build", "appbundle", "--release") + $defines

if ($env:LINEAGE_BUILD_NAME) {
  $buildArgs += "--build-name=$($env:LINEAGE_BUILD_NAME)"
}

if ($env:LINEAGE_BUILD_NUMBER) {
  $buildArgs += "--build-number=$($env:LINEAGE_BUILD_NUMBER)"
}

powershell -ExecutionPolicy Bypass -File $flutterSafe @buildArgs
