#Requires -Version 7
<#
.SYNOPSIS
  Writes the gitignored Docker secrets in jenkins/secrets/ used by
  jenkins/docker-compose.yml and jenkins/casc.yaml.

.DESCRIPTION
  - ingress_config_env         copy of k8s/app/ingress-config.env (rendered
                               from terraform outputs by render-k8s-config.ps1)
  - jenkins_deployer_role_arn  terraform output jenkins_deployer_role_arn
  - jenkins_admin_password     random, generated once
  - jenkins_ci_access_key_id / jenkins_ci_secret_access_key
                               only with -CreateAccessKey: runs
                               "aws iam create-access-key --user-name jenkins-ci"
                               (an AWS change) and writes the key straight to
                               disk. The secret is never printed.

  Files are written without BOM or trailing newline. Re-running without
  -CreateAccessKey leaves existing key files alone.

.EXAMPLE
  pwsh scripts/render-jenkins-secrets.ps1 -CreateAccessKey
  docker compose -f jenkins/docker-compose.yml up -d --build
#>
[CmdletBinding()]
param(
    [switch]$CreateAccessKey,
    [string]$InfraDir  = (Join-Path $PSScriptRoot '..' 'terraform' 'infra'),
    [string]$SecretDir = (Join-Path $PSScriptRoot '..' 'jenkins' 'secrets')
)

$ErrorActionPreference = 'Stop'
$SecretDir = [System.IO.Path]::GetFullPath($SecretDir)
New-Item -ItemType Directory -Force $SecretDir | Out-Null

function Write-Secret([string]$Name, [string]$Value) {
    [System.IO.File]::WriteAllText((Join-Path $SecretDir $Name), $Value, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  wrote $Name"
}

# 1. ingress-config.env (same file the manual kubectl apply uses)
& (Join-Path $PSScriptRoot 'render-k8s-config.ps1') -InfraDir $InfraDir | Out-Null
$ingressEnv = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' 'k8s' 'app' 'ingress-config.env'))
Write-Secret 'ingress_config_env' ([System.IO.File]::ReadAllText($ingressEnv))

# 2. role ARN and user name from terraform outputs
$outputs = (terraform "-chdir=$InfraDir" output -json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "terraform output failed (exit $LASTEXITCODE)" }
$roleArn  = [string]$outputs.jenkins_deployer_role_arn.value
$userName = [string]$outputs.jenkins_ci_user_name.value
if (-not $roleArn -or -not $userName) { throw 'terraform outputs jenkins_deployer_role_arn / jenkins_ci_user_name are missing' }
Write-Secret 'jenkins_deployer_role_arn' $roleArn

# 3. admin password, generated once
$pwFile = Join-Path $SecretDir 'jenkins_admin_password'
if (-not (Test-Path $pwFile)) {
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
    Write-Secret 'jenkins_admin_password' (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
}

# 4. jenkins-ci access key
$idFile     = Join-Path $SecretDir 'jenkins_ci_access_key_id'
$secretFile = Join-Path $SecretDir 'jenkins_ci_secret_access_key'
if ($CreateAccessKey) {
    $existing = (aws iam list-access-keys --user-name $userName --output json | ConvertFrom-Json).AccessKeyMetadata
    if ($LASTEXITCODE -ne 0) { throw 'aws iam list-access-keys failed' }
    if ($existing.Count -ge 2) { throw "$userName already has 2 access keys; delete one first (aws iam delete-access-key)." }
    $key = (aws iam create-access-key --user-name $userName --output json | ConvertFrom-Json).AccessKey
    if ($LASTEXITCODE -ne 0 -or -not $key) { throw 'aws iam create-access-key failed' }
    Write-Secret 'jenkins_ci_access_key_id' $key.AccessKeyId
    Write-Secret 'jenkins_ci_secret_access_key' $key.SecretAccessKey
    $key = $null
    if ($existing.Count -ge 1) {
        Write-Warning "$userName now has $($existing.Count + 1) access keys. Delete the old one once Jenkins works: aws iam delete-access-key --user-name $userName --access-key-id <old id>"
    }
} elseif (-not ((Test-Path $idFile) -and (Test-Path $secretFile))) {
    # Placeholders keep docker compose happy; the pipeline fails at the AWS step until replaced.
    if (-not (Test-Path $idFile))     { Write-Secret 'jenkins_ci_access_key_id' '' }
    if (-not (Test-Path $secretFile)) { Write-Secret 'jenkins_ci_secret_access_key' '' }
    Write-Warning 'No jenkins-ci access key yet. Re-run with -CreateAccessKey.'
}

Write-Host "Secrets in $SecretDir (gitignored). Restart Jenkins to reload: docker compose -f jenkins/docker-compose.yml up -d --force-recreate"
