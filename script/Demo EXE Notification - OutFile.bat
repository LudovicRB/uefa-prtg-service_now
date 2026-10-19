REM Demo 'BAT' Notification for Paessler Network Monitor
REM Writes current Date/Time into a File
REM
REM How to use it:
REM
REM Create a exe-notification on PRTG, select 'Demo Exe Notifcation - OutFile.bat' as program.
REM The output file will be created in the PRTG data folder which is usually located at
REM "C:\ProgramData\Paessler\PRTG Network Monitor\Demo Notification".
REM
REM Adapt Errorhandling to your needs.
REM This script comes without warranty or support.

SET OUTPUTPATH=%PROGRAMDATA%\Paessler\PRTG Network Monitor\Demo Notification
if not exist "%OUTPUTPATH%" mkdir "%OUTPUTPATH%"
Echo  %DATE% %TIME% > "%OUTPUTPATH%\demo-bat.txt"