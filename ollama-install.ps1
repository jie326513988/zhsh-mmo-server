# 纵横四海 · 把 Ollama 装到 E 盘（断点续传版）
#
# 为什么不用官方 install.ps1：它把 1.56GB 的安装包下到 %TEMP%（C 盘），
# 且不支持断点续传 —— 慢速网络下中断一次就从头再来。本脚本：
#   1) 下到 E:\ollama-install-temp，支持 Range 续传，随时 Ctrl+C 下次接着下
#   2) 用 Authenticode 校验数字签名（走任何镜像/代理都安全，被改过会失败）
#   3) /DIR= 静默安装到 E:\Ollama，不写 C 盘
#
# 用法：双击 ollama-install.cmd，或 powershell -File ollama-install.ps1
param(
  [string]$InstallDir = 'E:\Ollama',
  [string]$ModelDir   = 'E:\ollama-models',
  [string]$TempDir    = 'E:\ollama-install-temp'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 源按速度从快到慢尝试（本机实测 GitHub 比 ollama.com 快 3 倍）
$Sources = @(
  'https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe',
  'https://ollama.com/download/OllamaSetup.exe'
)

$dest = Join-Path $TempDir 'OllamaSetup.exe'

function Write-Header($text) { Write-Host ''; Write-Host "=== $text ===" -ForegroundColor Cyan }
function Format-Size($bytes) {
  if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
  if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
  return ('{0:N0} KB' -f ($bytes / 1KB))
}

# ---------- 1. 取文件总大小 ----------
# HEAD 在慢速网络上容易超时（GitHub 先走重定向），失败则退化为 Range 探测，
# 再失败返回 0 —— 下载照样进行，只是没有百分比进度。
function Get-RemoteSize($url) {
  try {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'HEAD'
    $req.Timeout = 45000
    $req.UserAgent = 'Mozilla/5.0'
    $resp = $req.GetResponse()
    $size = $resp.ContentLength
    $resp.Close()
    if ($size -gt 0) { return $size }
  } catch { }

  try {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Timeout = 45000
    $req.ReadWriteTimeout = 45000
    $req.AddRange(0, 0)
    $req.UserAgent = 'Mozilla/5.0'
    $resp = $req.GetResponse()
    $range = $resp.Headers['Content-Range']
    $resp.Close()
    if ("$range" -match '/(\d+)\s*$') { return [int64]$Matches[1] }
  } catch { }

  return 0
}

# ---------- 2. 断点续传下载 ----------
function Get-FileWithResume($url, $path, $totalSize) {
  $attempt = 0
  while ($true) {
    $have = if (Test-Path $path) { (Get-Item $path).Length } else { 0 }
    if ($totalSize -gt 0 -and $have -ge $totalSize) { return $true }

    $attempt += 1
    if ($attempt -gt 30) { throw "连续重试 30 次仍失败，请检查网络后重新运行（已下载部分会保留）" }

    try {
      $req = [System.Net.HttpWebRequest]::Create($url)
      $req.Timeout = 30000
      $req.ReadWriteTimeout = 60000
      $req.UserAgent = 'Mozilla/5.0'
      if ($have -gt 0) { $req.AddRange($have) }
      $resp = $req.GetResponse()

      # 服务器不支持 Range 时会回 200 全量，此时必须从头写，否则文件会拼坏
      $mode = [System.IO.FileMode]::Append
      if ($req.Headers['Range'] -and [int]$resp.StatusCode -ne 206) {
        Write-Host '  该源不支持断点续传，从 0 重新下载…' -ForegroundColor Yellow
        $have = 0
        $mode = [System.IO.FileMode]::Create
      }

      $fs = New-Object System.IO.FileStream($path, $mode, [System.IO.FileAccess]::Write)
      $stream = $resp.GetResponseStream()
      $buf = New-Object byte[] 131072
      $sessionStart = [DateTime]::UtcNow
      $sessionBytes = 0
      $lastReport = [DateTime]::UtcNow

      while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
        $fs.Write($buf, 0, $n)
        $have += $n
        $sessionBytes += $n
        if ((([DateTime]::UtcNow) - $lastReport).TotalSeconds -ge 3) {
          $lastReport = [DateTime]::UtcNow
          $secs = [Math]::Max(0.1, (([DateTime]::UtcNow) - $sessionStart).TotalSeconds)
          $speed = $sessionBytes / $secs
          if ($totalSize -gt 0) {
            $pct = [Math]::Round(100.0 * $have / $totalSize, 1)
            $eta = if ($speed -gt 1024) { [TimeSpan]::FromSeconds(($totalSize - $have) / $speed) } else { [TimeSpan]::Zero }
            Write-Host ("  {0,5}%  {1} / {2}  {3}/s  剩余约 {4:hh\:mm\:ss}" -f $pct, (Format-Size $have), (Format-Size $totalSize), (Format-Size $speed), $eta)
          } else {
            Write-Host ("  {0}  {1}/s" -f (Format-Size $have), (Format-Size $speed))
          }
        }
      }
      $stream.Close(); $fs.Close(); $resp.Close()

      if ($totalSize -eq 0 -or $have -ge $totalSize) { return $true }
      Write-Host '  连接中断，正在续传…' -ForegroundColor Yellow
      Start-Sleep -Seconds 2
    } catch {
      Write-Host "  下载出错：$($_.Exception.Message)" -ForegroundColor Yellow
      Write-Host '  3 秒后重试（已下载部分保留）…'
      Start-Sleep -Seconds 3
    }
  }
}

# ---------- 主流程 ----------
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null

Write-Header 'Ollama 安装器（装到 E 盘，可断点续传）'
Write-Host "  程序目录：$InstallDir"
Write-Host "  模型目录：$ModelDir"
Write-Host "  临时目录：$TempDir"
Write-Host '  提示：可随时 Ctrl+C，下次运行会接着已下载的部分继续。'

foreach ($dir in @($InstallDir, $ModelDir, $TempDir)) {
  if (-not $dir.StartsWith('E:\', [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "警告：$dir 不在 E 盘" -ForegroundColor Yellow
  }
}

Write-Header '第 1 步 / 3：下载安装包'
$totalSize = 0
$chosen = $null
foreach ($source in $Sources) {
  try {
    Write-Host "  探测源：$source"
    $totalSize = Get-RemoteSize $source
    if ($totalSize -gt 0) { $chosen = $source; break }
  } catch { Write-Host "  不可用：$($_.Exception.Message)" -ForegroundColor Yellow }
}
if (-not $chosen) { throw '所有下载源都不可用，请检查网络/代理设置' }
Write-Host ('  文件大小：{0}' -f (Format-Size $totalSize))
[void](Get-FileWithResume $chosen $dest $totalSize)
Write-Host '  下载完成' -ForegroundColor Green

Write-Header '第 2 步 / 3：校验数字签名'
$sig = Get-AuthenticodeSignature $dest
if ($sig.Status -ne 'Valid') {
  throw "数字签名无效（状态：$($sig.Status)）。文件可能被篡改或下载不完整，已中止安装。"
}
Write-Host ("  签名有效：{0}" -f ($sig.SignerCertificate.Subject -split ',')[0]) -ForegroundColor Green

Write-Header '第 3 步 / 3：静默安装到 E 盘'
$installerArgs = "/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /DIR=`"$InstallDir`""
Write-Host "  安装参数：$installerArgs"
# 注意：不能用 -Wait。安装器结束时会自己拉起托盘程序 ollama app.exe，
# PowerShell 的 -Wait 会连这个子进程一起等，导致脚本永久卡住（官方 install.ps1 同样规避了这点）。
$proc = Start-Process -FilePath $dest -ArgumentList $installerArgs -PassThru
$proc.WaitForExit()
if ($proc.ExitCode -ne 0) {
  throw "安装器返回错误码 $($proc.ExitCode)。若提示权限不足，请右键以管理员身份运行 ollama-install.cmd。"
}
Start-Sleep -Seconds 2

# 设置模型目录（若尚未设置）
$current = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User')
if ($current -ne $ModelDir) {
  [Environment]::SetEnvironmentVariable('OLLAMA_MODELS', $ModelDir, 'User')
  Write-Host "  已设置 OLLAMA_MODELS=$ModelDir（需重启 ollama 生效）" -ForegroundColor Green
} else {
  Write-Host "  OLLAMA_MODELS 已是 $ModelDir" -ForegroundColor Green
}

# 重启 ollama：安装器刚拉起的那个进程继承的是安装器自己的旧环境，
# 若不重启，拉模型仍会落到 C:\Users\<你>\.ollama\models。
$env:OLLAMA_MODELS = $ModelDir
Get-Process -Name 'ollama app', 'ollama', 'ollama_llama_server' -ErrorAction SilentlyContinue |
  Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$appExe = Join-Path $InstallDir 'ollama app.exe'
if (Test-Path $appExe) {
  Start-Process -FilePath $appExe | Out-Null
  Write-Host '  已用新的模型目录重启 ollama' -ForegroundColor Green
  Start-Sleep -Seconds 3
}

$exe = Join-Path $InstallDir 'ollama.exe'
if (Test-Path $exe) {
  $ver = & $exe --version 2>&1
  Write-Header '安装成功'
  Write-Host "  程序：$exe" -ForegroundColor Green
  Write-Host "  版本：$ver"
  Write-Host ''
  Write-Host '  下一步：'
  Write-Host '    1) 从开始菜单启动 Ollama（或运行 ollama app.exe），它会常驻托盘并在 11434 端口提供服务'
  Write-Host '    2) 拉取模型：ollama pull qwen3.5:4b'
  Write-Host "    3) 确认模型落在 E 盘：dir $ModelDir\blobs"
  Write-Host ''
  Write-Host "  安装包仍保留在 $dest（$(Format-Size (Get-Item $dest).Length)），确认可用后可删除。"
} else {
  throw "安装流程结束但未找到 $exe，请检查安装日志。"
}
