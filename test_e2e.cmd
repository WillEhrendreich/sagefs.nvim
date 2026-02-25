@echo off
REM test_e2e.cmd — Run E2E integration tests against a real SageFs daemon
REM Each suite copies a sample project, starts a daemon, runs tests, and cleans up.
REM Requires: sagefs, dotnet, curl, nvim on PATH

setlocal enabledelayedexpansion

echo === sagefs.nvim E2E Integration Tests ===
echo.

REM ─── Preflight checks ───────────────────────────────────────────────────────
set FAIL=0

where sagefs >nul 2>&1
if errorlevel 1 (
  echo ERROR: sagefs not found on PATH
  set FAIL=1
)

where dotnet >nul 2>&1
if errorlevel 1 (
  echo ERROR: dotnet SDK not found on PATH
  set FAIL=1
)

where curl >nul 2>&1
if errorlevel 1 (
  echo ERROR: curl not found on PATH
  set FAIL=1
)

where nvim >nul 2>&1
if errorlevel 1 (
  echo ERROR: nvim not found on PATH
  set FAIL=1
)

if %FAIL%==1 (
  echo.
  echo Fix the above issues and retry.
  exit /b 1
)

echo Preflight OK: sagefs, dotnet, curl, nvim found
echo.

REM ─── Build sample projects ──────────────────────────────────────────────────
echo Building sample projects...

for %%D in (Minimal WithTests MultiFile) do (
  if exist samples\%%D\*.fsproj (
    echo   Building samples\%%D...
    pushd samples\%%D
    dotnet build --nologo -v q >nul 2>&1
    if errorlevel 1 (
      echo   ERROR: samples\%%D failed to build
      set FAIL=1
    ) else (
      echo   OK: samples\%%D
    )
    popd
  )
)

if %FAIL%==1 (
  echo.
  echo Sample project build failed. Fix and retry.
  exit /b 1
)

echo.

REM ─── Run E2E suites sequentially ────────────────────────────────────────────
set TOTAL_EXIT=0

for %%F in (
  spec\e2e\e2e_eval_spec.lua
  spec\e2e\e2e_sse_spec.lua
  spec\e2e\e2e_sessions_spec.lua
  spec\e2e\e2e_testing_spec.lua
  spec\e2e\e2e_hotreload_spec.lua
  spec\e2e\e2e_completions_spec.lua
) do (
  if exist %%F (
    echo --- Running %%F ---
    nvim --headless --clean -u NONE -l %%F
    if errorlevel 1 (
      echo   FAILED: %%F
      set TOTAL_EXIT=1
    ) else (
      echo   PASSED: %%F
    )
    echo.
  ) else (
    echo   SKIPPED: %%F not found
  )
)

echo.
if %TOTAL_EXIT%==0 (
  echo === All E2E suites passed ===
) else (
  echo === Some E2E suites FAILED ===
)

exit /b %TOTAL_EXIT%
