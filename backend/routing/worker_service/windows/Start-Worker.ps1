# Moved: the launcher now lives in backend\routing\windows\Start-Worker.ps1 (routing restructure, 20 Nov 2026).
# This forwarder keeps the old command working. It has the same parameters and passes them on unchanged.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('planner','validator')][string]$Mode,
    [switch]$CheckConfig,
    [switch]$CheckConnection,
    [switch]$Activate,
    [string]$ApprovalRef,
    [string]$GraphId,
    [switch]$EnableCombinedWorkflow,
    [switch]$EnableExactWorkflow
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot '..\..\windows\Start-Worker.ps1') @PSBoundParameters
