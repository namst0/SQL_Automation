<#
Author : Jakub Wolski
Script Description
This PowerShell script provides a robust automation solution for managing SQL Server Availability Groups (AG) specifically configured in Synchronous mode. It includes a variety of functions to assist database administrators in efficiently monitoring and manipulating database availability and failover processes. Key features include:
Features:
Presentation Dialog Boxes: Utilizes the Presentation Framework to prompt users before script execution, providing critical information about the script's operations and prerequisites.
Logging: Automatically starts logging activities and saves logs to C:\temp with a timestamped filename, facilitating easy tracking of operations and troubleshooting.
Instance Monitoring: Allows for specifying a monitoring instance to interact with your database environment and retrieve necessary data for automation tasks.
File Interaction: Includes a GUI for file selection to input server or instance names from an Excel file (XLSX format) which should contain only the server name or instance name in the first column without any headers.
Email Notifications: Capable of sending emails with details about which SQL instance is primary and which is secondary, enhancing communication and documentation during monitoring and failover procedures.
Failover Execution: Provides the capability to perform failovers to secondary instances in the AG setup. It includes conditions to handle exceptions and ensure the failover is appropriate given the current synchronization state of the databases.
Database Synchronization Check: After potential failovers, it checks and reports on databases that are not in a synchronized state, outputting this information both to the console and to an HTML file for records.

#>

#### Adding assemblies for presentation dialog boxes ################
Add-Type -AssemblyName 'PresentationFramework'

[System.Windows.MessageBox]::Show("Before you start you should read the following information:
- This script works only for AG which are in Synchronous availability mode. If there is an AG in asynchronous mode, you will get information and failover won't be performed.
- Please use only XLSX files without headers. The first column should contain only the server name or only the instance name.
- It provides information if an instance is not in an AG.
- Logs are saved in C:\temp")

######## START LOGGING ###########
$time = (Get-Date).ToString("yyyy.MM.dd.HH.MM.ss")
Start-Transcript -Path "C:\temp\Failover_log_$time.txt"

#### Monitoring instance Variable ##############
$MonitoringInstance = 'PUT_HERE_Your_Monitoring_Instance'
$listinstance = "Query to select from your monitoring database connections string based on server name"

## HTML style for body table
$head = @"
<style type="text/css">
BODY {background-color: white; font-size: 11px}
TABLE {border-width: 1px; border-style: solid; border-color: black; border-collapse: collapse;}
TD {border-width: 1px; padding: 5px; border-style: solid; border-color: black; background-color: white}
TH {border-width: 1px; padding: 5px; border-style: solid; border-color: black; background-color: LightBlue}
TR.red TD {background-color: #ffd7de; font-weight: bold}
TR.row0 TD {background-color: white}
TR.row1 TD {background-color: #F2F3F4}
</style>
"@

###### Function to open file with GUI #############
function Open-File([string]$initialDirectory) {
    [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null
    $OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $OpenFileDialog.initialDirectory = $initialDirectory
    $OpenFileDialog.filter = "All files (*.*)| *.*"
    $OpenFileDialog.ShowDialog() | Out-Null
    return $OpenFileDialog.filename
}

$OpenFile = Open-File $env:USERPROFILE 

if ($OpenFile -ne "") {
    Write-Host -ForegroundColor green "You chose FileName: $OpenFile"
} else {
    Write-host -ForegroundColor Red "No File was chosen, terminating script"
    Stop-Transcript
    exit
}

########### Countdown Function ################
Function Start-Sleep($seconds) {
    $doneDT = (Get-Date).AddSeconds($seconds)
    while ($doneDT -gt (Get-Date)) {
        $secondsLeft = $doneDT.Subtract((Get-Date)).TotalSeconds
        $percent = ($seconds - $secondsLeft) / $seconds * 100
        Write-Progress -Activity "Waiting Before checking if all databases are in synchronized state" -Status "Pausing..." -SecondsRemaining $secondsLeft -PercentComplete $percent
    }
    Write-Progress -Activity "Pausing" -Status "Pausing..." -SecondsRemaining 0 -Completed
}

########## Import xlsx file ################
[array]$List_Of_server = Import-Excel $OpenFile -HeaderName Instance -ImportColumns 1

$ConnectionString = @(foreach ($server in $List_Of_server.Instance) {
    Invoke-DbaQuery -SqlInstance $MonitoringInstance -Query $listinstance
})

########## Ask user dialog boxes ################
$caption = "EMAIL regarding Instance which is primary and which secondary"
$message = "Would you like to get an email regarding which instance is primary and which secondary?"
$message_Failover = "Would you like to perform failover to the secondary instance?"
$caption_Failover = "You will be performing FAILOVER, please be sure that you have the proper instance list"
$message_CheckDatabaseStatus = "Would you like to get an email with information regarding on which instance databases don't have synchronized status? If you select no, list will be sent to the console"
$caption_CheckDatabaseStatus = "Database status on instances which have been performed failover"

########## Process Availability Groups ################
$CheckAG = @(foreach ($SQLInstance in $ConnectionString.instance_fully_qualified_name) {
    Try {
        Get-DbaAvailabilityGroup -SqlInstance $SQLInstance -EnableException | select SQLInstance, ComputerName, AvailabilityGroup, LocalReplicaRole
    } catch {
        $servernamesingle = $SQLInstance.server_name
        $locationCSV2 = "C:\temp\Singleinstance.csv_$Time.csv"
        $SingleInstance = @(
            '"' + $SQLInstance + '","' + $servernamesingle + '"'
        )
        Write-Host -ForegroundColor red "Instance $SQLInstance is not in AO availability Groups, File saved in $locationCSV2"
        $SingleInstance | foreach {
            Add-Content -Path $locationCSV2 -Value $_
        }
    }
})

# Create XML object from above result and convert to HTML
[xml]$xmlObject = $CheckAG | ConvertTo-Html -Fragment

# Create HTML table for each row of result
for ($i=1; $i -le $xmlObject.table.tr.count-1; $i++) {
    $class = $xmlObject.CreateAttribute("class")
    $class.value = "row$($i % 2)"
    $xmlObject.table.tr[$i].attributes.append($class) | out-null
}

$body = @"
<a href='shorturl.at/mqsCS'>WI Mail Check</a>
<span style='font-size: 14px; color: black; font-weight:bold; display:inline'> List of instance PRIMARY/SECONDARY: </span>
$($xmlObject.OuterXml)
"@
$xmlOutput = [xml](ConvertTo-Html -Head $head -Body $body)
$xmlOutput.html.body.LastChild.ParentNode.RemoveChild($xmlOutput.html.body.LastChild) | Out-Null
$tekstMail = $xmlOutput.OuterXml

####### Email Configuration #####
$fromEmail = new-object System.Net.Mail.MailAddress("Test@gmail.com")
$smtpServer = "smtprelay-nl.unix.corp"
$mailSubject = [string]::Format("List of Instance PRIMARY/SECONDARY", (Get-Date).ToString("yyyy-MM-dd"))
$mailPriority = [System.Net.Mail.MailPriority]::Normal

$continue = [System.Windows.MessageBox]::Show($message, $caption, 'YesNo')

if ($continue -eq 'Yes') {
    if ($CheckAG) {
        Send-MailMessage -To jakub@gmail.com -From $fromEmail -SmtpServer $smtpServer -Priority $mailPriority -Subject $mailSubject -BodyAsHtml ($tekstMail | Out-String)
    }
} else {
    Write-host -ForegroundColor Red -BackgroundColor Yellow "Email regarding instance PRIMARY/SECONDARY has not been sent"
}

########## Get list of secondary ################
$ListOfSecondary = $CheckAG | Where-Object LocalReplicaRole -eq 'Secondary'

################### Ask user if he wants to perform failover ################
$continue_failover = [System.Windows.MessageBox]::Show($message_failover, $caption_failover, 'YesNo')

############### Perform failover if 'Yes' chosen ################
if ($continue_failover -eq 'Yes') {
    foreach ($secondary in $ListOfSecondary) {
        try {
            $SQLInstanceFailover = $Secondary.SqlInstance
            $AGgroup = $Secondary.AvailabilityGroup
            Invoke-DbaAgFailover -SqlInstance $SQLInstanceFailover -AvailabilityGroup $AGgroup -Confirm:$false -EnableException | out-null
            Write-Host -ForegroundColor green "Failover with success to $SQLInstanceFailover for availability group $AGgroup"
        } catch {
            $SQLInstanceFailover = $Secondary.SqlInstance
            $AGgroup = $Secondary.AvailabilityGroup
            $servername = $secondary.ComputerName
            $locationCSV = "C:\temp\Failed_failovers_$time.csv"
            $FailedFailover = @(
                '"' + $SQLInstanceFailover + '","' + $AGgroup + '","' + $servername + '"'
            )
            $FailedFailover | foreach {
                Add-Content -Path $locationCSV -Value $_
                Write-Host -ForegroundColor Red "Failover to Instance $SQLInstanceFailover and availability group $AGgroup failed, it's probably because replicas are set to async mode or databases are not in synchronized state. Generated file $locationCSV"
            }
        }
    }
} else {
    Write-host -ForegroundColor Red "Terminating Script"
    Stop-Transcript
    exit
}

########## Countdown waiting 120 seconds to check ################
Start-Sleep 120

########### Check if some databases are not in synchronized state ################
$CheckDatabasesStatus = $null;
$CheckDatabasesStatus = @(foreach ($CheckDatabaseInstance in $CheckAG.SQLInstance) {
    Get-DbaAgDatabase $CheckDatabaseInstance | select SQLinstance, AvailabilityGroup, Name, SynchronizationState | Where-Object SynchronizationState -ne 'Synchronized'
})

# Check database status to output
if ($CheckDatabasesStatus -ne $null) {
    $CheckDatabasesStatus | Format-Table
    # Check database status to HTML file
    $CheckDatabasesStatus | ConvertTo-Html -Head $head | Out-File -FilePath "C:\temp\Databases_Without_Status_Synchronized_$time.html"
    Write-Host -ForegroundColor Yellow "Database status saved to: C:\temp\Databases_Without_Status_Synchronized_$time.html"
} else {
    Write-host -ForegroundColor Green "All databases are in synchronized state"
}

# Stop logging
Stop-Transcript
