﻿if (!(Test-Path function:Log)) {
    function Log([string]$line, [string]$color = "Gray") {
        ("<font color=""$color"">" + [DateTime]::Now.ToString([System.Globalization.DateTimeFormatInfo]::CurrentInfo.ShortTimePattern.replace(":mm",":mm:ss")) + " $line</font>") | Add-Content -Path "c:\demo\status.txt"
        Write-Host -ForegroundColor $color $line 
    }
}

Import-Module -name navcontainerhelper -DisableNameChecking

. (Join-Path $PSScriptRoot "settings.ps1")

$imageName = $navDockerImage.Split(',')[0]

docker ps --filter name=$containerName -a -q | % {
    Log "Removing container $containerName"
    docker rm $_ -f | Out-Null
}

$exist = $false
docker images -q --no-trunc | % {
    $inspect = docker inspect $_ | ConvertFrom-Json
    if ($inspect.RepoTags | Where-Object { "$_" -eq "$imageName" -or "$_" -eq "${imageName}:latest"}) { $exist = $true }
}
if (!$exist) {
    docker pull $imageName
}
$inspect = docker inspect $imageName | ConvertFrom-Json
$country = $inspect.Config.Labels.country
$navVersion = $inspect.Config.Labels.version
$nav = $inspect.Config.Labels.nav
$cu = $inspect.Config.Labels.cu
$locale = Get-LocaleFromCountry $country

if ($nav -eq "devpreview") {
    $title = "Dynamics 365 ""Tenerife"" Preview Environment"
} elseif ($nav -eq "main") {
    $title = "Dynamics 365 ""Tenerife"" Preview Environment"
} else {
    $title = "Dynamics NAV $nav Demonstration Environment"
}

Log "Using image $imageName"
Log "Country $country"
Log "Version $navVersion"
Log "Locale $locale"

$securePassword = ConvertTo-SecureString -String $adminPassword -Key $passwordKey
$credential = New-Object System.Management.Automation.PSCredential($navAdminUsername, $securePassword)
$additionalParameters = @("--publish  8080:8080",
                          "--publish  443:443", 
                          "--publish  7046-7049:7046-7049", 
                          "--env publicFileSharePort=8080",
                          "--env PublicDnsName=$publicdnsName",
                          "--env RemovePasswordKeyFile=N"
                          )
if ("$appBacpacUri" -ne "" -and "$tenantBacpacUri" -ne "") {
    $additionalParameters += @("--env appbacpac=$appBacpacUri",
                               "--env tenantbacpac=$tenantBacpacUri")
}

$mt = $false
if ($multitenant -eq "Yes") {
    $mt = $true
}

$myScripts = @()
Get-ChildItem -Path "c:\myfolder" | % { $myscripts += $_.FullName }

Log "Running $imageName (this will take a few minutes)"
New-NavContainer -accept_eula `
                 -containerName $containerName `
                 -useSSL `
                 -auth NavUserPassword `
                 -includeCSide `
                 -doNotExportObjectsToText `
                 -credential $credential `
                 -additionalParameters $additionalParameters `
                 -myScripts $myscripts `
                 -imageName $imageName `
                 -multitenant:$mt

if (Test-Path "c:\demo\objects.fob" -PathType Leaf) {
    Log "Importing c:\demo\objects.fob to container"
    $sqlCredential = New-Object System.Management.Automation.PSCredential ( "sa", $credential.Password )
    Import-ObjectsToNavContainer -containerName $containerName -objectsFile "c:\demo\objects.fob" -sqlCredential $sqlCredential
}

# Copy .vsix and Certificate to container folder
$containerFolder = "C:\ProgramData\navcontainerhelper\Extensions\$containerName"
Log "Copying .vsix and Certificate to $containerFolder"
docker exec -it $containerName powershell "copy-item -Path 'C:\Run\*.vsix' -Destination '$containerFolder' -force
copy-item -Path 'C:\Run\*.cer' -Destination '$containerFolder' -force
copy-item -Path 'C:\Program Files\Microsoft Dynamics NAV\*\Service\CustomSettings.config' -Destination '$containerFolder' -force
if (Test-Path 'c:\inetpub\wwwroot\http\NAV' -PathType Container) {
    [System.IO.File]::WriteAllText('$containerFolder\clickonce.txt','http://${publicDnsName}:8080/NAV')
}"
[System.IO.File]::WriteAllText("$containerFolder\Version.txt",$navVersion)
[System.IO.File]::WriteAllText("$containerFolder\Cu.txt",$cu)
[System.IO.File]::WriteAllText("$containerFolder\Country.txt", $country)
[System.IO.File]::WriteAllText("$containerFolder\Title.txt",$title)

# Install Certificate on host
$certFile = Get-Item "$containerFolder\*.cer"
if ($certFile) {
    $certFileName = $certFile.FullName
    Log "Importing $certFileName to trusted root"
    $pfx = new-object System.Security.Cryptography.X509Certificates.X509Certificate2 
    $pfx.import($certFileName)
    $store = new-object System.Security.Cryptography.X509Certificates.X509Store([System.Security.Cryptography.X509Certificates.StoreName]::Root,"localmachine")
    $store.open("MaxAllowed") 
    $store.add($pfx) 
    $store.close()
}

Log -color Green "Container output"
docker logs $containerName | % { log $_ }

Log -color Green "Container setup complete!"
