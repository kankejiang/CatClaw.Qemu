<#
.SYNOPSIS
  按 tools/assets.json 从 Release 下载并校验虚拟机套件的大件（不入 git 的部分）。

.DESCRIPTION
  流程：查本地缓存 → 命中且 SHA256 一致则直接用；否则从
  https://github.com/<Repo>/releases/download/<Tag>/<name> 下载 → 校验 SHA256 → 解压。
  校验失败会删除坏文件并终止（绝不把半个包解进输出目录）。

.EXAMPLE
  # 主程序构建前补齐 QEMU guest 运行时（解到 <Dest>\QemuGuest）
  pwsh tools/fetch-assets.ps1 -Dest ..\CatClawVideo\CatClawVideo.Maui

.EXAMPLE
  # guest 重建时取构建输入（解到指定目录）
  pwsh tools/fetch-assets.ps1 -Dest . -BuildInputsDest .\guest\qemu-src\blobs\astack
#>
[CmdletBinding()]
param(
    [string]$Repo = "kankejiang/CatClaw.Qemu",
    [string]$Tag = "vm-assets-v1",
    [Parameter(Mandatory = $true)][string]$Dest,
    [string]$Cache = (Join-Path $env:LOCALAPPDATA "CatClawQemuAssets"),
    [string]$BuildInputsDest = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $here "assets.json"
if (-not (Test-Path $manifestPath)) { throw "缺少清单：$manifestPath" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Write-Host "附件清单：$manifestPath（tag=$($manifest.tag)）"

function Get-AssetFile([string]$name, [int64]$size, [string]$sha256) {
    New-Item -ItemType Directory -Force -Path $Cache | Out-Null
    $cached = Join-Path $Cache $name
    if ((-not $Force) -and (Test-Path $cached)) {
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $cached).Hash.ToLower()
        if ($h -eq $sha256) { Write-Host "缓存命中：$name"; return $cached }
        Write-Host "缓存校验不符，重新下载：$name"
        Remove-Item -LiteralPath $cached -Force
    }
    $url = "https://github.com/$Repo/releases/download/$Tag/$name"
    Write-Host ("下载 {0}（{1:N1} MB）← {2}" -f $name, ($size / 1MB), $url)
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -L --fail --retry 3 -o $cached $url
        if ($LASTEXITCODE -ne 0) { throw "下载失败（curl 退出码 $LASTEXITCODE）：$url" }
    } else {
        Invoke-WebRequest -Uri $url -OutFile $cached -UseBasicParsing
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $cached).Hash.ToLower()
    if ($actual -ne $sha256) {
        Remove-Item -LiteralPath $cached -Force
        throw "SHA256 不匹配：$name（期望 $sha256，实际 $actual）—— 已删除坏文件"
    }
    Write-Host "校验通过：$name"
    return $cached
}

foreach ($a in $manifest.assets) {
    if ($a.name -eq "qemu-guest-win64.zip") {
        $file = Get-AssetFile $a.name $a.size $a.sha256
        $target = Join-Path $Dest "QemuGuest"
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Write-Host "解压 → $target"
        Expand-Archive -LiteralPath $file -DestinationPath $target -Force
    }
    elseif ($a.name -eq "guest-build-inputs.tar.gz") {
        if ([string]::IsNullOrWhiteSpace($BuildInputsDest)) { continue }
        $file = Get-AssetFile $a.name $a.size $a.sha256
        New-Item -ItemType Directory -Force -Path $BuildInputsDest | Out-Null
        Write-Host "解压 → $BuildInputsDest"
        tar -xzf $file -C $BuildInputsDest
    }
}

Write-Host ""
Write-Host "完成。QEMU 运行时目录：$(Join-Path $Dest 'QemuGuest')"
