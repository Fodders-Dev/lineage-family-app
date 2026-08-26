param(
  [ValidateSet("appbundle", "apk", "both")]
  [string]$ArtifactKind = "appbundle"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$flutterSafe = Join-Path $repoRoot "tool\flutter_safe.ps1"

if (-not (Test-Path $flutterSafe)) {
  throw "flutter_safe.ps1 not found: $flutterSafe"
}

function Get-NonEmptyEnv([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $null
  }
  return $value.Trim()
}

function Read-ReleaseSigningProperties([string]$Path) {
  $properties = @{}
  if (-not (Test-Path -LiteralPath $Path)) {
    return $properties
  }

  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
      continue
    }

    $separator = $trimmed.IndexOf("=")
    if ($separator -le 0) {
      continue
    }

    $key = $trimmed.Substring(0, $separator).Trim()
    $value = $trimmed.Substring($separator + 1).Trim()
    if ($key.Length -gt 0) {
      $properties[$key] = $value
    }
  }

  return $properties
}

function Get-SigningValue([hashtable]$Properties, [string]$PropertyName, [string]$EnvName) {
  if ($Properties.ContainsKey($PropertyName) -and -not [string]::IsNullOrWhiteSpace($Properties[$PropertyName])) {
    return $Properties[$PropertyName].ToString().Trim()
  }
  return Get-NonEmptyEnv $EnvName
}

function Resolve-SigningStoreFile([string]$StoreFile, [string]$PropertiesPath) {
  if ([string]::IsNullOrWhiteSpace($StoreFile)) {
    return $null
  }

  $candidates = New-Object System.Collections.Generic.List[string]
  if ([System.IO.Path]::IsPathRooted($StoreFile)) {
    $candidates.Add($StoreFile)
  } else {
    if (-not [string]::IsNullOrWhiteSpace($PropertiesPath)) {
      $propertiesDir = Split-Path -Parent $PropertiesPath
      if (-not [string]::IsNullOrWhiteSpace($propertiesDir)) {
        $candidates.Add((Join-Path $propertiesDir $StoreFile))
      }
    }
    $candidates.Add((Join-Path (Join-Path $repoRoot "android") $StoreFile))
    # Gradle resolves storeFile relative to the app MODULE (android/app), so
    # a properties path like "../KEYS/foo.jks" points at android/KEYS. Mirror
    # gradle's resolution here so the pre-flight check agrees with the build.
    $candidates.Add((Join-Path (Join-Path $repoRoot "android\app") $StoreFile))
    $candidates.Add((Join-Path (Join-Path $repoRoot "android") ($StoreFile -replace "\.\./", "")))
    $candidates.Add((Join-Path $repoRoot $StoreFile))
  }

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  return $null
}

function Assert-ReleaseSigningConfigured {
  $configuredPropertiesPath = Get-NonEmptyEnv "RODNYA_RELEASE_SIGNING_PROPERTIES"
  $propertiesPath = $configuredPropertiesPath
  if (-not $propertiesPath) {
    $propertiesPath = Join-Path $repoRoot "android\release-signing.properties"
  }

  if ($configuredPropertiesPath -and -not (Test-Path -LiteralPath $propertiesPath)) {
    throw "Release signing properties file was not found. Check RODNYA_RELEASE_SIGNING_PROPERTIES."
  }

  $properties = Read-ReleaseSigningProperties $propertiesPath
  $storeFile = Get-SigningValue $properties "storeFile" "RODNYA_KEYSTORE_FILE"
  $storePassword = Get-SigningValue $properties "storePassword" "RODNYA_KEYSTORE_PASSWORD"
  $keyAlias = Get-SigningValue $properties "keyAlias" "RODNYA_KEY_ALIAS"
  $keyPassword = Get-SigningValue $properties "keyPassword" "RODNYA_KEY_PASSWORD"

  $missing = @()
  if ([string]::IsNullOrWhiteSpace($storeFile)) { $missing += "storeFile/RODNYA_KEYSTORE_FILE" }
  if ([string]::IsNullOrWhiteSpace($storePassword)) { $missing += "storePassword/RODNYA_KEYSTORE_PASSWORD" }
  if ([string]::IsNullOrWhiteSpace($keyAlias)) { $missing += "keyAlias/RODNYA_KEY_ALIAS" }
  if ([string]::IsNullOrWhiteSpace($keyPassword)) { $missing += "keyPassword/RODNYA_KEY_PASSWORD" }

  if ($missing.Count -gt 0) {
    throw "Release signing is incomplete. Missing: $($missing -join ', '). Set RODNYA_RELEASE_SIGNING_PROPERTIES or RODNYA_KEYSTORE_* before building."
  }

  $resolvedStoreFile = Resolve-SigningStoreFile $storeFile $propertiesPath
  if (-not $resolvedStoreFile) {
    throw "Release signing keystore file was not found. Check storeFile or RODNYA_KEYSTORE_FILE."
  }
}

function Find-ApkSigner {
  $androidRoots = @(
    (Get-NonEmptyEnv "ANDROID_HOME"),
    (Get-NonEmptyEnv "ANDROID_SDK_ROOT"),
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Android\Sdk" }),
    $(if ($env:HOME) { Join-Path $env:HOME "Android\Sdk" })
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

  foreach ($androidRoot in $androidRoots) {
    $buildToolsDir = Join-Path $androidRoot "build-tools"
    if (-not (Test-Path -LiteralPath $buildToolsDir)) {
      continue
    }

    $apksigner = Get-ChildItem -LiteralPath $buildToolsDir -Directory |
      Sort-Object Name -Descending |
      ForEach-Object { Join-Path $_.FullName "apksigner.bat" } |
      Where-Object { Test-Path -LiteralPath $_ } |
      Select-Object -First 1

    if ($apksigner) {
      return $apksigner
    }
  }

  return $null
}

function Invoke-ApkSignerVerify([string]$ApkPath) {
  if (-not (Test-Path -LiteralPath $ApkPath)) {
    throw "APK was not found for signature verification: $ApkPath"
  }

  $apksigner = Find-ApkSigner
  if (-not $apksigner) {
    throw "apksigner was not found in ANDROID_HOME or ANDROID_SDK_ROOT; cannot verify release APK signature."
  }

  & $apksigner verify --verbose $ApkPath
  if ($LASTEXITCODE -ne 0) {
    throw "apksigner verify failed for release APK."
  }
}

Assert-ReleaseSigningConfigured

$defines = @(
  "--dart-define=RODNYA_RUNTIME_PRESET=prod_custom_api",
  "--dart-define=RODNYA_ENABLE_LEGACY_DYNAMIC_LINKS=false",
  "--dart-define=RODNYA_GOOGLE_WEB_CLIENT_ID=676171184233-hl6gauj8c1trtn25a8me7pvm4m4clndv.apps.googleusercontent.com",
  "--dart-define=RODNYA_APP_STORE=rustore",
  "--dart-define=RODNYA_ENABLE_RUSTORE_BILLING=false",
  "--dart-define=RODNYA_ENABLE_RUSTORE_REVIEW=true",
  "--dart-define=RODNYA_ENABLE_RUSTORE_UPDATES=true"
)

function Invoke-RustoreBuild([string]$artifactType) {
  $buildArgs = @("build", $artifactType, "--flavor", "rustore", "--release") + $defines

  if ($env:RODNYA_BUILD_NAME) {
    $buildArgs += "--build-name=$($env:RODNYA_BUILD_NAME)"
  }

  if ($env:RODNYA_BUILD_NUMBER) {
    $buildArgs += "--build-number=$($env:RODNYA_BUILD_NUMBER)"
  }

  powershell -ExecutionPolicy Bypass -File $flutterSafe @buildArgs

  if ($artifactType -eq "apk") {
    $apkPath = Join-Path $repoRoot "build\app\outputs\flutter-apk\app-rustore-release.apk"
    Invoke-ApkSignerVerify $apkPath
  }
}

switch ($ArtifactKind) {
  "appbundle" { Invoke-RustoreBuild "appbundle" }
  "apk" { Invoke-RustoreBuild "apk" }
  "both" {
    Invoke-RustoreBuild "appbundle"
    Invoke-RustoreBuild "apk"
  }
}
