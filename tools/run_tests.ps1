#Requires -Version 5.1
<#
  .SYNOPSIS
    Esegue i test offline con LuaJIT (stessa semantica Lua 5.1 di DriverWorks)
    e controlla la sintassi e la purezza dei moduli.

  .DESCRIPTION
    1. Sintassi: ogni file src/**/*.lua deve compilare.
    2. Lint dei moduli puri (src/lib/util.lua, net.lua, ws_frame.lua e
       src/tv/protocol.lua): solo Lua 5.1 e nessun riferimento a C4.
    3. Ogni tests/test_*.lua gira in un processo separato, con la radice del
       repo come cartella di lavoro (`require "lib.log"` e
       `require "tests.support.harness"` funzionano). Le righe PASS/FAIL dei
       singoli test sono stampate cosi' come arrivano.
    Al primo fallimento lo script si ferma con exit code 1; exit code 0 solo
    se tutto e' verde.

    Interprete: luajit nel PATH; in alternativa il percorso di default di
    winget (DEVCOM.LuaJIT) o un lua 5.1 nel PATH.

  .EXAMPLE
    ./tools/run_tests.ps1
    ./tools/run_tests.ps1 -Filter websocket    # solo tests/test_*websocket*.lua
#>
param(
    [string]$Filter = "",
    [switch]$Quiet     # solo riepilogo per file e righe non-PASS
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Find-Lua {
    foreach ($name in @("luajit", "lua5.1", "lua51")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    $wingetDefault = Join-Path $env:LOCALAPPDATA "Programs\LuaJIT\bin\luajit.exe"
    if (Test-Path $wingetDefault) { return $wingetDefault }
    return $null
}

$lua = Find-Lua
if (-not $lua) {
    Write-Host "Interprete Lua non trovato. Installa LuaJIT: winget install --id DEVCOM.LuaJIT -e" -ForegroundColor Red
    exit 1
}
Write-Host "==> Interprete: $lua" -ForegroundColor Cyan

# ------------------------------------------------------------
# 1. Sintassi di tutti i sorgenti Lua
# ------------------------------------------------------------
Write-Host "==> Sintassi src/" -ForegroundColor Cyan
$syntaxFailed = $false
foreach ($file in (Get-ChildItem (Join-Path $repoRoot "src") -Recurse -Filter *.lua)) {
    $path = $file.FullName.Replace("\", "/")
    $ErrorActionPreference = "Continue"
    $output = & $lua -e "local f, err = loadfile([[$path]]); if not f then io.stderr:write(err) os.exit(1) end" 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($code -ne 0) {
        Write-Host ("  FAIL {0}: {1}" -f $file.Name, ($output -join " ")) -ForegroundColor Red
        $syntaxFailed = $true
    }
}
if ($syntaxFailed) { exit 1 }

# ------------------------------------------------------------
# 2. Lint dei moduli puri (Lua 5.1, nessun C4)
# ------------------------------------------------------------
Write-Host "==> Lint moduli puri" -ForegroundColor Cyan
$pureModules = @("src/lib/util.lua", "src/lib/net.lua", "src/lib/ws_frame.lua", "src/tv/protocol.lua")
$rules = @(
    @{ Pattern = '\bC4\b';                       Why = "riferimento a C4 (i moduli puri non lo toccano)" },
    @{ Pattern = '\bgoto\b|::\w+::';             Why = "goto/label (Lua 5.2+)" },
    @{ Pattern = '//';                           Why = "divisione intera // (Lua 5.3+)" },
    @{ Pattern = '<<|>>|[^~=<>]~[^=]|&|\|';      Why = "operatori bit a bit (Lua 5.3+)" },
    @{ Pattern = '\bbit32\b|\butf8\b';           Why = "libreria post-5.1" },
    @{ Pattern = 'table\.(pack|unpack|move)\b';  Why = "table.pack/unpack/move (5.2+; in 5.1 usa il globale unpack)" },
    @{ Pattern = 'string\.(pack|unpack|packsize)\b'; Why = "string.pack/unpack (5.3+)" },
    @{ Pattern = 'math\.(tointeger|ult|type)\b'; Why = "API math 5.3+" },
    @{ Pattern = '\b_ENV\b';                     Why = "_ENV (Lua 5.2+)" }
)
$lintFailed = $false
foreach ($relative in $pureModules) {
    $file = Get-Item (Join-Path $repoRoot $relative)
    $text = [System.IO.File]::ReadAllText($file.FullName)
    # commenti a blocco, poi commenti di riga, poi contenuto delle stringhe
    $text = [regex]::Replace($text, '(?s)--\[(=*)\[.*?\]\1\]', '')
    $lineNo = 0
    foreach ($line in ($text -split "`n")) {
        $lineNo++
        $code = [regex]::Replace($line, '--.*$', '')
        $code = [regex]::Replace($code, '"([^"\\]|\\.)*"', '""')
        $code = [regex]::Replace($code, "'([^'\\]|\\.)*'", "''")
        foreach ($rule in $rules) {
            if ($code -match $rule.Pattern) {
                Write-Host ("  FAIL {0}:{1} {2}" -f $file.Name, $lineNo, $rule.Why) -ForegroundColor Red
                $lintFailed = $true
            }
        }
    }
}
if ($lintFailed) { exit 1 }

# ------------------------------------------------------------
# 3. Test
# ------------------------------------------------------------
$tests = Get-ChildItem (Join-Path $repoRoot "tests") -Filter "test_*.lua" |
    Where-Object { $_.Name -like "*$Filter*" } | Sort-Object Name
if (-not $tests) {
    Write-Host "Nessun test trovato (filtro '$Filter')." -ForegroundColor Red
    exit 1
}

# niente doppi apici: Windows PowerShell 5.1 li perde nel passaggio a un exe nativo
$bootstrap = "package.path = 'src/?.lua;./?.lua;' .. package.path"
Push-Location $repoRoot
try {
    foreach ($test in $tests) {
        Write-Host "==> $($test.Name)" -ForegroundColor Cyan
        $relative = "tests/" + $test.Name
        # lo stderr di un exe nativo, con ErrorActionPreference=Stop, diventerebbe un'eccezione
        $ErrorActionPreference = "Continue"
        $output = & $lua -e $bootstrap $relative 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        foreach ($line in $output) {
            $text = "$line"
            if ($Quiet -and $text -match '^\s+PASS ') { continue }
            if ($text -match '^\s+FAIL ') {
                Write-Host $text -ForegroundColor Red
            } else {
                Write-Host $text
            }
        }
        if ($code -ne 0) {
            Write-Host "FALLITO: $($test.Name) (exit code $code)" -ForegroundColor Red
            exit 1
        }
    }
} finally {
    Pop-Location
}

Write-Host "==> Tutto verde ($($tests.Count) file di test)" -ForegroundColor Green
