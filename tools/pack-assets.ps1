<#
.SYNOPSIS
  打包虚拟机套件的 Release 附件（大二进制不入 git，改由 Release 分发）。

.DESCRIPTION
  产物（默认输出到 -OutDir）：
    qemu-guest-win64.zip      运行时载荷：qemu-system-x86_64.exe + 依赖 DLL + share/ + x86guest 内核与 initrd
    guest-build-inputs.tar.gz guest 重建用的构建输入（android-stack.tar.gz 等）
    assets.json               名称/大小/SHA256 —— 入库，供 fetch-assets.ps1 校验下载物

  排除清单必须与主仓库 CatClawVideo.Maui.csproj 的 <Content Remove> 保持一致：
    aarch64 线退役件（qemu-system-aarch64.exe / art_initrd*.gz / pkg_*）、
    x86guest 出包实验件（bootimg 系列），以及本机的镜像分片与备份（*.gz.a1|a2 / *.bak_cpu）——
    后者是当初为绕开 GitHub 单文件限制切出来的分片，纯垃圾，绝不能随包（曾白拷 1.2GB 进输出目录）。

.EXAMPLE
  pwsh tools/pack-assets.ps1 -QemuGuestDir <主仓库 QemuGuest 目录> -OutDir .\_assets
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$QemuGuestDir,
    [string[]]$BuildInputs = @(),
    [string]$OutDir = ".\_assets",
    [string]$Tag = "vm-assets-v1"
)

$ErrorActionPreference = "Stop"
$excludeNames = @(
    # aarch64 线退役（2026-09-29）
    "qemu-system-aarch64.exe", "art_initrd.gz", "art_initrd_merged.gz", "pkg_kernel", "pkg_initrd.gz",
    # x86guest 出包实验件（构建期输入，运行时不需要）
    "art_initrd_x64_bootimg.gz", "art_initrd_x64_pristine.gz", "bootimg_artifacts.cpio.gz", "thunder_assets.cpio.gz",
    # 本机镜像分片/备份（垃圾，必须排除）
    "art_initrd_x64.gz.a1", "art_initrd_x64.gz.a2", "art_initrd_x64.gz.bak_cpu"
)

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stage = Join-Path $OutDir "_stage\QemuGuest"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$copied = 0; $bytes = 0
$rootLen = (Resolve-Path $QemuGuestDir).Path.Length
Get-ChildItem -LiteralPath $QemuGuestDir -Recurse -File | ForEach-Object {
    if ($excludeNames -contains $_.Name) { return }
    $rel = $_.FullName.Substring($rootLen).TrimStart("\")
    $dst = Join-Path $stage $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
    $copied++; $bytes += $_.Length
}
Write-Host ("运行时载荷：{0} 个文件 / {1:N1} MB" -f $copied, ($bytes / 1MB))

$zip = Join-Path $OutDir "qemu-guest-win64.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -CompressionLevel Fastest
Write-Host ("打包 {0}（{1:N1} MB）" -f (Split-Path $zip -Leaf), ((Get-Item $zip).Length / 1MB))

$tarPath = Join-Path $OutDir "guest-build-inputs.tar.gz"
if ($BuildInputs.Count -gt 0) {
    if (Test-Path $tarPath) { Remove-Item -Force $tarPath }
    tar -czf $tarPath @BuildInputs
    Write-Host ("打包 {0}（{1:N1} MB）" -f "guest-build-inputs.tar.gz", ((Get-Item $tarPath).Length / 1MB))
}

$list = @()
foreach ($f in @($zip, $tarPath)) {
    if (Test-Path $f) {
        $list += [ordered]@{
            name   = (Split-Path $f -Leaf)
            size   = (Get-Item $f).Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash.ToLower()
            tag    = $Tag
        }
    }
}
$json = [ordered]@{ generated = (Get-Date -Format s); tag = $Tag; assets = $list } | ConvertTo-Json -Depth 5
Set-Content -LiteralPath (Join-Path $OutDir "assets.json") -Value $json -Encoding utf8

Write-Host ""
Write-Host "附件清单："
$list | ForEach-Object { Write-Host ("  {0}  {1:N1} MB  {2}" -f $_.name, ($_.size / 1MB), $_.sha256) }
Write-Host ""
Write-Host "下一步：gh release create $Tag --repo kankejiang/CatClaw.Qemu --title <标题> --notes <说明> <附件>"
Write-Host "并把 assets.json 提交进仓库（fetch-assets.ps1 按它校验）。"
