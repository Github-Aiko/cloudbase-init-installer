function CheckRemoveDir($path)
{
    if (Test-Path $path) {
        Remove-Item -Recurse -Force $path
    }
}

function CheckCopyDir($src, $dest)
{
    CheckRemoveDir $dest
    Copy-Item $src $dest -Recurse
}

function CheckDir($path)
{
    if (!(Test-Path -path $path))
    {
        mkdir $path
    }
}

function GitClonePull($path, $url, $branch="master")
{
    Write-Host "Cloning / pulling: $url"

    $needspull = $true

    if (!(Test-Path -path $path))
    {
        git clone -b $branch $url
        if ($LastExitCode) { throw "git clone failed" }
        $needspull = $false
    }

    if ($needspull)
    {
        pushd .
        try
        {
            cd $path

            $branchFound = (git branch)  -match "(.*\s)?$branch"
            if ($LastExitCode) { throw "git branch failed" }

            if($branchFound)
            {
                git checkout $branch
                if ($LastExitCode) { throw "git checkout failed" }
            }
            else
            {
                git checkout -b $branch origin/$branch
                if ($LastExitCode) { throw "git checkout failed" }
            }

            git reset --hard
            if ($LastExitCode) { throw "git reset failed" }

            git clean -f -d
            if ($LastExitCode) { throw "git clean failed" }

            git pull
            if ($LastExitCode) { throw "git pull failed" }
        }
        finally
        {
            popd
        }
    }
}

function PullInstall($path, $url, $branch="master")
{
    GitClonePull $path $url $branch

    pushd .
    try
    {
        cd $path

        # Remove build directory
        CheckRemoveDir "build"

        # Remove Python compiled files
        Get-ChildItem  -include "*.pyc" -recurse | foreach ($_) {remove-item $_.fullname}

        PipInstall .
    }
    finally
    {
        popd
    }
}

function CreateZip($zipPath, $path)
{
    if (Test-Path $zipPath) {
        Remove-Item -Force $zipPath
    }

    $sevenZipCommand = Get-Command 7z.exe -ErrorAction SilentlyContinue
    $sevenZipPath = if ($sevenZipCommand) {
        $sevenZipCommand.Source
    }
    else {
        @(
            "$env:ProgramFiles\7-Zip\7z.exe",
            "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
        ) | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
    }

    if ($sevenZipPath) {
        Write-Host "Creating ZIP with $sevenZipPath"
        & $sevenZipPath a -tzip -mx=9 -r $zipPath $path
        if ($LastExitCode) {
            throw "7-Zip failed to create archive: $zipPath"
        }
    }
    else {
        Write-Host "7-Zip not found; using Compress-Archive"
        Compress-Archive -Path $path -DestinationPath $zipPath -CompressionLevel Optimal
    }

    if (!(Test-Path $zipPath -PathType Leaf)) {
        throw "Failed to create ZIP archive: $zipPath"
    }
}

function Expand7z($archive, $outputDir = ".")
{
    pushd .
    try
    {
        cd $outputDir
        &7z.exe x -y $archive
        if ($LastExitCode) { throw "7z.exe failed on archive: $archive"}
    }
    finally
    {
        popd
    }
}

function PullRelease($project, $release, $version)
{
    pushd .
    try
    {
        $projectVer = "$project-$version"
        $tarFile = "$projectVer.tar"
        $tgzFile = "$tarFile.gz"
        $url = "https://launchpad.net/$project/$release/$version/+download/$tgzFile"

        DownloadFile $url "$pwd\$tgzFile"

        Expand7z $tgzFile
        Remove-Item -Force $tgzFile
        cd ".\dist"
        CheckRemoveDir $projectVer
        Expand7z $tarFile
        Remove-Item -Force $tarFile
    }
    finally
    {
        popd
    }
}

function InstallRelease($project, $version)
{
    pushd .
    try
    {
        $projectVer = "$project-$version"
        cd ".\dist"
        cd $projectVer
        PipInstall .
        cd ..
        Remove-Item -Recurse -Force $projectVer
    }
    finally
    {
        popd
    }
}

function PullInstallRelease($project, $release, $version)
{
    PullRelease $project $release $version
    InstallRelease $project $version
}

function PipInstall($package, $allow_dev=$false, $update=$false)
{
    $dev = ""
    if ($allow_dev) {
        $dev = "--pre"
    }

    $u = ""
    if($update) {
        $u = "-U"
    }

    python -m pip install $dev $u $package
    if ($LastExitCode) { throw "pip install $dev failed on package: $package" }
}

function SetVCVars($version="2019", $platform="x86_amd64") {
    $preferredVersions = @("$version")
    if ($version -eq "automatic") {
        $preferredVersions = @("18", "2022", "2019", "2017")
    }
    $vsInstallTypes = @("Community", "Enterprise", "BuildTools")
    $vsInstallArchTypes = @("${ENV:ProgramFiles(x86)}", "$ENV:ProgramFiles")
    $vcvarsAll = $null

    if ($version -eq "automatic") {
        $vswhere = "${ENV:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path $vswhere -PathType Leaf) {
            $vcvarsAll = & $vswhere -latest -products * `
                -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                -find "VC\Auxiliary\Build\vcvarsall.bat" |
                Select-Object -First 1
        }
    }

    if (!$vcvarsAll) {
        :VisualStudioSearch foreach ($vsInstallArchType in $vsInstallArchTypes) {
            foreach ($vsInstallType in $vsInstallTypes) {
                foreach ($preferredVersion in $preferredVersions) {
                    $candidate = "${vsInstallArchType}\Microsoft Visual Studio\${preferredVersion}\${vsInstallType}\VC\Auxiliary\Build\vcvarsall.bat"
                    if (Test-Path $candidate -PathType Leaf) {
                        $vcvarsAll = $candidate
                        break VisualStudioSearch
                    }
                    Write-Host "${candidate} does not exist"
                }
            }
        }
    }

    if (!$vcvarsAll) {
        throw "Microsoft Visual C++ 14.0+ has not been found. Install the Visual Studio 'Desktop development with C++' workload (Microsoft.VisualStudio.Workload.VCTools)."
    }

    Write-Host "Loading Visual Studio environment from $vcvarsAll"
    pushd (Split-Path $vcvarsAll -Parent)
    try {
        $visualStudioEnvironment = cmd.exe /d /c "vcvarsall.bat $platform && set"
        if ($LastExitCode) {
            throw "vcvarsall.bat failed with exit code $LastExitCode"
        }
    }
    finally {
        popd
    }

    foreach ($line in $visualStudioEnvironment) {
        if ($line -notmatch "^[^=][^=]*=") {
            continue
        }
        $name, $value = $line -split "=", 2
        Set-Item -Force -Path "ENV:\$name" -Value $value
    }

    if (!(Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        throw "vcvarsall.bat completed, but cl.exe is unavailable. Repair the Visual C++ x64/x86 build tools workload."
    }
}

function ReplaceVSToolSet($toolset)
{
    Get-ChildItem -Filter *.vcxproj -Recurse |
    Foreach-Object {
        $vcxprojfile = $_.FullName
        (Get-Content $vcxprojfile) |
        Foreach-Object {$_ -replace "<PlatformToolset>[^<]+</PlatformToolset>", "<PlatformToolset>$toolset</PlatformToolset>"} |
        Set-Content $vcxprojfile
    }
}

function SetRuntimeLibrary($runtimeLibrary)
{
    Get-ChildItem -Filter *.vcxproj -Recurse |
    Foreach-Object {
        $vcxprojfile = $_.FullName
        (Get-Content $vcxprojfile) |
        Foreach-Object {$_ -replace "<RuntimeLibrary>[^<]+</RuntimeLibrary>", "<RuntimeLibrary>$runtimeLibrary</RuntimeLibrary>"} |
        Set-Content $vcxprojfile
    }
}

function PatchFromGitCommit($sourcePath, $destPath, $gitRef, $gerritUrl, $gerritRef, $filesToPatch)
{
    pushd .
    try
    {
        pushd .
        cd $sourcePath

        if ($gerritUrl)
        {
            &git fetch $gerritUrl $gerritRef
            if ($LastExitCode) { throw "git fetch failed for Gerrit patchset: $gerritUrl $gerritRef" }
            $gitRef = "FETCH_HEAD"
        }

        $patch = &git format-patch -1 --stdout $gitRef -- $filesToPatch
        if ($LastExitCode) { throw "git format-patch failed for commit: $gitRef" }
        popd

        cd $destPath
        $patch -join "`n" | &patch -p1
        if ($LastExitCode) { throw "patch failed for commit: $gitRef" }
    }
    finally
    {
        popd
    }
}

function PatchRelease($project, $version, $gitRef, $gerritUrl, $gerritRef, $filesToPatch)
{
    $destPath = ".\dist\$project-$version"
    PatchFromGitCommit $project $destPath $gitRef $gerritUrl $gerritRef $filesToPatch
}

function ExecRetry($command, $maxRetryCount = 10, $retryInterval=2)
{
    $currErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $retryCount = 0
    while ($true)
    {
        try
        {
            & $command
            break
        }
        catch [System.Exception]
        {
            $retryCount++
            if ($retryCount -ge $maxRetryCount)
            {
                $ErrorActionPreference = $currErrorActionPreference
                throw
            }
            else
            {
                Write-Error $_.Exception
                Start-Sleep $retryInterval
            }
        }
    }

    $ErrorActionPreference = $currErrorActionPreference
}

function GetCredentialsFromFile($path)
{
    # To populate the credentials file use:
    # $username | Out-File $path
    # read-host -assecurestring | convertfrom-securestring | Add-Content $path

    $data = Get-Content $path
    $username = $data[0]
    $securePass = $data[1] | convertto-securestring
    return new-object -typename System.Management.Automation.PSCredential -argumentlist $username,$securePass
}

function RunCommand($cmd, $arguments, $expectedExitCode = 0)
{
    Write-Host "Executing: $cmd $arguments"

    $p = Start-Process -Wait -PassThru -NoNewWindow $cmd -ArgumentList $arguments
    if($p.ExitCode -ne $expectedExitCode)
    {
        throw "$cmd failed with exit code: $($p.ExitCode)"
    }
}

function DownloadFile($url, $dest)
{
    Write-Host "Downloading: $url"

    $webClient = New-Object System.Net.webclient
    $webClient.DownloadFile($url, $dest)
}

function DownloadInstall($url, $type, $arguments="")
{
    $guid = [System.Guid]::NewGuid().ToString()
    $path = "$guid.$type"

    try
    {

        ExecRetry { DownloadFile $url $path }
        if($type -eq "msi")
        {
            if(!$arguments)
            {
                $arguments = "/qn"
            }
            ExecRetry { RunCommand "msiexec.exe" "/i $path $arguments" }
        }
        else
        {
            ExecRetry { RunCommand $path $arguments }
        }
    }
    finally
    {
        if(test-Path $path) { del $path }
    }
}

function ChocolateyInstall($package)
{
    ExecRetry {
        &cinst $package
        if($lastexitcode)
        {
            throw "cinst failed with exit code: $lastexitcode"
        }
    }
}

function ImportCertificateUser($pfxPath, $pfxPassword) {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::My,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfxPath, $pfxPassword,
        ([System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet -bor
         [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet))
    $store.Add($cert)

    return $cert.Thumbprint
}

function ChechFileHash($path, $hash, $algorithm="SHA1") {
    $actualHash = (Get-Filehash -Algorithm $algorithm $path).Hash.ToUpper()
    if ($actualHash -ne $hash.ToUpper()) {
        throw "Hash comparison failed for file: $path. Expected hash: ${hash}. Actual hash: ${actualHash}"
    }
}


function DownloadInstall-PythonMsi($platform, $python_template_dir, $pythonVersion, $PythonMsiChecksum, $algorithm="SHA1") {
    $platformSuffix = ""
    if ($platform -eq "x64") {
      $platformSuffix = "-amd64"
    }

    if (Test-Path $python_template_dir) {
      throw "$python_template_dir folder already exists"
    }

    $pythonInstallerPath = Join-Path (Resolve-Path "${python_template_dir}/..").Path "/python-${pythonVersion}${platformSuffix}.exe"
    $pythonVersionEscaped = $pythonVersion.replace("_",".")
    $PythonMsiUrl = "https://www.python.org/ftp/python/${pythonVersionEscaped}/python-${pythonVersionEscaped}${platformSuffix}.exe"

    if ($python_template_dir -and (Test-Path $python_template_dir)) {
      throw "Python template directory already exists"
    }

    $tmp_python_template_dir = "${python_template_dir}_tmp"
    if ($tmp_python_template_dir -and (Test-Path $tmp_python_template_dir)) {
      throw "Python temp template directory already exists"
    }

    try {
        ExecRetry { DownloadFile $PythonMsiUrl $pythonInstallerPath }
        ChechFileHash $pythonInstallerPath $PythonMsiChecksum $algorithm

        Write-Host "Trying to uninstall Python using $pythonInstallerPath"
        Start-Process -FilePath "${pythonInstallerPath}" -NoNewWindow -Wait `
            -ArgumentList @("/quiet", "/uninstall")

        $package = Get-Package -Name "Python ${pythonVersionEscaped}*" -ErrorAction SilentlyContinue
        if ($package) {
          throw "Python package was already installed"
        }

        Write-Host "Installing Python using $pythonInstallerPath"
        Start-Process -FilePath "${pythonInstallerPath}" -NoNewWindow -Wait `
            -ArgumentList @("/quiet", "TargetDir=${tmp_python_template_dir}","Include_test=0","Include_tcltk=0","Include_launcher=0","Include_doc=0")

        Copy-Item -Recurse $tmp_python_template_dir $python_template_dir

     } finally {

        Start-Process -FilePath "${pythonInstallerPath}" -NoNewWindow -Wait `
            -ArgumentList @("/quiet", "/uninstall")

        if (Test-Path $pythonInstallerPath) {
            Remove-Item $pythonInstallerPath
        }

        if (Test-Path $tmp_python_template_dir) {
            Remove-Item $tmp_python_template_dir -Recurse -Force
        }
      }
      if (!(Test-Path $python_template_dir)) {
        throw "$python_template_dir has not been created"
      }

}

function DownloadInstall-PythonUsingPyManager($platform, $python_template_dir, $pythonVersion) {
    $pythonManagerUrl = "https://www.python.org/ftp/python/pymanager/python-manager-26.3.msi"
    $pythonManagerPath = Join-Path (Resolve-Path "${python_template_dir}/..").Path "/python-manager.msi"
    $pythonManagerInstallLog = Join-Path (Resolve-Path "${python_template_dir}/..").Path "/python-manager.log"
    $pymanagerPath = "C:\Program Files\PyManager\pymanager.exe"

    Get-Package "Python Install Manager" -ErrorAction SilentlyContinue | Uninstall-Package

    ExecRetry { DownloadFile $pythonManagerUrl $pythonManagerPath }
    cmd /c msiexec -i "${pythonManagerPath}" /qn /l*v "${pythonManagerInstallLog}"

    $pythonManagerExists = Get-Command $pymanagerPath -ErrorAction SilentlyContinue
    if (!$pythonManagerExists) {
        throw "Failed to install Python Manager"
    }

    $platformSuffix = ""
    if ($platform -eq "x86") {
        $platformSuffix = "-32"
    }
    if ($platform -eq "arm64") {
        $platformSuffix = "-arm64"
    }

    if (Test-Path $python_template_dir) {
        throw "$python_template_dir folder already exists"
    }

    $pythonVersionEscaped = $pythonVersion.replace("_",".") + $platformSuffix
    & "${pymanagerPath}" install --target=$python_template_dir --force --update $pythonVersionEscaped
    if ($LASTEXITCODE) {
        throw "Failed to install python in directory: ${python_template_dir}"
    }

    if (!(Test-Path $python_template_dir)) {
        throw "$python_template_dir has not been created"
    }

    & "$python_template_dir/python.exe" --version
    if ($LASTEXITCODE) {
        throw "Failed to run python in directory: ${python_template_dir}"
    }

    Remove-Item -Force -Recurse "$python_template_dir/DLLs/_tkinter.pyd"
    Remove-Item -Force -Recurse "$python_template_dir/DLLs/tcl*.dll"
    Remove-Item -Force -Recurse "$python_template_dir/DLLs/tk*.dll"
    Remove-Item -Force -Recurse "$python_template_dir/Doc"
    Remove-Item -Force -Recurse "$python_template_dir/Lib/tkinter"
    Remove-Item -Force -Recurse "$python_template_dir/Lib/turtle.py"
    Remove-Item -Force -Recurse "$python_template_dir/Lib/turtledemo"
    Remove-Item -Force -Recurse "$python_template_dir/tcl"
}
