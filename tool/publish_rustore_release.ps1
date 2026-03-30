param(
  [string]$PackageName = "com.ahjkuio.lineage_family_app",
  [string]$ArtifactPath = "build/app/outputs/bundle/release/app-release.aab",
  [string]$AppName,
  [string]$AppType,
  [string]$PublishType,
  [Parameter(Mandatory = $true)]
  [int]$MinAndroidVersion,
  [string]$WhatsNew,
  [string]$WhatsNewFile,
  [string]$ModeratorComment,
  [int]$PriorityUpdate = 0,
  [switch]$SubmitForModeration
)

$ErrorActionPreference = "Stop"

function Get-RequiredEnv([string]$name) {
  $value = [Environment]::GetEnvironmentVariable($name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Missing environment variable: $name"
  }
  return $value
}

function Get-WhatsNewText {
  if (-not [string]::IsNullOrWhiteSpace($WhatsNew)) {
    return $WhatsNew.Trim()
  }
  if (-not [string]::IsNullOrWhiteSpace($WhatsNewFile)) {
    if (-not (Test-Path $WhatsNewFile)) {
      throw "WhatsNew file not found: $WhatsNewFile"
    }
    return (Get-Content $WhatsNewFile -Raw).Trim()
  }
  throw "Set -WhatsNew or -WhatsNewFile."
}

function New-RuStoreSignaturePayload(
  [string]$KeyId,
  [string]$PrivateKeyBase64
) {
  $timestamp = [DateTimeOffset]::Now.ToString("yyyy-MM-ddTHH:mm:ss.fffffffzzz")
  $message = "$KeyId$timestamp"
  $privateKeyBytes = [Convert]::FromBase64String($PrivateKeyBase64)
  $signatureBytes = $null
  $importMethod = [System.Security.Cryptography.RSA].GetMethod(
    "ImportPkcs8PrivateKey",
    [type[]]@(
      [byte[]],
      [ref].MakeByRefType()
    )
  )

  if ($null -ne $importMethod) {
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
      $bytesRead = 0
      $rsa.ImportPkcs8PrivateKey($privateKeyBytes, [ref]$bytesRead)
      $signatureBytes = $rsa.SignData(
        [System.Text.Encoding]::UTF8.GetBytes($message),
        [System.Security.Cryptography.HashAlgorithmName]::SHA512,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
      )
    } finally {
      $rsa.Dispose()
    }
  } else {
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rustore-sign-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
      $keyPath = Join-Path $tempDir "private-key.der"
      $messagePath = Join-Path $tempDir "message.txt"
      $signaturePath = Join-Path $tempDir "signature.bin"

      [System.IO.File]::WriteAllBytes($keyPath, $privateKeyBytes)
      [System.IO.File]::WriteAllBytes($messagePath, [System.Text.Encoding]::UTF8.GetBytes($message))

      $openssl = Get-Command "openssl" -ErrorAction SilentlyContinue
      if ($null -eq $openssl) {
        throw "OpenSSL not found in PATH and current PowerShell runtime does not support ImportPkcs8PrivateKey."
      }

      $opensslOutput = & $openssl.Source dgst -sha512 -sign $keyPath -keyform DER -out $signaturePath $messagePath 2>&1
      if ($LASTEXITCODE -ne 0) {
        throw "OpenSSL signing failed: $opensslOutput"
      }

      $signatureBytes = [System.IO.File]::ReadAllBytes($signaturePath)
    } finally {
      if (Test-Path $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
      }
    }
  }

  return @{
    keyId = $KeyId
    timestamp = $timestamp
    signature = [Convert]::ToBase64String($signatureBytes)
  }
}

function Invoke-RuStoreJsonRequest(
  [string]$Method,
  [string]$Uri,
  [hashtable]$Headers,
  $Body = $null
) {
  $params = @{
    Method = $Method
    Uri = $Uri
    Headers = $Headers
    ContentType = "application/json"
  }
  if ($null -ne $Body) {
    $params.Body = ($Body | ConvertTo-Json -Depth 10)
  }
  return Invoke-RestMethod @params
}

function Invoke-RuStoreFileUpload(
  [string]$Uri,
  [string]$Token,
  [string]$FilePath
) {
  $httpClient = [System.Net.Http.HttpClient]::new()
  try {
    $httpClient.DefaultRequestHeaders.Add("Public-Token", $Token)
    $multipart = [System.Net.Http.MultipartFormDataContent]::new()
    $stream = [System.IO.File]::OpenRead($FilePath)
    try {
      $fileContent = [System.Net.Http.StreamContent]::new($stream)
      $fileContent.Headers.ContentType =
          [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse(
            "application/octet-stream"
          )
      $multipart.Add(
        $fileContent,
        "file",
        [System.IO.Path]::GetFileName($FilePath)
      )
      $response = $httpClient.PostAsync($Uri, $multipart).GetAwaiter().GetResult()
      $responseBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      if (-not $response.IsSuccessStatusCode) {
        throw "RuStore upload failed: HTTP $($response.StatusCode)`n$responseBody"
      }
      return $responseBody | ConvertFrom-Json
    } finally {
      $stream.Dispose()
      $multipart.Dispose()
    }
  } finally {
    $httpClient.Dispose()
  }
}

if (-not (Test-Path $ArtifactPath)) {
  throw "Artifact not found: $ArtifactPath"
}

$artifactFullPath = (Resolve-Path $ArtifactPath).Path
$artifactExtension = [System.IO.Path]::GetExtension($artifactFullPath).ToLowerInvariant()
if ($artifactExtension -notin @(".aab", ".apk")) {
  throw "Unsupported artifact type: $artifactExtension"
}

$keyId = Get-RequiredEnv "RUSTORE_KEY_ID"
$privateKeyBase64 = Get-RequiredEnv "RUSTORE_PRIVATE_KEY_BASE64"
$signaturePayload = New-RuStoreSignaturePayload `
  -KeyId $keyId `
  -PrivateKeyBase64 $privateKeyBase64
$whatsNewText = Get-WhatsNewText

$authResponse = Invoke-RuStoreJsonRequest `
  -Method "POST" `
  -Uri "https://public-api.rustore.ru/public/auth" `
  -Headers @{} `
  -Body $signaturePayload

if ($authResponse.code -ne "OK" -or
    [string]::IsNullOrWhiteSpace($authResponse.body.jwe)) {
  throw "Failed to obtain RuStore API token: $($authResponse | ConvertTo-Json -Depth 10)"
}

$token = $authResponse.body.jwe
$headers = @{
  "Public-Token" = $token
}
$draftBody = @{
  minAndroidVersion = $MinAndroidVersion
  whatsNew = $whatsNewText
}

if (-not [string]::IsNullOrWhiteSpace($AppName)) {
  $draftBody.appName = $AppName
}

if (-not [string]::IsNullOrWhiteSpace($AppType)) {
  if ($AppType -notin @("MAIN", "GAMES")) {
    throw "Unsupported AppType: $AppType"
  }
  $draftBody.appType = $AppType
}

if (-not [string]::IsNullOrWhiteSpace($PublishType)) {
  if ($PublishType -notin @("MANUAL", "INSTANTLY", "DELAYED")) {
    throw "Unsupported PublishType: $PublishType"
  }
  $draftBody.publishType = $PublishType
}

if (-not [string]::IsNullOrWhiteSpace($ModeratorComment)) {
  $draftBody.moderInfo = $ModeratorComment
}

$draftResponse = Invoke-RuStoreJsonRequest `
  -Method "POST" `
  -Uri "https://public-api.rustore.ru/public/v1/application/$PackageName/version" `
  -Headers $headers `
  -Body $draftBody

if ($draftResponse.code -ne "OK") {
  throw "Failed to create RuStore draft: $($draftResponse | ConvertTo-Json -Depth 10)"
}

$versionId = if ($draftResponse.body -is [int] -or
                 $draftResponse.body -is [long] -or
                 $draftResponse.body -is [string]) {
  [string]$draftResponse.body
} else {
  [string]$draftResponse.body.versionId
}

if (-not $versionId) {
  throw "RuStore draft response does not contain versionId: $($draftResponse | ConvertTo-Json -Depth 10)"
}

$uploadEndpointSuffix = if ($artifactExtension -eq ".aab") {
  "aab"
} else {
  "apk"
}
$uploadResponse = Invoke-RuStoreFileUpload `
  -Uri "https://public-api.rustore.ru/public/v1/application/$PackageName/version/$versionId/$uploadEndpointSuffix" `
  -Token $token `
  -FilePath $artifactFullPath

if ($uploadResponse.code -ne "OK") {
  throw "Failed to upload artifact: $($uploadResponse | ConvertTo-Json -Depth 10)"
}

if ($SubmitForModeration) {
  $commitResponse = Invoke-RuStoreJsonRequest `
    -Method "POST" `
    -Uri "https://public-api.rustore.ru/public/v1/application/$PackageName/version/$versionId/commit?priorityUpdate=$PriorityUpdate" `
    -Headers $headers
  if ($commitResponse.code -ne "OK") {
    throw "Failed to submit draft for moderation: $($commitResponse | ConvertTo-Json -Depth 10)"
  }
}

Write-Host "RuStore draft created successfully."
Write-Host "Package: $PackageName"
Write-Host "Version ID: $versionId"
Write-Host "Artifact: $artifactFullPath"
Write-Host "Submitted for moderation: $($SubmitForModeration.IsPresent)"
