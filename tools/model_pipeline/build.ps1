param(
    [Parameter(Position = 0)]
    [string]$Generator,

    [string]$Params = "{}",
    [string]$Out,
    [string]$LuauOut,
    [switch]$NoLuau,
    [string]$RenderOut,
    [switch]$NoRender,
    [string]$Blender = "blender",
    [switch]$List
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildPy = Join-Path $ScriptDir "build.py"

$blenderArgs = @("--background", "--python", $BuildPy, "--")

if ($List) {
    $blenderArgs += "--list"
} else {
    if (-not $Generator) {
        Write-Error "Usage: build.ps1 <generator> [-Params '{...}'] [-Out path.glb]  or  build.ps1 -List"
        exit 1
    }
    # Windows PowerShell strips embedded double-quotes when handing a string arg to a native
    # exe, so a JSON string like '{"width":20}' arrives as '{width:20}'. Escaping them survives.
    $EscapedParams = $Params.Replace('"', '\"')
    $blenderArgs += @("--generator", $Generator, "--params", $EscapedParams)
    if ($Out) {
        $blenderArgs += @("--out", $Out)
    }
    if ($NoLuau) {
        $blenderArgs += "--no-luau"
    } elseif ($LuauOut) {
        $blenderArgs += @("--luau-out", $LuauOut)
    }
    if ($NoRender) {
        $blenderArgs += "--no-render"
    } elseif ($RenderOut) {
        $blenderArgs += @("--render-out", $RenderOut)
    }
}

& $Blender @blenderArgs
exit $LASTEXITCODE
