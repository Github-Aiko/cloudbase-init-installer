# Xylentis Cloudbase-Init Installer

This repository builds the Xylentis distribution of Cloudbase-Init for
Windows. It tracks the Xylentis source fork at
<https://github.com/Github-Aiko/cloudbase-init> and includes the Proxmox
dual-stack network parsing fix.

The distribution keeps the internal `cloudbase-init` Windows service name and
configuration layout for compatibility, while using a separate MSI identity,
publisher, install directory, artwork and update chain.

## Build requirements

- Windows Server 2022 or a compatible Windows development machine
- Visual Studio 2019 build tools with MSBuild and WiX Toolset 3.x
- Git and 7-Zip
- Administrator privileges (the build enables Windows long paths)

Python 3.14.6 x64 is the current default. The build can download a clean Python
template using Python install manager, so a committed template is not required.

## Build locally

Run from an elevated PowerShell prompt:

```powershell
.\BuildAutomation\BuildCloudbaseInitSetup.ps1 `
    -ClonePullInstallerRepo:$false `
    -Platform x64 `
    -PythonVersion 3.14_6 `
    -VCVars automatic `
    -VSRedistDir "" `
    -InstallOfficialPythonMsi:$true `
    -InstallOfficialPythonUsingPyManager:$true
```

Build outputs:

- `CloudbaseInitSetup\bin\Release\x64\XylentisCloudbaseInitSetup.msi`
- `CloudbaseInitSetup\bin\Release\x64\XylentisCloudbaseInitSetup.zip`

The source repository, branch, constraints file and installer repository can be
overridden with `CloudbaseInitRepoUrl`, `CloudbaseInitRepoBranch`,
`CloudbaseInitConstraintsUrl` and `InstallerRepoUrl`.

## Compatibility note

Do not install the official Cloudbase-Init MSI and the Xylentis MSI side by
side. They use different MSI upgrade identities and directories, but both use
the `cloudbase-init` Windows service name. Uninstall one distribution before
installing the other. The MSI checks for that service and blocks a conflicting
side-by-side installation.

## Attribution and support

This is a customized distribution based on the Cloudbase-Init installer and
Cloudbase-Init projects. Upstream copyright and Apache License 2.0 notices are
preserved. Xylentis branding does not imply upstream endorsement.

For Xylentis information and support, visit <https://xylentis.com/>.
