#requires -RunAsAdministrator
#requires -Version 5.1
<# NorthLine lab. Fresh Windows Server 2022 Desktop Experience only.
Run Prepare, reboot, Forest, reboot, Services. No automatic disk formatting.
LabFlat has one NIC and no gateway. Routed requires a real reachable gateway.
#>
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidateSet('Prepare','Forest','Services')][string]$Phase,
 [Parameter(Mandatory)][string]$InterfaceAlias,
 [ValidateSet('LabFlat','Routed')][string]$Mode = 'LabFlat',
 [string]$BackupRoot = 'E:\NorthLineBackup'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Domain = 'northline.local'
$ServerIP = '10.1.20.10'
$LinuxIP = '10.1.20.20'
$nic = Get-NetAdapter -Name $InterfaceAlias -ErrorAction Stop
if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) { throw 'Windows Server required.' }
if ($Phase -eq 'Prepare') {
 $up = @(Get-NetAdapter | Where-Object Status -eq 'Up')
 if ($up.Count -ne 1) { throw 'Use only the isolated lab NIC; disconnect other NICs first.' }
 $existing = @(Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254.*' })
 if (@($existing | Where-Object IPAddress -ne $ServerIP).Count) { throw 'Unexpected static address. Review NIC manually before continuing.' }
 Set-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -Dhcp Disabled
 if (-not ($existing | Where-Object IPAddress -eq $ServerIP)) {
  $p = @{InterfaceIndex=$nic.ifIndex;IPAddress=$ServerIP;PrefixLength=24}
  if ($Mode -eq 'Routed') { $p.DefaultGateway = '10.1.20.1' }
  New-NetIPAddress @p | Out-Null
 }
 Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $ServerIP
 if ($env:COMPUTERNAME -ne 'WIN-SRV01') { Rename-Computer -NewName 'WIN-SRV01' -Force }
 Write-Host 'Prepare complete. Restart-Computer, then run -Phase Forest.'
 exit
}
if ($env:COMPUTERNAME -ne 'WIN-SRV01') { throw 'Run Prepare and restart first.' }
if (-not (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 | Where-Object IPAddress -eq $ServerIP)) { throw 'Expected server address is missing.' }
if ($Phase -eq 'Forest') {
 if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) { throw 'Already a DC. Use Services.' }
 Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
 Import-Module ADDSDeployment
 $dsrm = Read-Host 'Enter a unique DSRM recovery password' -AsSecureString
 Install-ADDSForest -DomainName $Domain -DomainNetbiosName NORTHLINE -InstallDns -SafeModeAdministratorPassword $dsrm -NoRebootOnCompletion:$true -Force
 Write-Host 'Forest created. Restart-Computer, sign in as NORTHLINE\Administrator, run Services.'
 exit
}
Import-Module ActiveDirectory
if ((Get-ADDomain).DNSRoot -ne $Domain) { throw 'Wrong domain.' }
if (-not (Test-Path (Split-Path -Qualifier $BackupRoot))) { throw 'Prepare a separate backup volume (E: by default); nothing will be formatted by this script.' }
Install-WindowsFeature DHCP,FS-FileServer,Print-Server,Windows-Server-Backup -IncludeManagementTools | Out-Null
Import-Module DhcpServer
Import-Module DnsServer
if (-not (Get-DhcpServerInDC | Where-Object IPAddress -eq $ServerIP)) { Add-DhcpServerInDC -DnsName "WIN-SRV01.$Domain" -IPAddress $ServerIP }
Get-DhcpServerv4Binding | ForEach-Object { Set-DhcpServerv4Binding -InterfaceAlias $_.InterfaceAlias -BindingState ($_.InterfaceAlias -eq $InterfaceAlias) }
# Only the SERVER subnet is active in the flat lab. Routed scopes need real relays.
$scopes = if ($Mode -eq 'LabFlat') {
 @(@{Id='10.1.20.0';Start='10.1.20.100';End='10.1.20.199';Mask='255.255.255.0';GW=$null;Name='LAB-SERVER'})
} else {
 $s = @()
 foreach ($v in @(30,40,50,60,70)) { $s += @{Id="10.1.$v.0";Start="10.1.$v.50";End="10.1.$v.199";Mask='255.255.255.0';GW="10.1.$v.1";Name="HQ-$v"} }
 $s += @{Id='10.2.30.0';Start='10.2.30.10';End='10.2.30.62';Mask='255.255.255.192';GW='10.2.30.1';Name='DEB-ADMIN'}
 $s += @{Id='10.2.50.0';Start='10.2.50.10';End='10.2.50.126';Mask='255.255.255.128';GW='10.2.50.1';Name='DEB-LOG'}
 $s += @{Id='10.3.30.0';Start='10.3.30.10';End='10.3.30.30';Mask='255.255.255.224';GW='10.3.30.1';Name='NYH-ADMIN'}
 $s
}
foreach ($s in $scopes) {
 if (-not (Get-DhcpServerv4Scope | Where-Object { $_.ScopeId.IPAddressToString -eq $s.Id })) {
  Add-DhcpServerv4Scope -Name $s.Name -StartRange $s.Start -EndRange $s.End -SubnetMask $s.Mask -State Active | Out-Null
 }
 Set-DhcpServerv4OptionValue -ScopeId $s.Id -DnsDomain $Domain -DnsServer $ServerIP
 if ($s.GW) { Set-DhcpServerv4OptionValue -ScopeId $s.Id -Router $s.GW }
}
# Bind is a secondary DNS; Windows clients deliberately use the writable AD DNS.
foreach ($z in @($Domain,"_msdcs.$Domain")) {
 Set-DnsServerPrimaryZone -Name $z -SecureSecondaries TransferToSecureServers -SecondaryServers $LinuxIP -Notify NotifyServers -NotifyServers $LinuxIP
}
foreach ($name in @('lnx-srv01','www')) {
 $rr = @(Get-DnsServerResourceRecord -ZoneName $Domain -Name $name -RRType A -ErrorAction SilentlyContinue)
 if ($rr.Count -eq 0) { Add-DnsServerResourceRecordA -ZoneName $Domain -Name $name -IPv4Address $LinuxIP }
 elseif (@($rr | Where-Object { $_.RecordData.IPv4Address.IPAddressToString -ne $LinuxIP }).Count) { throw "Conflicting DNS record: $name" }
}
$base = (Get-ADDomain).DistinguishedName
$ou = "OU=NorthLine,$base"
if (-not (Get-ADOrganizationalUnit -LDAPFilter '(ou=NorthLine)' -SearchBase $base -SearchScope OneLevel)) { New-ADOrganizationalUnit -Name NorthLine -Path $base }
foreach ($g in @('GG_Admin','GG_Sales')) {
 if (-not (Get-ADGroup -Filter "SamAccountName -eq '$g'")) { New-ADGroup -Name $g -SamAccountName $g -GroupScope Global -GroupCategory Security -Path $ou }
}
foreach ($u in @(@{Name='anna.admin';Group='GG_Admin'},@{Name='bela.sales';Group='GG_Sales'})) {
 if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Name)'")) {
  $pw = Read-Host "Unique initial password for $($u.Name)" -AsSecureString
  New-ADUser -Name $u.Name -SamAccountName $u.Name -UserPrincipalName "$($u.Name)@$Domain" -Path $ou -Enabled $true -AccountPassword $pw -ChangePasswordAtLogon $true
 }
 Add-ADGroupMember -Identity $u.Group -Members $u.Name
}
$adminSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$admins = $adminSid.Translate([System.Security.Principal.NTAccount]).Value
foreach ($share in @(@{Name='Kozos';Groups=@('GG_Admin','GG_Sales')},@{Name='Admin';Groups=@('GG_Admin')})) {
 $path = "C:\NorthLine\$($share.Name)"
 New-Item -ItemType Directory -Force -Path $path | Out-Null
 $acl = New-Object System.Security.AccessControl.DirectorySecurity
 $acl.SetAccessRuleProtection($true,$false)
 foreach ($sid in @($adminSid,$systemSid)) { $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')) }
 foreach ($group in $share.Groups) { $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new("NORTHLINE\$group",'Modify','ContainerInherit,ObjectInherit','None','Allow')) }
 Set-Acl -Path $path -AclObject $acl
 $accounts = @($share.Groups | ForEach-Object { "NORTHLINE\$_" })
 if (-not (Get-SmbShare -Name $share.Name -ErrorAction SilentlyContinue)) { New-SmbShare -Name $share.Name -Path $path -FullAccess $admins -ChangeAccess $accounts -FolderEnumerationMode AccessBased | Out-Null }
}
New-Item -ItemType Directory -Force -Path C:\NorthLineTools,$BackupRoot | Out-Null
# Daily file backup, new directory each run, no mirror/delete operation.
$backupCode = @'
$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$root = '__BACKUPROOT__'
$dest = Join-Path $root $stamp
New-Item -ItemType Directory -Path $dest | Out-Null
$logFile = Join-Path $dest 'robocopy.log'
& robocopy.exe C:\NorthLine (Join-Path $dest 'Files') /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ "/LOG:$logFile"
if ($LASTEXITCODE -ge 8) { throw "Robocopy failed: $LASTEXITCODE" }
Export-DhcpServer -File (Join-Path $dest 'dhcp.xml') -Leases -Force
Get-SmbShare | Select-Object Name,Path | Export-Clixml (Join-Path $dest 'shares.xml')
'@
$backupCode.Replace('__BACKUPROOT__',$BackupRoot.Replace("'","''")) | Set-Content C:\NorthLineTools\backup.ps1 -Encoding UTF8
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\NorthLineTools\backup.ps1'
$t = New-ScheduledTaskTrigger -Daily -At '21:00'
$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName NorthLine-Backup -Action $a -Trigger $t -Principal $p -Force | Out-Null
New-NetFirewallRule -Name NorthLine-ICMPv4 -DisplayName NorthLine-ICMPv4 -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow -RemoteAddress 10.0.0.0/8 -ErrorAction SilentlyContinue | Out-Null
Write-Host 'Services configured. Complete printer setup and client tests in VM2/VM4. No tests have been claimed as passed.'
