[CmdletBinding()]
param(
    [string]$SnapshotRoot = (Join-Path $PSScriptRoot '..\reports\m365')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sources = @(Get-ChildItem -LiteralPath $SnapshotRoot -Filter messages.json -Recurse)
$legacyPages = @(Get-ChildItem -LiteralPath (Join-Path $SnapshotRoot 'history') -Filter index.html -Recurse |
    Where-Object { $_.Directory.Parent.Name -eq 'history' -and
        -not (Test-Path -LiteralPath (Join-Path $_.DirectoryName 'messages.json')) })
$temporary = Join-Path ([IO.Path]::GetTempPath()) "m365-public-snapshot-$([guid]::NewGuid().ToString('N')).json"
try {
    foreach ($source in @($sources) + @($legacyPages)) {
        $messages = $source.FullName
        if ($source.Extension -eq '.html') {
            $html = Get-Content -LiteralPath $source.FullName -Raw -Encoding UTF8
            $match = [regex]::Match($html, '(?s)\bconst DATA = (?<json>.*?)\s*;\s*const INSIGHTS =')
            if (-not $match.Success) { throw "Legacy approved snapshot DATA not found: $messages" }
            $match.Groups['json'].Value | Set-Content -LiteralPath $temporary -Encoding UTF8
            $messages = $temporary
        }
        $parameters = @{
            MessagesJson = $messages
            OutputPath = Join-Path $source.DirectoryName 'index.html'
        }
        $insights = Join-Path $source.DirectoryName 'insights.json'
        if (Test-Path -LiteralPath $insights) { $parameters.InsightsJson = $insights }
        & (Join-Path $PSScriptRoot 'New-M365MessageCenterDashboard.ps1') @parameters
    }
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
