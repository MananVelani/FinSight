<#
.SYNOPSIS
    FinSight AI - Local startup script (fully native, no Docker)
.DESCRIPTION
    Starts all services natively:
      Infrastructure: PostgreSQL 18 (port 5433), Redis, Qdrant (native binary)
      Application:    FastAPI backend (8000), Celery worker, Next.js frontend (3000)
.USAGE
    .\start-local-native.ps1           # Start everything
    .\start-local-native.ps1 -StopAll  # Stop everything
#>
param(
    [switch]$StopAll,
    [switch]$InfraOnly,
    [switch]$SkipInfra
)

$ErrorActionPreference = "Continue"
$ROOT = $PSScriptRoot

function Write-Step($msg) { Write-Host "`n[STEP] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [ERR] $msg" -ForegroundColor Red }

# ── Stop All ─────────────────────────────────────────────────────────
if ($StopAll) {
    Write-Step "Stopping all FinSight services..."
    Get-Process | Where-Object { $_.MainWindowTitle -match "FinSight" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name "qdrant" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $portPids = @()
    try {
        $portPids += (Get-NetTCPConnection -LocalPort 8000 -ErrorAction SilentlyContinue).OwningProcess
        $portPids += (Get-NetTCPConnection -LocalPort 3000 -ErrorAction SilentlyContinue).OwningProcess
    } catch {}
    $portPids | Where-Object { $_ -and $_ -ne 0 } | Sort-Object -Unique | ForEach-Object {
        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "All FinSight processes stopped."
    Write-Warn "Note: PostgreSQL and Redis services remain running (Windows services)."
    exit 0
}

if (-not $SkipInfra) {
    # ── 1. PostgreSQL (Windows Service) ──────────────────────────────────
    Write-Step "Checking PostgreSQL 18 (port 5433)..."
    $pgService = Get-Service -Name "postgresql-x64-18" -ErrorAction SilentlyContinue
    if ($pgService -and $pgService.Status -ne "Running") {
        Start-Service -Name "postgresql-x64-18"
        Start-Sleep -Seconds 3
    }
    $env:PGPASSWORD = 'postgres'
    $pgReady = & 'C:\Program Files\PostgreSQL\18\bin\pg_isready.exe' -h localhost -p 5433 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "PostgreSQL 18 ready on localhost:5433"
    } else {
        Write-Err "PostgreSQL not ready! Check the service."
    }

    # ── 2. Redis ─────────────────────────────────────────────────────────
    Write-Step "Checking Redis (port 6379)..."
    $redisPong = & "C:\Program Files\Redis\redis-cli.exe" ping 2>&1
    if ($redisPong -match "PONG") {
        Write-Ok "Redis already running on localhost:6379"
    } else {
        Start-Process -FilePath "C:\Program Files\Redis\redis-server.exe" -WindowStyle Minimized
        Start-Sleep -Seconds 2
        $redisPong2 = & "C:\Program Files\Redis\redis-cli.exe" ping 2>&1
        if ($redisPong2 -match "PONG") { Write-Ok "Redis started on localhost:6379" }
        else { Write-Err "Redis failed to start!" }
    }

    # ── 3. Qdrant ────────────────────────────────────────────────────────
    Write-Step "Checking Qdrant (port 6333)..."
    $qdrantProc = Get-Process -Name "qdrant" -ErrorAction SilentlyContinue
    if (-not $qdrantProc) {
        Start-Process powershell -ArgumentList @(
            "-NoExit", "-Command",
            "Set-Location '$ROOT\qdrant'; " +
            "`$Host.UI.RawUI.WindowTitle = 'FinSight: Qdrant'; " +
            "Write-Host 'Qdrant running on port 6333...' -ForegroundColor Cyan; " +
            ".\qdrant.exe"
        )
        Write-Host "  Waiting for Qdrant..." -NoNewline
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            Write-Host "." -NoNewline
            try {
                Invoke-WebRequest -Uri "http://localhost:6333/healthz" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop | Out-Null
                Write-Host ""
                Write-Ok "Qdrant ready on localhost:6333"
                break
            } catch {}
        }
    } else {
        Write-Ok "Qdrant already running"
    }
}

if ($InfraOnly) {
    Write-Host "`n--- Infrastructure is running ---" -ForegroundColor Green
    Write-Host "  PostgreSQL -> localhost:5433"
    Write-Host "  Redis      -> localhost:6379"
    Write-Host "  Qdrant     -> localhost:6333/dashboard"
    exit 0
}

# ── 4. Clear Next.js cache ────────────────────────────────────────────
if (Test-Path "$ROOT\frontend\.next") {
    Remove-Item -Recurse -Force "$ROOT\frontend\.next" -ErrorAction SilentlyContinue
    Write-Ok "Cleared Next.js cache"
}

# ── 5. Backend API ────────────────────────────────────────────────────
Write-Step "Starting Backend API (port 8000)..."
Start-Process powershell -ArgumentList @(
    "-NoExit", "-Command",
    "Set-Location '$ROOT\backend'; " +
    "`$env:PYTHONPATH='$ROOT\backend'; " +
    "`$Host.UI.RawUI.WindowTitle = 'FinSight: Backend API'; " +
    "Write-Host 'Starting Backend API on port 8000...' -ForegroundColor Cyan; " +
    "& .\.venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload"
)
Write-Ok "Backend window launched"

# ── 6. Celery Worker ──────────────────────────────────────────────────
Write-Step "Starting Celery Worker..."
Start-Process powershell -ArgumentList @(
    "-NoExit", "-Command",
    "Set-Location '$ROOT\backend'; " +
    "`$env:PYTHONPATH='$ROOT\backend'; " +
    "`$Host.UI.RawUI.WindowTitle = 'FinSight: Celery Worker'; " +
    "Write-Host 'Starting Celery Worker (solo pool)...' -ForegroundColor Cyan; " +
    "& .\.venv\Scripts\python.exe -m celery -A workers.celery_app worker --loglevel=info --pool=solo"
)
Write-Ok "Celery window launched"

# ── 7. Wait for Backend ───────────────────────────────────────────────
Write-Host "`n  Waiting for Backend API..." -NoNewline
$backendReady = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    Write-Host "." -NoNewline
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:8000/" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $backendReady = $true; break }
    } catch {}
}
if ($backendReady) { Write-Host ""; Write-Ok "Backend API ready!" }
else { Write-Host ""; Write-Warn "Backend may still be loading (check its window)" }

# ── 8. Frontend ───────────────────────────────────────────────────────
Write-Step "Starting Frontend (port 3000)..."
Start-Process powershell -ArgumentList @(
    "-NoExit", "-Command",
    "Set-Location '$ROOT\frontend'; " +
    "`$Host.UI.RawUI.WindowTitle = 'FinSight: Frontend'; " +
    "Write-Host 'Starting Next.js on port 3000...' -ForegroundColor Cyan; " +
    "npm run dev"
)
Write-Ok "Frontend window launched"

Start-Sleep -Seconds 3

# ── Summary ───────────────────────────────────────────────────────────
Write-Host "`n"
Write-Host "---------------------------------------------" -ForegroundColor Green
Write-Host ""
Write-Host "  Infrastructure (Native):" -ForegroundColor White
Write-Host "    PostgreSQL  -> localhost:5433" -ForegroundColor Gray
Write-Host "    Redis       -> localhost:6379" -ForegroundColor Gray
Write-Host "    Qdrant      -> localhost:6333" -ForegroundColor Gray
Write-Host ""
Write-Host "  Application (Native):" -ForegroundColor White
Write-Host "    Backend     -> http://localhost:8000      (API docs: /docs)" -ForegroundColor Gray
Write-Host "    Frontend    -> http://localhost:3000" -ForegroundColor Gray
Write-Host "    Qdrant UI   -> http://localhost:6333/dashboard" -ForegroundColor Gray
Write-Host "    Celery      -> Background worker (solo pool)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Stop all:  .\start-local-native.ps1 -StopAll" -ForegroundColor Yellow
Write-Host "---------------------------------------------" -ForegroundColor Green
