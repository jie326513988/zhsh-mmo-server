# 纵横四海 · AI 配置读写（供 ai-setup.ps1 与 游戏服务器.ps1 共用）
# 本文件只定义函数，不产生任何副作用；调用方用 . (dot-source) 方式引入。

function Get-AiConfigPath { Join-Path $PSScriptRoot 'ai-config.json' }

function New-DefaultAiConfig {
  return [pscustomobject]@{
    mode         = 'local'
    ask_on_start = $true
    local        = [pscustomobject]@{
      ollama_url  = 'http://127.0.0.1:11434'
      model_light = 'qwen3.5:4b'
      model_fast  = 'qwen3.5:2b'
    }
    cloud        = [pscustomobject]@{
      base_url = 'https://api.deepseek.com/v1'
      api_key  = ''
      model    = 'deepseek-chat'
    }
  }
}

function Get-Prop($object, $name, $default) {
  if ($null -eq $object) { return $default }
  $value = $object.$name
  if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) { return $default }
  return $value
}

# 读取配置；文件缺失/损坏/手改残缺时都能容错回落到默认值
function Get-AiConfig {
  $default = New-DefaultAiConfig
  $path = Get-AiConfigPath
  if (-not (Test-Path $path)) { return $default }
  try {
    $raw = Get-Content $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $default }
    $saved = $raw | ConvertFrom-Json
  } catch { return $default }

  $mode = [string](Get-Prop $saved 'mode' $default.mode)
  if ($mode -notin @('local', 'cloud', 'off')) { $mode = $default.mode }
  $ask = $saved.ask_on_start
  if ($null -eq $ask) { $ask = $default.ask_on_start }

  return [pscustomobject]@{
    mode         = $mode
    ask_on_start = [bool]$ask
    local        = [pscustomobject]@{
      ollama_url  = [string](Get-Prop $saved.local 'ollama_url' $default.local.ollama_url)
      model_light = [string](Get-Prop $saved.local 'model_light' $default.local.model_light)
      model_fast  = [string](Get-Prop $saved.local 'model_fast' $default.local.model_fast)
    }
    cloud        = [pscustomobject]@{
      base_url = [string](Get-Prop $saved.cloud 'base_url' $default.cloud.base_url)
      api_key  = [string](Get-Prop $saved.cloud 'api_key' '')
      model    = [string](Get-Prop $saved.cloud 'model' $default.cloud.model)
    }
  }
}

# 写配置（UTF-8 无 BOM，JSON 交给 Node/PS 都能直接读）
function Save-AiConfig($config) {
  $json = $config | ConvertTo-Json -Depth 6
  [System.IO.File]::WriteAllText((Get-AiConfigPath), $json, (New-Object System.Text.UTF8Encoding($false)))
}

# 把配置翻译成服务器进程的环境变量。
# 先清空同名变量，避免"改了模式但上一个模式的环境变量还残留"导致串档。
function Set-AiEnv($config) {
  foreach ($name in 'ZHSH_AI_PROVIDER', 'ZHSH_AI_BASE_URL', 'ZHSH_AI_API_KEY', 'ZHSH_AI_MODEL',
    'ZHSH_AI_MODEL_LIGHT', 'ZHSH_AI_MODEL_FAST', 'ZHSH_AI_DISABLED', 'ZHSH_OLLAMA_URL') {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
  }
  switch ($config.mode) {
    'off' {
      # 明确关闭：所有 AI 场景瞬时走规则保底，且不启动 AI 玩家
      $env:ZHSH_AI_DISABLED = '1'
    }
    'cloud' {
      $env:ZHSH_AI_PROVIDER = 'openai'
      $env:ZHSH_AI_BASE_URL = $config.cloud.base_url
      $env:ZHSH_AI_API_KEY = $config.cloud.api_key
      $env:ZHSH_AI_MODEL = $config.cloud.model
    }
    default {
      # local：不设 ZHSH_AI_PROVIDER，走默认 ollama 分支
      $env:ZHSH_OLLAMA_URL = $config.local.ollama_url
      $env:ZHSH_AI_MODEL_LIGHT = $config.local.model_light
      $env:ZHSH_AI_MODEL_FAST = $config.local.model_fast
    }
  }
}

function Get-AiModeLabel($mode) {
  switch ($mode) {
    'cloud' { return '联网模型' }
    'off' { return 'AI 关闭' }
    default { return '本地 ollama' }
  }
}

# 快速 TCP 探测（比 Test-NetConnection 快一个数量级，启动流程里不能用慢的那个）
function Test-TcpPort($port, $timeoutMs = 300) {
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect('127.0.0.1', $port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne($timeoutMs)
    if ($ok -and $client.Connected) { $client.Close(); return $true }
    $client.Close()
    return $false
  } catch { return $false }
}

# 从 ollama 地址里取端口，没写端口就是 11434
function Get-OllamaPort($ollamaUrl) {
  if ($ollamaUrl -match ':(\d+)') { return [int]$Matches[1] }
  return 11434
}

# 地址是否指向本机：只有本机才自动拉起 ollama；填了别的机器就当成远程服务，不去动本机进程
function Test-LocalOllamaUrl($ollamaUrl) {
  return [bool]($ollamaUrl -match '^https?://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?/?$')
}

<#
  只把 ollama serve 拉起来，不等端口就绪（设置窗口打开时预热用）。
  返回：started / already-running / not-installed。
#>
function Start-OllamaServe($config, $ollamaExe = 'E:\Ollama\ollama.exe') {
  $port = Get-OllamaPort $config.local.ollama_url
  if (Test-TcpPort $port) { return 'already-running' }
  if (-not (Test-Path $ollamaExe)) { return 'not-installed' }

  # 必须显式带上 OLLAMA_MODELS：否则 serve 会把模型落到默认的 C:\Users\<你>\.ollama\models
  $models = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User')
  if (-not $models) { $models = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'Machine') }
  if ($models) { $env:OLLAMA_MODELS = $models }

  Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WorkingDirectory (Split-Path -Parent $ollamaExe) -WindowStyle Hidden
  return 'started'
}

<#
  本地模式时确保 ollama 在 11434 上服务。
  背景：Ollama 的托盘程序（ollama app.exe）在强制结束过 server 后，有时会陷入
  "ollama server not ready" 而不再拉起子进程。游戏启动器不依赖托盘，直接拉 serve，
  并显式带上 OLLAMA_MODELS，保证模型落在 E 盘而不是 C 盘。
  未安装 ollama 时静默返回（AI 场景自然走规则保底）。
  返回：skipped（非本地模式）/ already-running / started / failed / not-installed。
#>
function Ensure-OllamaServer($config, $ollamaExe = 'E:\Ollama\ollama.exe') {
  if ($config.mode -ne 'local') { return 'skipped' }

  $port = Get-OllamaPort $config.local.ollama_url
  $state = Start-OllamaServe $config $ollamaExe
  if ($state -ne 'started') { return $state }

  for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-TcpPort $port) { return 'started' }
  }
  return 'failed'
}
