# VCF Installer deployment export to webserver

[Invoke-VcfDeploymentExport.ps1](./Invoke-VcfDeploymentExport.ps1) exports the latest deployment specification from VMware Cloud Foundation (VCF) Installer and publishes it as `VCF-Credentials.json` on the lab web server. The specification can contain passwords. The PowerCLI script contains the Bash exporter and generates it for each run.

Send bash script to VCF installer -> Execute script on VCF Installer to extract a json file with passwords -> Send json file to local web server to display passwords

Copy VCF-Credentials.html to a web server, it will the fetch information from the generated json file and show/copy passwords.

## DISCLAIMER
**This is a script you ONLY should use in your homelab.**<br> 
**Under no circumstances should it be used in a production environment!**

## Lab endpoints

| Role | Default |
| --- | --- |
| vCenter | `192.168.0.90` |
| Installer VM inventory name | `vcfinstaller` |
| Installer guest hostname | `vcfinstaller.vcf.lab` |
| Installer API | `https://127.0.0.1` from inside the installer VM |
| Web server upload | `root@192.168.20.20:/var/www/html/VCF-Credentials.json` |

Use `-VCenterServer` to select the vCenter managing the installer. The installer VM name, guest hostname, and SCP destination are defined in the script.

## Prerequisites

- On the workstation, use PowerShell with VMware PowerCLI installed and a working connection to vCenter. The vCenter account needs permission to find the VM, copy files into its guest, and run guest commands.
- The installer VM must be powered on with VMware Tools running and must report `vcfinstaller.vcf.lab` as its guest hostname. The guest workflow uses root, Bash, `curl`, `jq`, OpenSSH `scp` with `SSH_ASKPASS_REQUIRE` support, and standard Linux file utilities. The exporter needs writable space under `/tmp` and an executable location under `/root/.ssh` for its temporary SSH password helper.
- The installer VM must reach the web server on TCP port 22. The server must allow SSH password login for root, support the SCP client's file transfer, and provide a writable `/var/www/html` directory.
- Install the web server's verified SSH public host key in `/root/.ssh/known_hosts` on the installer VM. Verify the key against a trusted source, such as the server console, before adding it. SCP uses strict host-key checking.

## Run interactively

From the directory that contains the script:

```powershell
.\Invoke-VcfDeploymentExport.ps1
```

Enter the credentials when prompted. The script can reuse an active PowerCLI connection matching the requested vCenter when you omit `-VCenterCredential` and `-PasswordFile`.

## Run with a password file

Copy [VcfExportPasswords.example.json](./VcfExportPasswords.example.json) and fill in each value with the corresponding password as a non-empty JSON string.

```powershell
Copy-Item .\VcfExportPasswords.example.json .\VcfExportPasswords.json
# Fill in VcfExportPasswords.json before running the export.
.\Invoke-VcfDeploymentExport.ps1 -PasswordFile .\VcfExportPasswords.json
```

| JSON field | Account |
| --- | --- |
| `vCenterPassword` | vCenter `administrator@vsphere.local` |
| `guestRootPassword` | Installer VM `root` for VMware guest operations |
| `installerAdminPassword` | VCF Installer API `admin@local` |
| `webServerRootPassword` | Web server `root` for SCP |

The filled JSON stores plaintext passwords. The repository ignores `VcfExportPasswords.json` at its root. Restrict access to the filled file and keep any copies under other names out of version control. Escape quotes and backslashes according to JSON rules when entering passwords.

## Parameters and examples

| Parameter | Purpose |
| --- | --- |
| `-VCenterServer` | vCenter host or IP address. Defaults to `192.168.0.90`. |
| `-VCenterCredential` | PowerShell `PSCredential` for vCenter. |
| `-GuestCredential` | PowerShell `PSCredential` for installer guest operations. The guest workflow requires root access. |
| `-InstallerAdminPassword` | `SecureString` for VCF Installer `admin@local`. |
| `-WebServerRootPassword` | `SecureString` for web server root. |
| `-PasswordFile` | JSON credential file. Explicit credential parameters override their corresponding file values. |
| `-GuestOutputPath` | Absolute installer path for the intermediate export. Defaults to `/tmp/VCF-Deployment-yyyyMMdd-HHmmssfff.json` with a UTC timestamp. Existing files at this path are protected from overwrite. |

```powershell
.\Invoke-VcfDeploymentExport.ps1 -GuestOutputPath /tmp/vcf-export.json
Get-Help .\Invoke-VcfDeploymentExport.ps1 -Full
```

## Export, upload, and cleanup

1. PowerCLI identifies the installer VM by inventory name and verifies its guest hostname. It writes the embedded Bash exporter to a temporary workstation file, copies it to `/tmp/export-vcf-deployment.sh` on the installer, and removes the workstation copy.
2. `Invoke-VMScript` runs the Bash exporter in the guest. The exporter authenticates to the VCF Installer API over loopback, finds the latest deployment, and writes its specification as JSON. The loopback request skips TLS certificate validation.
3. The exporter stages the web copy in a private temporary directory and uploads it using SCP with mode `0644`. Each successful upload replaces the previous `/var/www/html/VCF-Credentials.json`. Mode `0644` lets all local users read the file and permits only the owner to write it.
4. After SCP returns success, the exporter removes the intermediate JSON on the installer. If SCP fails, the exporter reports the failure, exits with an error, and keeps the completed JSON on the installer at the reported path. The guest Bash file remains available at `/tmp/export-vcf-deployment.sh` and is replaced by the next run.

## View the credentials page

Serve [VCF-Credentials.html](./VCF-Credentials.html) alongside `VCF-Credentials.json` if you want the browser viewer. Open the HTML page through the web server. The page fetches the JSON from the same directory. Deploy the HTML separately from this export workflow.

The page masks passwords by default, but clients that can fetch the JSON can read its contents directly. Restrict access to both the HTML and JSON through the web server or the lab network, and use HTTPS for browser access to the credentials.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| PowerCLI cannot connect | Check vCenter reachability, certificate trust, and the vCenter credential. |
| VM cannot be uniquely verified | Confirm that vCenter contains the `vcfinstaller` VM and that VMware Tools reports `vcfinstaller.vcf.lab` as its hostname. |
| Guest copy or execution fails | Check VMware Tools, guest root credentials, and the vCenter account's guest-operation permissions. |
| Password file validation fails | Compare the keys with the example file and ensure all required values are non-empty JSON strings. |
| Installer API returns an HTTP or JSON error | Check the `admin@local` password, installer service health, and whether a deployment is available. |
| Host key verification fails | Compare the web server's public host key with the entry trusted by root on the installer. Investigate changed keys before replacing the entry. |
| SSH reports permission denied | Check the web server root password, server-side root password authentication policy, and any error about executing the askpass helper. |
| SCP fails after a successful export | Review the SSH or SCP message immediately before the failure summary. Check TCP port 22, the SCP subsystem, and web directory permissions. Retry after fixing the cause. A run with the default timestamp creates a new intermediate export. |
| A custom guest output path already exists | Use a different path, or move the earlier export after confirming whether it is still needed. |
| Browser cannot load JSON | Confirm both files are served from the same directory and check the web server's access rules and JSON response. |

To verify the web copy's filesystem permissions, run this on the web server:

```bash
stat -c '%a %n' /var/www/html/VCF-Credentials.json
```

The expected mode is `644`.
