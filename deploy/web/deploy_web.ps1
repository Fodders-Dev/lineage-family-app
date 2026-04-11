param(
    [string]$Host = "212.69.84.167",
    [string]$User = "rodnya-deploy",
    [string]$TargetDir = "/var/www/rodnya-site",
    [string]$RemoteScriptPath = "/usr/local/bin/rodnya-activate-web-release",
    [string]$RemoteUploadDir = "/tmp",
    [string]$IdentityFile,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')"
    }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\\..")
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$archivePath = Join-Path $env:TEMP "rodnya-site-$timestamp.tgz"

Push-Location $repoRoot
try {
    if (-not $SkipBuild) {
        Invoke-Checked "flutter" @("pub", "get")
        Invoke-Checked "flutter" @(
            "build",
            "web",
            "--release",
            "--dart-define=LINEAGE_RUNTIME_PRESET=prod_custom_api",
            "--dart-define=LINEAGE_ENABLE_LEGACY_DYNAMIC_LINKS=false"
        )
    }

    if (Test-Path $archivePath) {
        Remove-Item $archivePath -Force
    }

    Push-Location (Join-Path $repoRoot "build\\web")
    try {
        Invoke-Checked "tar.exe" @("-czf", $archivePath, ".")
    } finally {
        Pop-Location
    }

    $gitSha = (& git rev-parse --short HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to resolve git revision"
    }

    $dirtyTree = if ((& git status --porcelain).Trim()) { "dirty-tree-web-build" } else { "clean-tree-web-build" }
    $buildLabel = "deploy $(Get-Date -Format 'yyyy-MM-dd HH:mm zzz') / git $gitSha / $dirtyTree"
    $remoteArchive = "$RemoteUploadDir/rodnya-site-$timestamp.tgz"

    $sshArgs = @()
    if ($IdentityFile) {
        $sshArgs += @("-i", $IdentityFile)
    }

    Invoke-Checked "scp" ($sshArgs + @($archivePath, "${User}@${Host}:$remoteArchive"))

    $escapedLabel = $buildLabel.Replace("'", "'`"'`"'")
    $remoteCommand = "BUILD_LABEL='$escapedLabel' sudo '$RemoteScriptPath' '$remoteArchive' '$TargetDir' && rm -f '$remoteArchive'"
    Invoke-Checked "ssh" ($sshArgs + @("${User}@${Host}", $remoteCommand))
} finally {
    Pop-Location
}
