# Demo 'Powershell' Notification for Paessler Network Monitor
# Writes current Date/Time into a File
# 
# How to use it:
# 
# Create a exe-notification on PRTG, select 'Demo Exe Notifcation - OutFile.ps1' as program.
# The output file will be created in the PRTG data folder which is usually located at
# "C:\ProgramData\Paessler\PRTG Network Monitor\Demo Notification".
# 
# Adapt Errorhandling to your needs.
# This script comes without warranty or support.

$path = $env:programdata + "\Paessler\PRTG Network Monitor\Demo Notification";
If(!(test-path $path))
{
      New-Item -ItemType Directory -Force -Path $path
}
Get-Date | Out-File ($path + "\demo-ps.txt");
exit 0;
