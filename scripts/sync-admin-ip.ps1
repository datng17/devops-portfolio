#Requires -Version 7
<#
.SYNOPSIS
  Keeps the EKS public API allowlist in step with this machine's dynamic public IP.

.DESCRIPTION
  Builds the same list Terraform builds in terraform/infra/admin_ip.tf
  (static admin_cidrs + current IP/32) and, if the cluster's
  publicAccessCidrs differ, updates them with `aws eks update-cluster-config`.
  Because Terraform detects the same IP, the next `terraform plan` shows no
  drift. Only the public endpoint allowlist is touched.

  -Install registers a Windows scheduled task that runs this every 15 minutes
  and at logon, so kubectl and local Jenkins keep working after the ISP
  changes the IP. -Uninstall removes it.

.EXAMPLE
  pwsh scripts/sync-admin-ip.ps1            # sync now, wait for the update to finish
  pwsh scripts/sync-admin-ip.ps1 -WhatIf    # show what would change
  pwsh scripts/sync-admin-ip.ps1 -Install   # sync automatically from now on
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$ClusterName = 'eks-portfolio',
  [string]$Region = 'us-east-1',
  # Static CIDRs to keep next to the detected IP. Default: terraform output admin_cidrs_static.
  [string[]]$StaticCidrs,
  [switch]$NoWait,
  [switch]$Install,
  [switch]$Uninstall,
  [int]$IntervalMinutes = 15
)

$ErrorActionPreference = 'Stop'
$TaskName = "eks-admin-ip-sync-$ClusterName"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$LogFile = Join-Path $env:LOCALAPPDATA "$TaskName.log"

function Write-Log([string]$Message) {
  $line = "{0:u} {1}" -f (Get-Date), $Message
  Write-Host $line
  if (-not $Install -and -not $Uninstall) { Add-Content -Path $LogFile -Value $line }
}

if ($Uninstall) {
  if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task $TaskName."
  }
  return
}

if ($Install) {
  $pwsh = (Get-Process -Id $PID).Path
  $taskArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$PSCommandPath`" -ClusterName $ClusterName -Region $Region -NoWait"
  $action = New-ScheduledTaskAction -Execute $pwsh -Argument $taskArgs -WorkingDirectory $RepoRoot
  $triggers = @(
    New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
  )
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  if ($PSCmdlet.ShouldProcess($TaskName, "Register scheduled task (every $IntervalMinutes min + at logon)")) {
    # Runs as the current user (interactive logon) so it uses your AWS CLI profile.
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings `
      -Description "Sync $ClusterName EKS public API allowlist with the current public IP" -Force | Out-Null
    Write-Host "Registered $TaskName (every $IntervalMinutes min and at logon). Log: $LogFile"
  }
  return
}

# 1. Current public IP.
$ip = $null
foreach ($attempt in 1..3) {
  try { $ip = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com' -TimeoutSec 10).Trim(); break }
  catch { Start-Sleep -Seconds 2 }
}
if (-not $ip -or -not [System.Net.IPAddress]::TryParse($ip, [ref]$null) -or $ip.Contains(':')) {
  throw "Could not detect a public IPv4 address (got '$ip')."
}

# 2. Static CIDRs from Terraform state (the same input Terraform uses).
if (-not $PSBoundParameters.ContainsKey('StaticCidrs')) {
  $StaticCidrs = @()
  $tfDir = Join-Path $RepoRoot 'terraform/infra'
  if ((Get-Command terraform -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $tfDir '.terraform'))) {
    $json = terraform "-chdir=$tfDir" output -json admin_cidrs_static 2>$null
    if ($LASTEXITCODE -eq 0 -and $json) { $StaticCidrs = @($json | ConvertFrom-Json) }
  }
}
foreach ($c in $StaticCidrs) {
  if ($c -eq '0.0.0.0/0' -or $c -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') { throw "Refusing static CIDR '$c'." }
}
$desired = @(@($StaticCidrs) + "$ip/32" | Sort-Object -Unique)

# 3. Compare with the cluster.
$cluster = aws eks describe-cluster --name $ClusterName --region $Region --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "aws eks describe-cluster failed." }
$current = @($cluster.cluster.resourcesVpcConfig.publicAccessCidrs | Sort-Object -Unique)
if (-not (Compare-Object $current $desired)) {
  Write-Log "In sync: $($current -join ',')"
  return
}

# EKS allows one cluster update at a time.
$updates = aws eks list-updates --name $ClusterName --region $Region --output json | ConvertFrom-Json
foreach ($id in $updates.updateIds) {
  $u = aws eks describe-update --name $ClusterName --region $Region --update-id $id --output json | ConvertFrom-Json
  if ($u.update.status -eq 'InProgress') {
    Write-Log "Update $id ($($u.update.type)) still in progress; retry later."
    return
  }
}

$cidrArg = $desired -join ','
if (-not $PSCmdlet.ShouldProcess($ClusterName, "Set publicAccessCidrs $($current -join ',') -> $cidrArg")) { return }

$upd = aws eks update-cluster-config --name $ClusterName --region $Region `
  --resources-vpc-config "publicAccessCidrs=$cidrArg" --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "aws eks update-cluster-config failed." }
$updateId = $upd.update.id
Write-Log "Started update $updateId : $($current -join ',') -> $cidrArg"

if ($NoWait) { return }
do {
  Start-Sleep -Seconds 15
  $status = aws eks describe-update --name $ClusterName --region $Region --update-id $updateId `
    --query update.status --output text
  Write-Host "  $status"
} while ($status -eq 'InProgress')
if ($status -ne 'Successful') { throw "EKS update $updateId ended with status $status." }
Write-Log "Update $updateId successful."
