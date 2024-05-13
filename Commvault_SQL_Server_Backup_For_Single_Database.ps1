<#
.DESCRIPTION
This script is designed to interact with a Commvault backup environment and SQL databases. 
It provides a graphical user interface (GUI) for initiating backups, listing previous backups, and checking the progress of ongoing backups.

Known BUG - if you perfrom full backup on CV for database and it have recovery model simple it wont perform backup

.NOTES
    Author: Jakub Wolski
    Version: 2.1
    Required Dependencies: dbatools, PowerShell module, cv module



#>

# Add necessary assemblies for WPF functionality.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Data

# Define the GUI layout using XAML.
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SingleDatabase Backup CV - Author Jakub Wolski" Height="450" Width="800">
    <Grid>
        <Label Content="Database:" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="79,60,0,0"/>
        <ComboBox x:Name="ListOfDatabases" HorizontalAlignment="Left" Height="30" Margin="79,87,0,0" VerticalAlignment="Top" Width="333"/>
        
        <Label Content="Backup Type:" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="467,60,0,0"/>
        <ComboBox x:Name="BackupType" Text="Choose Backup Type" HorizontalAlignment="Left" Height="30" Margin="467,87,0,0" VerticalAlignment="Top" Width="263">
            <ComboBoxItem Content="differential"/>
            <ComboBoxItem Content="full"/>
            <ComboBoxItem Content="incremental"/>
        </ComboBox>
        
        <Label Content="Console Name:" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="300,20,0,0"/>
        <ComboBox x:Name="CVConsole" Text="Console Name" HorizontalAlignment="Left" Height="30" Margin="300,40,0,0" VerticalAlignment="Top" Width="263">
            <ComboBoxItem Content="P00171.hosting.corp"/>
            <ComboBoxItem Content="P01309.hosting.corp"/>
        </ComboBox>
         <!-- Adding OK Button next to Console Name ComboBox -->
        <Button x:Name="OkButton" Content="Connect" HorizontalAlignment="Left" Height="30" Margin="568,40,0,0" VerticalAlignment="Top" Width="75" />
        
        <Label Content="SQL Instance without domain:" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="79,120,0,0"/>
        <TextBox x:Name="SqlInstanceName" HorizontalAlignment="Left" Height="30" Margin="79,147,0,0" VerticalAlignment="Top" Width="333"/>
        
        <Button x:Name="ListLastBackup" Content="List all last backups" HorizontalAlignment="Left" Height="33" Margin="480,207,0,0" VerticalAlignment="Top" Width="197"/>
        <Button x:Name="BackupDatabase" Content="Backup Database" HorizontalAlignment="Left" Height="33" Margin="262,207,0,0" VerticalAlignment="Top" Width="150"/>
        <Label x:Name="ProgressLabel" Content="Backup percent complete: 0%" HorizontalAlignment="Left" Margin="10,0,10,40" VerticalAlignment="Bottom"/>
        <Label x:Name="ProgressLabel2" Content="Estimated Time completion backup" HorizontalAlignment="center" Margin="10,0,10,40" VerticalAlignment="Bottom"/>
        <Button x:Name="Check" Content="Check Status Backup" HorizontalAlignment="Right" Height="30" Margin="540,20,0,0" VerticalAlignment="Bottom" Width="75" />
        <DataGrid x:Name="ResultsDataGrid" HorizontalAlignment="Left" Height="60" Margin="40,280,40,40" VerticalAlignment="Top" Width="700" AutoGenerateColumns="True"/>

    </Grid>
</Window>
"@

# Parsing the XAML
$reader = New-Object System.IO.StringReader $xaml
$xmlReader = [System.Xml.XmlReader]::Create($reader)
$window = [System.Windows.Markup.XamlReader]::Load($xmlReader)

# Access GUI elements by name for later manipulation.

$comboListOfDatabases = $window.FindName("ListOfDatabases")
$comboBackupType = $window.FindName("BackupType")
$comboCVConsole = $window.FindName("CVConsole")
$btnListLastBackup = $window.FindName("ListLastBackup")
$btnBackupDatabase = $window.FindName("BackupDatabase")
$textBoxSqlInstanceName = $window.FindName("SqlInstanceName")
$btnConnectToConsole =$window.FindName("OkButton")
$comboListOfConsole = $window.FindName("CVConsole")
$InstanceName=$textBoxSqlInstanceName.Tex
$global:ProgressLabel2 = $window.FindName("ProgressLabel2")
$global:ProgressLabel = $window.FindName("ProgressLabel")
$btnCheckStatus = $window.FindName("Check")
$resultsDataGrid = $window.FindName("ResultsDataGrid")

# Handle the "Connect" button click: connects to the selected Commvault console.
$btnConnectToConsole.Add_Click({

$ChosenConsole=$comboListOfConsole.SelectedItem.content 

$User = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$PassWord = Read-Host -Prompt "Enter Your ADAA password" -AsSecureString 
$Global:Credential= New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $User,$Password 
Connect-CVServer -Credential $Global:Credential -Server "$ChosenConsole" -ErrorAction SilentlyContinue





})


[Reflection.Assembly]::LoadWithPartialName('System.Collections.ObjectModel')
$databaseNames = New-Object System.Collections.ObjectModel.ObservableCollection[string]
$comboListOfDatabases.ItemsSource = $databaseNames

# Dynamically update the list of databases when the dropdown is opened.

function UpdateDatabaseList {
    param([string]$instanceName)
    
   
    $window.Dispatcher.Invoke([action]{
        $databaseNames.Clear()
    })

   
    $ListDatabase = Invoke-DbaQuery -SqlInstance $instanceName -Query 'SELECT name FROM master.sys.databases'
    $window.Dispatcher.Invoke([action]{
        $ListDatabase.name | ForEach-Object {
            [void]$databaseNames.Add($_)
        }
    })
}


$comboListOfDatabases.Add_DropDownOpened({
    $instanceName = $textBoxSqlInstanceName.Text
    if (-not [string]::IsNullOrWhiteSpace($instanceName)) {
        UpdateDatabaseList -instanceName $instanceName
    }
})

# Handle the "List all last backups" button click: shows a list of the latest backups.


$btnListLastBackup.Add_Click({
    [System.Windows.MessageBox]::Show("List last backups for selected database.")
    $instanceName = $textBoxSqlInstanceName.Text
    $selectedDatabase = $comboListOfDatabases.SelectedItem
$QueryDatabases= "use msdb
go

-- D = Full, I = Differential and L = Log.
-- There are other types of backups too but those are the primary ones.
SELECT backupset.database_name, 
    MAX(CASE WHEN backupset.type = 'D' THEN backupset.backup_finish_date ELSE NULL END) AS LastFullBackup,
    MAX(CASE WHEN backupset.type = 'I' THEN backupset.backup_finish_date ELSE NULL END) AS LastDifferential,
    MAX(CASE WHEN backupset.type = 'L' THEN backupset.backup_finish_date ELSE NULL END) AS LastLog
FROM backupset
where database_name ='$selectedDatabase'
GROUP BY backupset.database_name
ORDER BY backupset.database_name DESC

"
    $results= Invoke-DbaQuery  -SqlInstance $instanceName -query $QueryDatabases -database msdb -as DataTable
$resultsDataGrid.ItemsSource = $results.DefaultView

})


# Handle the "Backup Database" button click: initiates a backup of the selected database.



$btnBackupDatabase.Add_Click({

    $QueryAO = "SELECT CASE WHEN EXISTS (
    SELECT 1 FROM sys.dm_hadr_availability_group_states
)
THEN 'AO_CONFIGURED'
ELSE 'AO_NOT_CONFIGURED'
END AS AO_STATUS;
"

    
    [System.Windows.MessageBox]::Show("Performing backup .")
    $instanceName = $textBoxSqlInstanceName.Text
    $ExecuteQueryAO = Invoke-DbaQuery -SqlInstance $instanceName -Query $QueryAO -Database master


    if ($ExecuteQueryAO.AO_STATUS -eq  'AO_CONFIGURED'){

    $InstanceNameSplit=$instancename.Split('\')

    $OnlyInstance=$InstanceNameSplit[1]
    $onlyListener = $InstanceNameSplit[0]
    
    $selectedDatabase = $comboListOfDatabases.SelectedItem
    $SelectedBackupType=$comboBackupType.SelectedItem.content
    write-host -ForegroundColor Red "$SelectedBackupType"
    write-host -ForegroundColor red "$selectedDatabase"
    write-host -ForegroundColor red "$onlyListener listener"
    write-host -ForegroundColor red "$OnlyInstance Instance"

   Get-CVClient | Where-Object clientname -Like "*$OnlyInstance*" |Get-CVSQLInstance| Where-Object insname -Like "*$onlyListener*"|Get-CVSQLDatabase  | Where-Object {$_.dbname -eq $selectedDatabase } |Backup-CVSQLDatabase -BackupType  $SelectedBackupType| Out-GridView
    
    
    }

    else {

    $selectedDatabase = $comboListOfDatabases.SelectedItem
    $SelectedBackupType=$comboBackupType.SelectedItem.content
    write-host -ForegroundColor Red "$SelectedBackupType"

    Get-CVSQLInstance -Name  $instanceName | Get-CVSQLDatabase  | Where-Object {$_.dbname -eq $selectedDatabase } |Backup-CVSQLDatabase -BackupType  $SelectedBackupType| Out-GridView
    
    }
    
})

# Handle the "Check Status Backup" button click: checks the progress of the ongoing backup.

$btnCheckStatus.Add_Click({

$selectedDatabase = $comboListOfDatabases.SelectedItem

$instanceName = $textBoxSqlInstanceName.Text

      $QueryProgress = @"
 SELECT 
    FLOOR(percent_complete) as percent_complete ,db_name(database_id) as [DatabaseName],
   dateadd(second,estimated_completion_time/1000, getdate()) as estimated_completion_time
FROM sys.dm_exec_requests r 
   CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) a 
WHERE r.command in ('BACKUP DATABASE','RESTORE DATABASE')  and db_name(database_id) ='$selectedDatabase'

"@


$progressResult = Invoke-DbaQuery -SqlInstance $instanceName -Query $QueryProgress -Database master



$global:ProgressLabel.Content = "Backup percent complete: $($progressResult.percent_complete)%"

$global:ProgressLabel2.Content = "Backup will end at : $($progressResult.estimated_completion_time)"


})
