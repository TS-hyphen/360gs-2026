param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$lichtfeld = Join-Path $env:LOCALAPPDATA '360GS\packs\lichtfeld-studio\bin\LichtFeld-Studio.exe'
if (-not (Test-Path -LiteralPath $lichtfeld)) {
    Write-Error "Managed LichtFeld executable not found: $lichtfeld"
    exit 2
}

& $lichtfeld @Args
