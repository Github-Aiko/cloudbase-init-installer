Param(
  [string]$platform = "x64",
  [string]$pythonversion = "3.14_6",
  [string]$SignX509Thumbprint = $null,
  [string]$release = $null,
  # Cloudbase-Init repo details
  [string]$CloudbaseInitRepoUrl = "https://github.com/Github-Aiko/cloudbase-init.git",
  [string]$CloudbaseInitRepoBranch = "master",
  [string]$CloudbaseInitConstraintsUrl = $null,
  # Use an already available installer or clone a new one.
  [switch]$ClonePullInstallerRepo = $true,
  [string]$InstallerRepoUrl = "https://github.com/Github-Aiko/cloudbase-init-installer.git",
  [string]$VSRedistDir = "${ENV:ProgramFiles(x86)}\Common Files\Merge Modules",
  [string]$SignTimestampUrl = "http://timestamp.digicert.com?alg=sha256",
  [string]$VCVars = "2019",
  [switch]$InstallOfficialPythonMsi = $false,
  [string]$OfficialPythonMsiChecksum = "F95758C1FE6F75CC33D8E65640B074676AB88CB3",
  [switch]$RemovePythonPycs = $false,
  [switch]$InstallOfficialPythonUsingPyManager = $false
)

$ErrorActionPreference = "Stop"

$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
$repoRootPath = split-path -parent $scriptPath

. "$scriptPath\BuildUtils.ps1"

$platformVCVarsRequired = "x86_amd64"
# On Visual Studio 2019, the mixed x86_amd64 VC variables
# make compilation for x86 use the x64 functions
if ($platform -eq "x86") {
    throw "Platform x86 is no longer supported. See https://github.com/cloudbase/cloudbase-init/issues/213"
}

# Fix required to allow for >= 255 characters paths. Required for Python folder bundling.
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -Value 1

SetVCVars $VCVars $platformVCVarsRequired

# Build with the toolset provided by the selected Visual Studio installation.
# The project defaults to v142 for compatibility with the original VS 2019
# build environment, but newer runners do not necessarily install that
# optional legacy component.
$visualStudioMajorVersion = $ENV:VisualStudioVersion.Split('.')[0]
$platformToolsets = @{
    "15" = "v141"
    "16" = "v142"
    "17" = "v143"
    "18" = "v145"
}
$platformToolset = $platformToolsets[$visualStudioMajorVersion]
if (!$platformToolset) {
    throw "Unsupported Visual Studio version: $ENV:VisualStudioVersion"
}
Write-Host "Using Visual Studio $ENV:VisualStudioVersion platform toolset $platformToolset"

# Chocolatey can install WiX while the runner service is already running, so
# its new machine-level WIX variable is not visible in the current process.
# Discover the SDK explicitly because UtilsActions needs wcautil.h and the
# native WiX libraries in addition to the MSBuild targets.
$wixRootCandidates = @(
    $ENV:WIX,
    [Environment]::GetEnvironmentVariable("WIX", "Machine")
)
$wixInstallBase = "${ENV:ProgramFiles(x86)}"
if (Test-Path $wixInstallBase -PathType Container) {
    $wixRootCandidates += Get-ChildItem $wixInstallBase -Directory `
        -Filter "WiX Toolset v3.*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -ExpandProperty FullName
}
$wixRoot = $wixRootCandidates |
    Where-Object {
        $_ -and (Test-Path (Join-Path $_ "sdk\VS2015\inc\wcautil.h") `
            -PathType Leaf)
    } |
    Select-Object -First 1
if (!$wixRoot) {
    throw "WiX v3 SDK was not found. Install it with: choco install wixtoolset -y --no-progress"
}
$ENV:WIX = $wixRoot.TrimEnd('\') + '\'
Write-Host "Using WiX SDK from $ENV:WIX"

$wixTargetsCandidates = @(
    "${ENV:ProgramFiles(x86)}\MSBuild\Microsoft\WiX\v3.x\Wix.targets",
    "$ENV:ProgramFiles\MSBuild\Microsoft\WiX\v3.x\Wix.targets"
)
$wixTargetsPath = $wixTargetsCandidates |
    Where-Object { Test-Path $_ -PathType Leaf } |
    Select-Object -First 1
if (!$wixTargetsPath) {
    throw "WiX v3 MSBuild targets were not found. Repair the wixtoolset Chocolatey package."
}
Write-Host "Using WiX MSBuild targets from $wixTargetsPath"

# Needed for SSH
$ENV:HOME = $ENV:USERPROFILE

$basepath = Join-path $scriptPath "build\cloudbase-init"

$ENV:PATH += ";$ENV:ProgramFiles (x86)\Git\bin\"
CheckDir $basepath

pushd .
try
{
    cd $basepath

    # Don't use the default pip temp directory to avoid concurrency issues
    $ENV:TMPDIR = Join-Path $basepath "temp"
    CheckRemoveDir $ENV:TMPDIR
    mkdir $ENV:TMPDIR

    if ($ClonePullInstallerRepo)
    {
        # Clone a new installer repo no matter what.
        $cloudbaseInitInstallerDir = join-Path $basepath "cloudbase-init-installer"
        ExecRetry {
            GitClonePull $cloudbaseInitInstallerDir $InstallerRepoUrl
        }
    }
    else
    {
        $InstallerDir = (Join-Path -Path $PSScriptRoot -ChildPath ..\ -Resolve)
        if (Test-Path $InstallerDir)
        {
            $cloudbaseInitInstallerDir = $InstallerDir
        }
        else
        {
            throw "Installer path not present: $InstallerDir"
        }
    }
    $python_dir = join-path $cloudbaseInitInstallerDir "CloudbaseInitSetup\Python_CloudbaseInit"
    $ENV:PATH = "$python_dir\;$python_dir\scripts;$ENV:PATH"

    $python_template_dir = join-path $cloudbaseInitInstallerDir "Python$($pythonversion.replace('.', ''))_${platform}_Template"

    # TODO(avladu): stick to just only one way to download Python, preferably the pymanager once it gets ironed out
    if ($InstallOfficialPythonMsi) {
        if ($InstallOfficialPythonUsingPyManager) {
                Remove-Item -Recurse -Force $python_template_dir -ErrorAction SilentlyContinue
                DownloadInstall-PythonUsingPyManager $platform $python_template_dir $pythonversion
        } else {
                if (!$OfficialPythonMsiChecksum) {
                    throw "Please set a OfficialPythonMsiChecksum parameter value."
                }
                Remove-Item -Recurse -Force $python_template_dir -ErrorAction SilentlyContinue
                DownloadInstall-PythonMsi $platform $python_template_dir $pythonversion $OfficialPythonMsiChecksum
        }
    }

    CheckCopyDir $python_template_dir $python_dir

    # Make sure that we don't have temp files from a previous build
    $python_build_path = "$ENV:LOCALAPPDATA\Temp\pip_build_$ENV:USERNAME"
    if (Test-Path $python_build_path) {
        Remove-Item -Recurse -Force $python_build_path
    }

    ExecRetry { PipInstall "pip" -update $true }
    ExecRetry { PipInstall "wheel" -update $true }
    ExecRetry { PipInstall "setuptools" -update $true }

    if (Test-Path ".\requirements") {
        Remove-Item -Recurse -Force ".\requirements"
    }

    mkdir ".\requirements"
    $upper_constraints_path = ".\requirements\upper-constraints.txt"
    $upper_constraints_file = Join-Path (Resolve-Path ".\requirements") "upper-constraints.txt"
    if (!$CloudbaseInitConstraintsUrl) {
        $constraints_repo_path = $CloudbaseInitRepoUrl -replace "^https://github.com/", ""
        $constraints_repo_path = $constraints_repo_path -replace "\.git$", ""
        $CloudbaseInitConstraintsUrl = "https://raw.githubusercontent.com/${constraints_repo_path}/refs/heads/${CloudbaseInitRepoBranch}/upper-constraints.txt"
    }
    try {
        ExecRetry { DownloadFile $CloudbaseInitConstraintsUrl $upper_constraints_file }
    } catch {
        ExecRetry { DownloadFile "https://raw.githubusercontent.com/openstack/requirements/refs/heads/master/upper-constraints.txt" $upper_constraints_file }
    }

    if (!(Test-Path $upper_constraints_file)) {
      throw "${upper_constraints_file} does not exist"
    }

    $env:PIP_CONSTRAINT = $upper_constraints_file
    $env:PIP_NO_BINARIES = "cloudbase-init"

    if ($release)
    {
        ExecRetry { PipInstall "cloudbase-init==$release" }
    }
    else
    {
        ExecRetry { PullInstall "cloudbase-init" $CloudbaseInitRepoUrl $CloudbaseInitRepoBranch }
    }

    if ($RemovePythonPycs) {
        pushd $python_dir
            Get-ChildItem -Path .\ -Recurse -Include *__pycache__ | foreach ($_) { Remove-Item $_.FullName -Force -Recurse}
            Get-ChildItem -Path .\ -Recurse -Include *.pyc | foreach ($_) { Remove-Item $_.FullName -Force -Recurse}
        popd
    }
    $release_dir = join-path $cloudbaseInitInstallerDir "CloudbaseInitSetup\bin\Release\$platform"
    $bin_dir = join-path $cloudbaseInitInstallerDir "CloudbaseInitSetup\Binaries\$platform"

    $zip_content_dir = join-path $release_dir "zip_content"
    CheckRemoveDir $zip_content_dir
    mkdir $zip_content_dir

    $python_dir_release = join-path $zip_content_dir "Python"
    $bin_dir_release = join-path $zip_content_dir "Bin"

    CheckCopyDir $python_dir $python_dir_release
    CheckCopyDir $bin_dir $bin_dir_release

    $zip_path = join-path $release_dir "XylentisCloudbaseInitSetup.zip"
    if (Test-Path $zip_path) {
        del $zip_path
    }

    pushd $zip_content_dir
    try
    {
        CreateZip $zip_path *
    }
    finally
    {
        popd
    }

    $version = &"$python_dir\python.exe" -c "from cloudbaseinit import version; print(version.get_version())"
    if ($LastExitCode -or !$version.Length) { throw "Unable to get cloudbase-init version" }
    Write-Host "Cloudbase-Init version: $version"

    try
    {
        [int]::Parse($version.Substring($version.LastIndexOf('.') + 1)) | out-null
        $msi_version = $version + ".0"
        Write-Host "This is a tagged stable release"
    }
    catch
    {
        $msi_version = $version.Substring(0, $version.LastIndexOf('.')) + ".0"
    }

    Write-Host "Cloudbase-Init MSI version: $msi_version"

    $installer_sources_dir = join-path $cloudbaseInitInstallerDir "CloudbaseInitSetup"


    if ($VSRedistDir)
    {
        if($platform -eq "x64")
        {
            copy "${VSRedistDir}\Microsoft_VC140_CRT_x64.msm" $installer_sources_dir
        }
        else
        {
            copy "${VSRedistDir}\Microsoft_VC140_CRT_x86.msm" $installer_sources_dir
        }
    }

    cd $cloudbaseInitInstallerDir

    $msbuildArguments = @(
        "CloudbaseInitSetup.sln",
        "/m",
        "/p:Platform=$platform",
        "/p:Configuration=Release",
        "/p:PlatformToolset=$platformToolset",
        "/p:WixTargetsPath=$wixTargetsPath",
        "/p:DefineConstants=PythonSourcePath=$python_dir;CarbonSourcePath=Carbon;Version=$msi_version;VersionStr=$version"
    )
    & msbuild @msbuildArguments
    if ($LastExitCode) { throw "MSBuild failed" }

    $msi_path = join-path $cloudbaseInitInstallerDir "CloudbaseInitSetup\bin\Release\$platform\XylentisCloudbaseInitSetup.msi"

    if($SignX509Thumbprint)
    {
        ExecRetry {
            Write-Host "Signing MSI with certificate: $SignX509Thumbprint"
            signtool.exe sign /sha1 $SignX509Thumbprint /tr $SignTimestampUrl /td SHA256 /v $msi_path
            if ($LastExitCode) { throw "signtool failed" }
        }
    }
    else
    {
        Write-Warning "MSI not signed"
    }

    Remove-Item -Recurse -Force $python_dir
}
finally
{
    popd
}
