# 纵横四海 · AI 设置窗口
# 启动前选择 AI 后端：本地 ollama / 联网模型（OpenAI 兼容）/ 关闭。
# 用法：
#   ai-setup.cmd                      打开设置窗口（可保存并重启游戏）
#   powershell -File ai-setup.ps1 -Mode Ask      启动流程里弹窗询问（保存后由调用方继续启动）
#   powershell -File ai-setup.ps1 -Mode TestOnly 不开界面，只按当前配置测连通性（排障用）
param(
  [ValidateSet('Settings', 'Ask', 'TestOnly')][string]$Mode = 'Settings'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ai-config.ps1')

# 云端基本都是 HTTPS，Windows PowerShell 5.1 默认不启用 TLS1.2
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$config = Get-AiConfig

# ---------- 连通性测试（GUI 按钮与 TestOnly 共用） ----------
function Test-AiConnection($mode, $ollamaUrl, $lightModel, $fastModel, $baseUrl, $apiKey, $cloudModel) {
  try {
    if ($mode -eq 'off') { return [pscustomobject]@{ ok = $true; message = '已选择关闭 AI：不会发出任何模型请求，全部走规则保底。' } }

    if ($mode -eq 'local') {
      $url = $ollamaUrl.TrimEnd('/')
      $autoNote = ''

      # 本机地址没在服务时先自动拉起 ollama：否则「测试连接」只会报“连不上”，
      # 而真实原因是 ollama 根本没启动（游戏启动器是在弹窗之后才兜底启动的）。
      if (Test-LocalOllamaUrl $url) {
        if (-not (Test-TcpPort (Get-OllamaPort $url))) {
          $probe = [pscustomobject]@{ mode = 'local'; local = [pscustomobject]@{ ollama_url = $url } }
          $state = Ensure-OllamaServer $probe
          switch ($state) {
            'started' { $autoNote = '（已自动启动本地 ollama）' }
            'not-installed' {
              return [pscustomobject]@{ ok = $false; message = "没找到 ollama 程序：E:\Ollama\ollama.exe`n先跑 ollama-install.cmd 装好，或改选「联网模型 / 关闭 AI」。" }
            }
            'failed' {
              return [pscustomobject]@{ ok = $false; message = "本地 ollama 启动了，但 12 秒内还没监听 $url。`n手动启动：E:\Ollama\ollama.exe serve（或从开始菜单打开 Ollama），再点「测试连接」。" }
            }
          }
        }
      }

      try {
        $resp = Invoke-RestMethod -Uri "$url/api/tags" -TimeoutSec 8
      } catch {
        return [pscustomobject]@{ ok = $false; message = "连接失败：$url 没有响应。`n确认 ollama 已启动、地址以 http:// 开头；远程服务请填对应主机地址。" }
      }

      $names = @($resp.models | ForEach-Object { $_.name } | Where-Object { $_ })
      # ollama 对不写 tag 的名字返回 :latest，比对时两边都补齐
      $known = @($names)
      foreach ($n in $names) { if ($n -notmatch ':') { $known += ($n + ':latest') } }

      if ($names.Count -eq 0) {
        return [pscustomobject]@{ ok = $false; message = "已连上 $url$autoNote，但里面一个模型都没有。`n先拉主模型：ollama pull $lightModel" }
      }

      $want = @($lightModel.Trim(), $fastModel.Trim()) | Where-Object { $_ } | Select-Object -Unique
      $missing = @($want | Where-Object { $known -notcontains $_ -and $known -notcontains ($_ + ':latest') })
      if ($missing.Count -gt 0) {
        $cmds = ($missing | ForEach-Object { "ollama pull $_" }) -join '；'
        return [pscustomobject]@{ ok = $false; message = "已连上 ollama$autoNote，但缺少模型：$($missing -join '、')`n补拉：$cmds`n现有：$($names -join '、')" }
      }
      return [pscustomobject]@{ ok = $true; message = "连接成功$autoNote，模型齐备：$($names -join '、')" }
    }

    $base = $baseUrl.TrimEnd('/')
    if (-not $apiKey) {
      return [pscustomobject]@{ ok = $false; message = '请填写 API Key：联网模型必须带 Key，否则服务端会直接返回 401。' }
    }

    # 先挡掉最常见的复制手误，省得对着 401 猜
    $keyHint = ''
    if ($apiKey -match '^\s*Bearer\s+') { $keyHint = 'Key 里带了「Bearer 」前缀，只保留 sk- 开头的部分。' }
    elseif ($apiKey -match '\s') { $keyHint = 'Key 里混入了空格或换行，重新复制一次（不要带引号）。' }
    elseif ($apiKey -notmatch '^sk-') { $keyHint = 'DeepSeek 的 Key 以 sk- 开头，当前值看起来不像（可能复制成了别的平台，或没复制全）。' }

    try {
      $resp = Invoke-RestMethod -Uri "$base/models" -Headers @{ Authorization = "Bearer $apiKey" } -TimeoutSec 12
    } catch {
      $status = $null
      try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch {}
      $body = ''
      try { if ($_.ErrorDetails.Message) { $body = ([string]$_.ErrorDetails.Message).Trim() } } catch {}
      switch ($status) {
        401 { $msg = '鉴权失败（401）：Key 无效、已被删除或已过期。到 platform.deepseek.com →「API Keys」重新创建，复制完整 sk-… 串再试。' }
        402 { $msg = '余额不足（402）：去 platform.deepseek.com 充值后再试。' }
        403 { $msg = '无权限（403）：这个 Key 没有该模型的权限，或账号受限。' }
        404 { $msg = '地址或模型不存在（404）：检查 Base URL（DeepSeek 用 https://api.deepseek.com/v1）与模型名。' }
        429 { $msg = '请求过于频繁（429）：稍后重试，或调大 ZHSH_AI_TICK_MS。' }
        default {
          if ($body) { $msg = "连接失败（HTTP $status）：$body" } else { $msg = "连接失败：$($_.Exception.Message)" }
        }
      }
      if ($keyHint) { $msg = "$keyHint`n$msg" }
      return [pscustomobject]@{ ok = $false; message = $msg }
    }

    $ids = @($resp.data | ForEach-Object { $_.id } | Where-Object { $_ })
    if ($ids.Count -eq 0) {
      return [pscustomobject]@{ ok = $true; message = "连接成功（该服务未列出模型清单）。请自行确认模型名「$cloudModel」正确。" }
    }
    if ($ids -notcontains $cloudModel) {
      return [pscustomobject]@{ ok = $false; message = "连接成功，但模型清单里没有「$cloudModel」。`n可用：$(($ids | Select-Object -First 10) -join '、')" }
    }
    return [pscustomobject]@{ ok = $true; message = "连接成功，模型「$cloudModel」可用。" }
  } catch {
    return [pscustomobject]@{ ok = $false; message = "连接失败：$($_.Exception.Message)" }
  }
}

# TestOnly：命令行直接看当前配置能不能用
if ($Mode -eq 'TestOnly') {
  $result = Test-AiConnection $config.mode $config.local.ollama_url $config.local.model_light `
    $config.local.model_fast $config.cloud.base_url $config.cloud.api_key $config.cloud.model
  $label = Get-AiModeLabel $config.mode
  Write-Output ("[{0}] {1}" -f $label, $result.message)
  exit ([int](-not $result.ok))
}

# ---------- 图形界面 ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:saved = $false
$global:ZHSH_AI_SETUP_RESULT = 'cancel'

$form = New-Object System.Windows.Forms.Form
$form.Text = '纵横四海 · AI 设置'
$form.ClientSize = New-Object System.Drawing.Size(600, 578)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $false
try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9) } catch {}

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '这一局用哪种 AI？'
$lblTitle.Location = New-Object System.Drawing.Point(18, 14)
$lblTitle.Size = New-Object System.Drawing.Size(560, 26)
$lblTitle.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 12, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblTitle)

$rbLocal = New-Object System.Windows.Forms.RadioButton
$rbLocal.Text = '本地模型（ollama）— 免费、可离线，需要本机算力'
$rbLocal.Location = New-Object System.Drawing.Point(22, 46)
$rbLocal.Size = New-Object System.Drawing.Size(540, 22)
$form.Controls.Add($rbLocal)

$rbCloud = New-Object System.Windows.Forms.RadioButton
$rbCloud.Text = '联网模型（OpenAI 兼容：DeepSeek / 通义 / Kimi / 智谱 …）— 按量计费'
$rbCloud.Location = New-Object System.Drawing.Point(22, 72)
$rbCloud.Size = New-Object System.Drawing.Size(555, 22)
$form.Controls.Add($rbCloud)

$rbOff = New-Object System.Windows.Forms.RadioButton
$rbOff.Text = '关闭 AI — 纯规则保底，零调用零费用（台词/叙述为固定文案）'
$rbOff.Location = New-Object System.Drawing.Point(22, 98)
$rbOff.Size = New-Object System.Drawing.Size(540, 22)
$form.Controls.Add($rbOff)

function Add-Row($group, $index, $labelText, $value, $isPassword) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $labelText
  $label.Location = New-Object System.Drawing.Point(14, (26 + $index * 30))
  $label.Size = New-Object System.Drawing.Size(96, 20)
  $group.Controls.Add($label)
  $box = New-Object System.Windows.Forms.TextBox
  $box.Location = New-Object System.Drawing.Point(112, (23 + $index * 30))
  $box.Size = New-Object System.Drawing.Size(410, 22)
  $box.Text = $value
  if ($isPassword) { $box.UseSystemPasswordChar = $true }
  $group.Controls.Add($box)
  return $box
}

$gbLocal = New-Object System.Windows.Forms.GroupBox
$gbLocal.Text = '本地 ollama 参数'
$gbLocal.Location = New-Object System.Drawing.Point(18, 126)
$gbLocal.Size = New-Object System.Drawing.Size(560, 150)
$form.Controls.Add($gbLocal)
$txtOllama = Add-Row $gbLocal 0 'Ollama 地址' $config.local.ollama_url $false
$txtLight = Add-Row $gbLocal 1 '主模型' $config.local.model_light $false
$txtFast = Add-Row $gbLocal 2 '快模型' $config.local.model_fast $false

# 明确告知本地模型的体积落在哪：这是唯一会让 C 盘突然多出几 GB 的地方
# 若 OLLAMA_MODELS 已指向非系统盘，就直接显示实际目录，避免用户以为还在 C 盘。
$modelDir = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User')
if (-not $modelDir) { $modelDir = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'Machine') }
if (-not $modelDir) { $modelDir = $env:OLLAMA_MODELS }
$lblLocalHint = New-Object System.Windows.Forms.Label
if ($modelDir) {
  $lblLocalHint.Text = "模型目录：$modelDir（已不在系统盘）。安装/重启 ollama 后，新下载的模型会存到这里。"
  $lblLocalHint.ForeColor = [System.Drawing.Color]::FromArgb(0, 110, 60)
} else {
  $lblLocalHint.Text = "模型文件默认在 C:\Users\<你>\.ollama\models，通常数 GB。想放别的盘：先 setx OLLAMA_MODELS `"E:\ollama-models`"，再重启 ollama。"
  $lblLocalHint.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
}
$lblLocalHint.Location = New-Object System.Drawing.Point(14, 114)
$lblLocalHint.Size = New-Object System.Drawing.Size(530, 32)
try { $lblLocalHint.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 8) } catch {}
$gbLocal.Controls.Add($lblLocalHint)

$gbCloud = New-Object System.Windows.Forms.GroupBox
$gbCloud.Text = '联网模型参数（OpenAI 兼容）'
$gbCloud.Location = New-Object System.Drawing.Point(18, 286)
$gbCloud.Size = New-Object System.Drawing.Size(560, 122)
$form.Controls.Add($gbCloud)
$txtBase = Add-Row $gbCloud 0 'Base URL' $config.cloud.base_url $false
$txtKey = Add-Row $gbCloud 1 'API Key' $config.cloud.api_key $true
$txtModel = Add-Row $gbCloud 2 '模型名' $config.cloud.model $false

$chkAsk = New-Object System.Windows.Forms.CheckBox
$chkAsk.Text = '每次启动都询问我（不勾选则直接用上面的设置启动）'
$chkAsk.Location = New-Object System.Drawing.Point(22, 416)
$chkAsk.Size = New-Object System.Drawing.Size(540, 22)
$chkAsk.Checked = [bool]$config.ask_on_start
$form.Controls.Add($chkAsk)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(22, 442)
$lblStatus.Size = New-Object System.Drawing.Size(556, 60)
$lblStatus.Text = '建议先点「测试连接」确认配置可用，再保存。'
$form.Controls.Add($lblStatus)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = '测试连接'
$btnTest.Location = New-Object System.Drawing.Point(20, 512)
$btnTest.Size = New-Object System.Drawing.Size(100, 32)
$form.Controls.Add($btnTest)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = '仅保存'
$btnSave.Location = New-Object System.Drawing.Point(132, 512)
$btnSave.Size = New-Object System.Drawing.Size(100, 32)
$form.Controls.Add($btnSave)

$btnPrimary = New-Object System.Windows.Forms.Button
$btnPrimary.Location = New-Object System.Drawing.Point(244, 512)
$btnPrimary.Size = New-Object System.Drawing.Size(180, 32)
$form.Controls.Add($btnPrimary)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = '取消'
$btnCancel.Location = New-Object System.Drawing.Point(478, 512)
$btnCancel.Size = New-Object System.Drawing.Size(100, 32)
$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($btnCancel)
$form.CancelButton = $btnCancel

function Get-SelectedMode {
  if ($rbCloud.Checked) { return 'cloud' }
  if ($rbOff.Checked) { return 'off' }
  return 'local'
}

function Set-SelectedMode($mode) {
  $rbLocal.Checked = ($mode -eq 'local')
  $rbCloud.Checked = ($mode -eq 'cloud')
  $rbOff.Checked = ($mode -eq 'off')
}

function Update-Enabled {
  $mode = Get-SelectedMode
  $gbLocal.Enabled = ($mode -eq 'local')
  $gbCloud.Enabled = ($mode -eq 'cloud')
}

function Read-FormConfig {
  return [pscustomobject]@{
    mode         = Get-SelectedMode
    ask_on_start = [bool]$chkAsk.Checked
    local        = [pscustomobject]@{
      ollama_url  = $txtOllama.Text.Trim()
      model_light = $txtLight.Text.Trim()
      model_fast  = $txtFast.Text.Trim()
    }
    cloud        = [pscustomobject]@{
      base_url = $txtBase.Text.Trim()
      api_key  = $txtKey.Text.Trim()
      model    = $txtModel.Text.Trim()
    }
  }
}

function Show-Status($ok, $message) {
  $lblStatus.ForeColor = if ($ok) { [System.Drawing.Color]::FromArgb(0, 110, 60) } else { [System.Drawing.Color]::FromArgb(170, 30, 30) }
  $lblStatus.Text = $message
}

# 保存前的输入校验
function Test-FormValid($cfg) {
  if ($cfg.mode -eq 'local') {
    if (-not $cfg.local.ollama_url) { return '请填写 Ollama 地址。' }
    if (-not $cfg.local.model_light) { return '请填写主模型名。' }
  }
  if ($cfg.mode -eq 'cloud') {
    if (-not $cfg.cloud.base_url) { return '请填写联网服务的 Base URL。' }
    if (-not $cfg.cloud.model) { return '请填写模型名。' }
    if (-not $cfg.cloud.api_key) { return '请填写 API Key（否则请求会被鉴权拒绝）。' }
  }
  return $null
}

function Stop-GameServer {
  try {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop |
      Where-Object { $_.CommandLine -match 'server[\\/]server\.js' } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } catch {}
  Start-Sleep -Milliseconds 900
}

function Start-GameTray {
  $vbs = Join-Path $PSScriptRoot '启动游戏.vbs'
  if (Test-Path $vbs) { Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`"" }
}

# 模式差异：Ask = 启动流程中询问（保存后交给调用方继续启动）；Settings = 独立设置窗口（可保存并重启游戏）
if ($Mode -eq 'Ask') {
  $btnSave.Visible = $false
  $btnPrimary.Text = '开始游戏'
  $btnPrimary.Location = New-Object System.Drawing.Point(132, 512)
  $btnPrimary.Size = New-Object System.Drawing.Size(140, 32)
} else {
  $btnPrimary.Text = '保存并重启游戏'
}

Set-SelectedMode $config.mode
Update-Enabled

# 窗口一打开就预热本地 ollama：拉起进程要几秒，等用户点「测试连接」时通常已经在服务了。
# 只拉起、不等待，失败也不打扰（点测试时 Test-AiConnection 还会再兜底一次）。
if ($config.mode -eq 'local' -and (Test-LocalOllamaUrl $config.local.ollama_url)) {
  try { [void](Start-OllamaServe $config) } catch {}
}

$rbLocal.Add_CheckedChanged({ Update-Enabled })
$rbCloud.Add_CheckedChanged({ Update-Enabled })
$rbOff.Add_CheckedChanged({ Update-Enabled })

$btnTest.Add_Click({
    $cfg = Read-FormConfig
    Show-Status $true '正在测试…'
    $form.Refresh()
    $r = Test-AiConnection $cfg.mode $cfg.local.ollama_url $cfg.local.model_light $cfg.local.model_fast `
      $cfg.cloud.base_url $cfg.cloud.api_key $cfg.cloud.model
    Show-Status $r.ok $r.message
  })

$save = {
  param([bool]$restart)
  $cfg = Read-FormConfig
  $problem = Test-FormValid $cfg
  if ($problem) { Show-Status $false $problem; return }
  try {
    Save-AiConfig $cfg
  } catch {
    Show-Status $false "保存失败：$($_.Exception.Message)"
    return
  }
  $script:saved = $true
  $global:ZHSH_AI_SETUP_RESULT = 'ok'
  if ($restart) {
    Stop-GameServer
    Start-GameTray
  }
  $form.Close()
}

$btnSave.Add_Click({ & $save $false })

$btnPrimary.Add_Click({
    if ($Mode -eq 'Ask') { & $save $false } else { & $save $true }
  })

[void]$form.ShowDialog()

if (-not $script:saved) { $global:ZHSH_AI_SETUP_RESULT = 'cancel' }
