<#
.SYNOPSIS
Exports the VCF deployment specification from vcfinstaller.vcf.lab.

.DESCRIPTION
Run this script with VMware PowerCLI installed. It copies the embedded Bash
exporter to the installer VM and runs it with Invoke-VMScript. The exporter
uploads the JSON to root@192.168.20.20:/var/www/html/VCF-Credentials.json,
replacing any previous web copy. It removes the installer copy after a
successful upload and keeps it if SCP fails. The web server must allow root
password login, and root on the installer VM must trust its SSH host key.

By default, the script prompts for credentials as needed. It can reuse an
active PowerCLI connection to the requested vCenter. For unattended use, copy
VcfExportPasswords.example.json, fill in the four password fields, and pass
the filled file with -PasswordFile. Keep the filled plaintext file out of
version control.

.PARAMETER VCenterServer
vCenter address. Defaults to 192.168.0.90.

.PARAMETER VCenterCredential
Optional credential for vCenter. The prompt and password file use
administrator@vsphere.local by default.

.PARAMETER GuestCredential
Optional credential for VMware guest operations. The prompt and password
file use root by default.

.PARAMETER InstallerAdminPassword
Optional SecureString password for the VCF Installer admin@local account.

.PARAMETER WebServerRootPassword
Optional SecureString password for root on the web server at 192.168.20.20.

.PARAMETER PasswordFile
Path to a JSON file with vCenterPassword, guestRootPassword,
installerAdminPassword, and webServerRootPassword string values. Explicit credential parameters take
precedence over the corresponding values in the file.

.PARAMETER GuestOutputPath
Absolute path for the JSON export on the VM. Defaults to a timestamped file
under /tmp. The exporter refuses to overwrite an existing file on the VM. The web copy has mode 0644.

.EXAMPLE
PS> .\Invoke-VcfDeploymentExport.ps1

Run interactively and enter passwords when prompted.

.EXAMPLE
PS> .\Invoke-VcfDeploymentExport.ps1 -PasswordFile .\VcfExportPasswords.json

Run using a filled copy of VcfExportPasswords.example.json.

.EXAMPLE
PS> .\Invoke-VcfDeploymentExport.ps1 -GuestOutputPath /tmp/my-vcf-export.json

Run interactively and save the export to a specific path on the VM.
#>
[CmdletBinding()]
param(
    [string]$VCenterServer = '192.168.0.90',
    [pscredential]$VCenterCredential,
    [pscredential]$GuestCredential,
    [securestring]$InstallerAdminPassword,
    [securestring]$WebServerRootPassword,
    [ValidateNotNullOrEmpty()]
    [string]$PasswordFile,
    [ValidatePattern('^/[^\r\n]+$')]
    [string]$GuestOutputPath = "/tmp/VCF-Deployment-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')).json"
)

$ErrorActionPreference = 'Stop'
$bashScript = @'
#!/usr/bin/env bash
set -euo pipefail
umask 077

stage='initializing the exporter'
trap 'printf "Deployment export failed while %s (exit %s).\n" "$stage" "$?" >&2' ERR

if (( $# > 1 )); then
    printf 'Usage: %s [output.json]\n' "$0" >&2
    exit 2
fi

output=${1:-VCF-Deployment.json}
base=https://127.0.0.1
request=(curl --disable --silent --show-error --fail --insecure
    --noproxy '*' --connect-timeout 10 --max-time 60)

for tool in curl jq scp; do
    command -v "$tool" >/dev/null || { printf 'Required command missing: %s\n' "$tool" >&2; exit 1; }
done

if [[ -t 0 ]]; then
    read -r -s -p 'VCF Installer admin@local password: ' password
    printf '\n' >&2
    read -r -s -p 'Web server root password: ' web_password
    printf '\n' >&2
else
    stage='reading passwords from the guest command'
    password=''
    IFS= read -r password || true
    web_password=''
    IFS= read -r web_password || true
fi
if [[ -z $password ]]; then
    printf 'No installer password supplied.\n' >&2
    exit 1
fi

if [[ -z $web_password ]]; then
    printf 'No web server root password supplied.\n' >&2
    exit 1
fi

# The API is reached directly over loopback, with proxies and curl startup config disabled.
stage='authenticating to VCF Installer'
token=$(
    printf '%s' "$password" |
        jq -Rs '{username: "admin@local", password: .}' |
        "${request[@]}" --header 'Content-Type: application/json' --data-binary @- "$base/v1/tokens" |
        jq -er '.accessToken | strings | select(test("^[A-Za-z0-9._~+/-]+=*$"))'
)
unset password

get_json() {
    printf 'Authorization: Bearer %s\nAccept: application/json\n' "$token" |
        "${request[@]}" --header @- "$base/$1"
}

stage='looking up the latest deployment'
deployment_id=$(get_json v1/sddcs/latest | jq -er '.id | strings | select(length > 0) | @uri')
stage='saving the deployment specification on the installer VM'
tmp=$(mktemp -- "$(dirname -- "$output")/.vcf-deployment.XXXXXXXX")
askpass=''
upload_dir=''
trap 'rm -f -- "$tmp" "$askpass"; if [[ -n $upload_dir ]]; then rm -f -- "$upload_dir/VCF-Credentials.json"; rmdir -- "$upload_dir"; fi' EXIT
get_json "v1/sddcs/$deployment_id/spec" | jq -e 'objects' > "$tmp"

# Publish only a complete file and refuse to overwrite an earlier export.
ln -T -- "$tmp" "$output"
printf 'Saved deployment specification to %s\n' "$output"

# Stage the web copy in a private directory so the installer export stays private.
stage='preparing the SCP upload'
upload_dir=$(mktemp -d)
upload_file="$upload_dir/VCF-Credentials.json"
install -m 0644 -- "$output" "$upload_file"

askpass=$(mktemp /root/.ssh/vcf-scp-askpass.XXXXXXXX)
cat > "$askpass" <<'ASKPASS'
#!/bin/sh
printf '%s\n' "$VCF_SCP_PASSWORD"
ASKPASS
chmod 700 "$askpass"
destination='root@192.168.20.20:/var/www/html/VCF-Credentials.json'
if ! VCF_SCP_PASSWORD="$web_password" SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force \
    scp -p -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
        -- "$upload_file" "$destination" </dev/null; then
    printf 'SCP to %s failed. The export is still at %s on the installer VM.\n' "$destination" "$output" >&2
    exit 1
fi
unset web_password
printf 'Copied deployment specification to %s\n' "$destination"
stage='removing the installer copy after upload'
rm -- "$output"
printf 'Removed the installer copy at %s\n' "$output"
'@

if ($PSBoundParameters.ContainsKey('PasswordFile')) {
    $passwordFileItem = Get-Item -LiteralPath $PasswordFile
    if ($passwordFileItem -isnot [System.IO.FileInfo]) {
        throw 'PasswordFile must point to a JSON file.'
    }

    try {
        $passwords = [IO.File]::ReadAllText($passwordFileItem.FullName) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'Could not read the password file as JSON. Use VcfExportPasswords.example.json as a template.'
    }
    if ($passwords -isnot [pscustomobject]) {
        throw 'The password file must contain a JSON object.'
    }

    $requiredFields = @()
    if (!$VCenterCredential) { $requiredFields += 'vCenterPassword' }
    if (!$GuestCredential) { $requiredFields += 'guestRootPassword' }
    if (!$InstallerAdminPassword) { $requiredFields += 'installerAdminPassword' }

    if (!$WebServerRootPassword) { $requiredFields += 'webServerRootPassword' }

    foreach ($field in $requiredFields) {
        if ($passwords.$field -isnot [string] -or $passwords.$field.Length -eq 0) {
            throw "Password file field '$field' must contain a non-empty JSON string."
        }
    }

    if (!$VCenterCredential) {
        $securePassword = ConvertTo-SecureString -String $passwords.vCenterPassword -AsPlainText -Force
        $VCenterCredential = [pscredential]::new('administrator@vsphere.local', $securePassword)
    }
    if (!$GuestCredential) {
        $securePassword = ConvertTo-SecureString -String $passwords.guestRootPassword -AsPlainText -Force
        $GuestCredential = [pscredential]::new('root', $securePassword)
    }
    if (!$InstallerAdminPassword) {
        $InstallerAdminPassword = ConvertTo-SecureString -String $passwords.installerAdminPassword -AsPlainText -Force
    }
    if (!$WebServerRootPassword) {
        $WebServerRootPassword = ConvertTo-SecureString -String $passwords.webServerRootPassword -AsPlainText -Force
    }
    $passwords = $securePassword = $null
}

Import-Module VMware.VimAutomation.Core

$server = $null
$openedConnection = $false
try {
    if (!$VCenterCredential) {
        $server = $global:DefaultVIServers |
            Where-Object { $_.IsConnected -and $_.Name -eq $VCenterServer } |
            Select-Object -First 1
        if (!$server -and $global:DefaultVIServer.IsConnected -and $global:DefaultVIServer.Name -eq $VCenterServer) {
            $server = $global:DefaultVIServer
        }
    }
    if (!$server) {
        if (!$VCenterCredential) {
            $VCenterCredential = Get-Credential -UserName 'administrator@vsphere.local' -Message "Sign in to vCenter $VCenterServer"
        }
        if (!$VCenterCredential) { throw 'A vCenter credential is required.' }
        $server = Connect-VIServer -Server $VCenterServer -Credential $VCenterCredential -NotDefault
        $openedConnection = $true
    }

    $vm = @(Get-VM -Server $server -Name 'vcfinstaller')
    if ($vm.Count -ne 1 -or $vm[0].Guest.HostName -ne 'vcfinstaller.vcf.lab') {
        throw 'Could not uniquely verify the VM as vcfinstaller.vcf.lab.'
    }
    if (!$GuestCredential) {
        $GuestCredential = Get-Credential -UserName 'root' -Message 'Sign in to vcfinstaller.vcf.lab'
    }
    if (!$GuestCredential) { throw 'A guest credential is required.' }
    if (!$InstallerAdminPassword) {
        $InstallerAdminPassword = Read-Host 'VCF Installer admin@local password' -AsSecureString
    }
    if (!$InstallerAdminPassword -or $InstallerAdminPassword.Length -eq 0) {
        throw 'The VCF Installer admin@local password is required.'
    }

    if (!$WebServerRootPassword) {
        $WebServerRootPassword = Read-Host 'Web server root password (192.168.20.20)' -AsSecureString
    }
    if (!$WebServerRootPassword -or $WebServerRootPassword.Length -eq 0) {
        throw 'The web server root password is required.'
    }

    $guestScriptPath = '/tmp/export-vcf-deployment.sh'
    $guestParameters = @{
        VM = $vm[0]
        GuestCredential = $GuestCredential
    }
    $localScriptPath = [IO.Path]::GetTempFileName()
    try {
        # Linux expects LF line endings and a shebang without a byte order mark.
        $bashWithLf = $bashScript.Replace("`r`n", "`n") + "`n"
        [IO.File]::WriteAllText($localScriptPath, $bashWithLf, [Text.UTF8Encoding]::new($false))
        Copy-VMGuestFile @guestParameters -Source $localScriptPath -Destination $guestScriptPath -LocalToGuest -Force | Out-Null
    } finally {
        [IO.File]::Delete($localScriptPath)
    }

    # Encode the passwords for shell quoting, then pass them to the exporter via stdin.
    $adminCredential = [pscredential]::new('admin@local', $InstallerAdminPassword)
    $passwordBytes = [Text.Encoding]::UTF8.GetBytes($adminCredential.GetNetworkCredential().Password)
    $webCredential = [pscredential]::new('root', $WebServerRootPassword)
    $webPasswordBytes = [Text.Encoding]::UTF8.GetBytes($webCredential.GetNetworkCredential().Password)
    try {
        $encodedWebPassword = [Convert]::ToBase64String($webPasswordBytes)
        $encodedPassword = [Convert]::ToBase64String($passwordBytes)
        $quotedOutputPath = "'" + $GuestOutputPath.Replace("'", "'\''") + "'"
        $guestCommand = 'umask 077; {{ printf %s {0} | base64 -d; printf "\n"; printf %s {1} | base64 -d; printf "\n"; }} | bash {2} {3} 2>&1' -f $encodedPassword, $encodedWebPassword, $guestScriptPath, $quotedOutputPath
        try {
            $result = Invoke-VMScript @guestParameters -ScriptType Bash -ScriptText $guestCommand
        } catch {
            # The PowerCLI error can contain the submitted script text.
            throw 'Invoke-VMScript failed to run the guest command. Check VMware Tools and guest-operation permissions.'
        }
    } finally {
        [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
        [Array]::Clear($webPasswordBytes, 0, $webPasswordBytes.Length)
        $encodedPassword = $encodedWebPassword = $guestCommand = $null
    }

    $guestOutput = ([string]$result.ScriptOutput).Trim()
    if ($result.ExitCode -ne 0) {
        $message = "The deployment export exited with code $($result.ExitCode)."
        if ($guestOutput) {
            $message += [Environment]::NewLine + $guestOutput
        }
        throw $message
    }
    if ($guestOutput) { $guestOutput }
} finally {
    if ($openedConnection) {
        Disconnect-VIServer -Server $server -Confirm:$false -ErrorAction Continue | Out-Null
    }
}
