# Builds the model pipeline's generators in headless Blender (build.py). The pipeline needs Blender 5.2 (manifest.py's
# BLENDER_VERSION, which build.py checks): a mesh's hash depends on how Blender triangulates it, so any other version
# could re-hash, and so re-upload, every mesh. -Blender is its blender.exe, by default the 5.2 install's, else PATH's.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Generators,

    [switch]$All,
    [switch]$Stale,
    [switch]$List,
    [string]$Params = "{}",
    [switch]$NoRender,
    [string]$OutDir,
    [string]$GameRoot,
    [string]$Blender
)

if (-not $Blender) {
    $installed = "C:\Program Files\Blender Foundation\Blender 5.2\blender.exe"
    $Blender = if (Test-Path $installed) { $installed } else { "blender" }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildPy = Join-Path $ScriptDir "build.py"

$blenderArgs = @("--background", "--python", $BuildPy, "--")

if ($List) {
    $blenderArgs += "--list"
} else {
    if ($All) {
        $blenderArgs += "--all"
    } elseif ($Stale) {
        $blenderArgs += "--stale"
    } elseif ($Generators) {
        $blenderArgs += $Generators
    } else {
        Write-Error "Usage: build.ps1 <generator...> | -All | -Stale | -List  [-Params '{...}'] [-NoRender] [-OutDir dir] [-Blender path]"
        exit 1
    }
    # Windows PowerShell strips embedded double-quotes when handing a string arg to a native
    # exe, so a JSON string like '{"width":20}' arrives as '{width:20}'. Escaping them survives.
    $blenderArgs += @("--params", $Params.Replace('"', '\"'))
    if ($NoRender) {
        $blenderArgs += "--no-render"
    }
    if ($OutDir) {
        $blenderArgs += @("--out-dir", $OutDir)
    }
    if ($GameRoot) {
        $blenderArgs += @("--game-root", $GameRoot)
    }
}

& $Blender @blenderArgs
exit $LASTEXITCODE
