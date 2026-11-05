$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:server = Join-Path $script:root 'server'
$script:serverJs = Join-Path $script:server 'server.js'
$script:lock = Join-Path $script:server 'data' '.zhsh-game-server.lock'
$script:port = 4173
$script:localUrl = "http://127.0.0.1:$script:port/"

$script:mutex = New-Object System.Threading.Mutex($false, 'ZHSH_GAME_TRAY')
if (-not $script:mutex.WaitOne(0)) {
  Start-Process $script:localUrl
  exit
}

# ---- AI 后端选择：启动前确定（本地 ollama / 联网模型 / 关闭） ----
# 顶层要求：AI 的 provider 与模型名都是服务器进程启动时读取的，所以必须在这里定好再起 node。
. (Join-Path $script:root 'ai-config.ps1')
$script:aiConfig = Get-AiConfig
if ($script:aiConfig.ask_on_start) {
  & (Join-Path $script:root 'ai-setup.ps1') -Mode Ask
  if ($global:ZHSH_AI_SETUP_RESULT -eq 'cancel') {
    $script:notify = $null
    $script:mutex.ReleaseMutex()
    exit
  }
  $script:aiConfig = Get-AiConfig
}
Set-AiEnv $script:aiConfig
$script:aiModeLabel = Get-AiModeLabel $script:aiConfig.mode
# 本地模式：确保 ollama 已在服务。Ollama 托盘程序在异常退出后可能不再拉起 server，
# 这里直接兜底启动，避免"本地模型"静默退化成规则保底。
$script:ollamaState = Ensure-OllamaServer $script:aiConfig

function Read-LockPid {
  if (Test-Path $script:lock) {
    try { return [int]((Get-Content $script:lock -Raw | ConvertFrom-Json).pid) } catch { return $null }
  }
  return $null
}

function Get-ServerPid {
  # 先看 lock 文件；server.js 目前并不写 lock，所以命令行匹配才是实际生效的那条路
  $candidate = Read-LockPid
  if ($candidate) {
    if (Get-Process -Id $candidate -ErrorAction SilentlyContinue) { return $candidate }
  }
  try {
    $proc = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -match 'server[\\/]server\.js' } |
      Select-Object -First 1
    if ($proc) { return [int]$proc.ProcessId }
  } catch { }
  return $null
}

function Ensure-FirewallRule {
  # 放行 4173 只对"局域网其他设备访问"有必要；本机游玩不需要。
  # 注意不能带 -Wait：写防火墙规则需要管理员，等待会让启动流程卡在 UAC 弹窗上，
  # 用户不点就一直起不来。这里改为"发起后立即继续"，授权成功与否都不影响本机启动。
  netsh advfirewall firewall show rule name="Zhsh Game Server" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    try {
      Start-Process -FilePath 'netsh' -ArgumentList 'advfirewall','firewall','add','rule','name=Zhsh Game Server','dir=in','action=allow','protocol=TCP','localport=4173' -Verb RunAs -WindowStyle Hidden
    } catch { }
  }
}

function Start-Server {
  if (Get-ServerPid) { return }
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { $script:notify.ShowBalloonTip(5000, '纵横四海', '未找到 Node.js，请安装 Node.js 22 或更高版本。', [System.Windows.Forms.ToolTipIcon]::Error); return }
  Start-Process -FilePath $node.Source -ArgumentList "`"$script:serverJs`"" -WorkingDirectory $script:root -WindowStyle Hidden
  for ($i = 0; $i -lt 30; $i++) { if (Get-ServerPid) { break }; Start-Sleep -Milliseconds 200 }
  if (-not (Get-ServerPid)) {
    $script:notify.ShowBalloonTip(5000, '纵横四海', '服务器启动失败（端口可能被占用）。', [System.Windows.Forms.ToolTipIcon]::Warning)
  }
}

function Stop-Server {
  $serverPid = Get-ServerPid
  if ($serverPid) {
    Stop-Process -Id $serverPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
    if (Test-Path $script:lock) { Remove-Item $script:lock -Force -ErrorAction SilentlyContinue }
  }
}

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Text = "纵横四海 · $($script:aiModeLabel)"
$script:notify.Icon = [System.Drawing.SystemIcons]::Application
$script:notify.Visible = $true

if ($script:aiConfig.mode -eq 'local' -and $script:ollamaState -eq 'failed') {
  $script:notify.ShowBalloonTip(6000, '纵横四海', '本地 ollama 未能启动，AI 将走规则保底。可在「AI 设置」里改用联网模型。', [System.Windows.Forms.ToolTipIcon]::Warning)
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = New-Object System.Windows.Forms.ToolStripMenuItem('打开游戏')
$aiItem = New-Object System.Windows.Forms.ToolStripMenuItem("AI 设置（当前：$($script:aiModeLabel)）")
$restartItem = New-Object System.Windows.Forms.ToolStripMenuItem('重启服务器')
$stopItem = New-Object System.Windows.Forms.ToolStripMenuItem('停止服务器')
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
[void]$menu.Items.Add($openItem)
[void]$menu.Items.Add($aiItem)
[void]$menu.Items.Add($restartItem)
[void]$menu.Items.Add($stopItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($exitItem)
$script:notify.ContextMenuStrip = $menu

$openItem.Add_Click({ Start-Process $script:localUrl })
$aiItem.Add_Click({
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $script:root 'ai-setup.ps1')`"", '-Mode', 'Settings'
  })
$restartItem.Add_Click({ Stop-Server; Start-Server })
$stopItem.Add_Click({ Stop-Server })
$exitItem.Add_Click({ Stop-Server; $script:notify.Visible = $false; $script:notify.Dispose(); [System.Windows.Forms.Application]::Exit() })
$script:notify.Add_DoubleClick({ Start-Process $script:localUrl })

Ensure-FirewallRule
Start-Server
[System.Windows.Forms.Application]::Run()
$script:mutex.ReleaseMutex()
