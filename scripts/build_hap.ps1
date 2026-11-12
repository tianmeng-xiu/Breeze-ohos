# build_hap.ps1 —— build_hap.sh 的 PowerShell 等价物（本机 bash 不在 PATH 时用）
# 用法: pwsh -File scripts/build_hap.ps1 -Project Breeze-ohos -Mode release [-Clean]
param(
    [string]$Project = "Breeze-ohos",
    [ValidateSet("debug", "release")][string]$Mode = "release",
    [string]$Root = "",
    [string]$JavaHome = "",
    [switch]$Clean
)
$ErrorActionPreference = "Stop"
if ($JavaHome) { $env:JAVA_HOME = $JavaHome -replace '\\', '/' }

# 仓库根从脚本位置推导（$PSScriptRoot = 本文件所在的 scripts/），不写死盘符。
# 要指向别处：pwsh -File scripts/build_hap.ps1 -Root D:/work/breeze
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$OHOS_ROOT = $Root -replace '\\', '/'
$CLI = if ($env:OHOS_CLI_TOOLS) { $env:OHOS_CLI_TOOLS -replace '\\', '/' } else { "$OHOS_ROOT/toolchain/cli-tools/command-line-tools" }
$env:OHOS_ROOT = $OHOS_ROOT
$env:OHOS_CLI_TOOLS = $CLI
$env:DEVECO_SDK_HOME = "$CLI/sdk"
$env:DEVECO_NODE_HOME = "$CLI/tool/node"
$env:HVIGOR_USER_HOME = "$OHOS_ROOT/toolchain/.hvigor"
if (-not $env:JAVA_HOME) {
    $jdk = @(Get-ChildItem -Directory "$OHOS_ROOT/toolchain/jdk" -Filter 'jdk-17*' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($jdk.Count -eq 0) {
        Write-Error "找不到 toolchain/jdk/jdk-17*，请设 JAVA_HOME 或 -JavaHome"
        exit 2
    }
    $env:JAVA_HOME = $jdk[0].FullName -replace '\\', '/'
}
$env:npm_config_cache = "$OHOS_ROOT/toolchain/.npm-cache"
$env:NODE_OPTIONS = "--require $OHOS_ROOT/scripts/spawn-shim.cjs"
$env:PATH = "$($env:DEVECO_NODE_HOME);$($env:JAVA_HOME)/bin;$($env:PATH)"

$NODE = "$CLI/tool/node/node.exe"
$PROJ = if (Test-Path "$OHOS_ROOT/$Project/oh-package.json5") { "$OHOS_ROOT/$Project" } else { $Project }
if (-not (Test-Path "$PROJ/oh-package.json5")) { Write-Error "not a project dir: $PROJ"; exit 2 }

Write-Output "[build] project = $PROJ  mode=$Mode  clean=$Clean"
& $NODE "$OHOS_ROOT/scripts/link_hvigor.cjs" "$PROJ"
if ($LASTEXITCODE -ne 0) { Write-Error "env prepare failed"; exit 3 }

Set-Location $PROJ
$LOG_DIR = "$OHOS_ROOT/_tmp/build-logs"
New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null
$LOG = "$LOG_DIR/$Project-$Mode-$(Get-Date -Format yyyyMMdd-HHmmss).ps1.log"
$HVIGOR = "node_modules/@ohos/hvigor/bin/hvigor.js"

if ($Clean) {
    Write-Output "[build] clean ..."
    & $NODE $HVIGOR --mode module -p product=default -p buildMode=$Mode clean --no-daemon *>> $LOG
}
Write-Output "[build] assembleHap ... (log: $LOG)"
& $NODE $HVIGOR --mode module -p product=default -p buildMode=$Mode assembleHap --no-daemon *>> $LOG
$RC = $LASTEXITCODE

$HAP = "entry/build/default/outputs/default/entry-default-unsigned.hap"
if ($RC -eq 0 -and (Test-Path $HAP)) {
    $SIZE = (Get-Item $HAP).Length
    Write-Output "[build] SUCCESS  $PROJ/$HAP  ($SIZE bytes, mode=$Mode)"
    exit 0
}
Write-Output "[build] FAILED (exit $RC)"
Get-Content $LOG | ForEach-Object { $_ -replace "`e\[[0-9;]*m", "" } |
    Select-String -Pattern "ERROR|Error Message|COMPILE RESULT|At File:|BUILD FAILED" |
    Select-Object -Last 40
Write-Output "[build] full log: $LOG"
exit $RC
