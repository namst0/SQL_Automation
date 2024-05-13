<#
.DESCRIPTION
This script migrate single or multiple databases if we have new clean server is also changing sp_configure , copying custom error and all needed configuration which was same on old server.
It automaticly check if server is configured with AO or this is single SQL server instance. Script will have 3 separate question depends what you want to do 1st regarding copying configuration from old server 2nd copying database, adding to Ao ETC ,3rd copying database stuff.
When we are copying database stuff its checking assosicated logins, default database etc.Its accepting TXT input for list of databases, databases have to be separeted by enter so

db1
db2
db3


.NOTES
    Author: Jakub Wolski
    Version: 3.2.1
    Required Dependencies: dbatools, PowerShell module, 

    Changes from 2.0 to  2.1
    - Added transcript 
    - Working now on listener /server name you dont have to provide server name will work also with listener name
    - Saving configuration of SP_Configure to file from desitnation and source before migration
    - Added log for sp_configure what options has been changed
    - small changes in comunicates
    - Added aditional update to change destination server after restart because , replica can change - it should not because we are allways restarting Primary , then secondary but in case of problems

    Changes from 2.1 to  3.0

    - added check if we have active connections to database if yes warn user that there are active connection
    - Changed approach i did split script into 3 parts - Initial configuration , Migration of Databases , Migration of login, creating script to set database in matinance etc , User will have 3 questions and each part work separatly
    - Adding a litlle of else and new comunicates
    
    Changes from 3.0 to  3.1
    -Added condition to scritp default databtas added condition if EXISTS
    -Added checking roles which are not standard so not in : ('public','sysadmin','securityadmin','serveradmin','setupadmin',
'processadmin','diskadmin','dbcreator','bulkadmin') if there are diffrent roles than mentioned here it will create script with name of server role and with permissons grant or deny 

    Changes from 3.2 to  3.2.1
    -Added "[]" in script for default database so now there should be no issues when we have sign like - in database name
    -Added check if $databases list is not empty if empty dont perform database migration, its done because when empty variable will go to copy-dbadatabase (dbatools command) he will migrate all databases instead of mentioned one in the  list


#>

    





Set-DbaToolsConfig -Name 'sql.connection.trustcert' -Value $true

#### adding assembleys for presentation dialog boxes################

Add-Type -AssemblyName 'PresentationFramework'

Add-Type -AssemblyName System.Windows.Forms

#Gathering informarion from user 


Write-Host -ForegroundColor Yellow "Relax and enjoy automation and read all comunicates !!!!! Remember - with great power comes great responsibility "

Write-Host -ForegroundColor Yellow "Script is not using force to copying database,logins and jobs so if something already exist it wont be overwriten"


$SourceServer = Read-Host -Prompt "Please provide source from which database need to be migrated  "

$DestinationServer = Read-Host -Prompt "Please provide destination to which database need to be migrated "

# Open File Dialog
$openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
$openFileDialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
$openFileDialog.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
$openFileDialog.ShowDialog() | Out-Null
$filePath = $openFileDialog.FileName

Write-Host -ForegroundColor Green "You did choose $filePath with database list"
# Variable to store the database names
$Databases = @()

# Check if file was selected
if (-not [string]::IsNullOrWhiteSpace($filePath)) {
    # Read the file and store each line in the variable
    $Databases = Get-Content -Path $filePath

}
else {
    Write-Output "No file selected."
}


#Checking connection to Source and Destination Server
Write-Host -ForegroundColor Yellow "Checking connection to Source server : $SourceServer"

Try {
    $connectionTestS = Test-DbaConnection -SqlInstance $SourceServer -EnableException -ErrorAction SilentlyContinue 

    if ($connectionTestS.ConnectSuccess -eq 'True') {
        Write-Host -ForegroundColor Green "Connection to $SourceServer with Success"

    }
}
catch {
    Write-Host -ForegroundColor Red "Connection to $SourceServer failed, check connection string or check if instance is accessible"

    break
}

Write-Host -ForegroundColor Yellow "Checking connection to Destination server : $DestinationServer"

Try {
    $connectionTestD = Test-DbaConnection -SqlInstance $DestinationServer -EnableException -ErrorAction SilentlyContinue

    if ( $connectionTestD.ConnectSuccess -eq 'True') {
        Write-Host -ForegroundColor Green "Connection to $DestinationServer with Success"


        
    }
}
catch {
    Write-Host -ForegroundColor Red "Connection to $DestinationServer failed, check connection string or check if instance is accessible"
    break
}


#times needed for file needed
$time = (Get-Date).ToString("yyyy.MM.dd.HH.MM.ss")
$start_time = get-date -format "yyyy-MM-dd hh:mm:ss"
#time needed for maintanance mode
$futureDate = (Get-Date).AddDays(21).ToString('yyyyMMdd')
#Taking initals of person running script
$userinfo = (net user $env:USERNAME /domain | Select-String "Full Name") -replace "\s\s+", " " -split " " -replace ",", "."
$userinfo = $userinfo[2].Substring(0, 2) + $userinfo[3].Substring(0, 2)


$userinfo
# QueryLogins associated with database
$QueryLogins = "SELECT 
--    dp.name AS DatabaseUserName,
    sp.name AS LoginName
    ,sp.type_desc
FROM sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.type_desc IN ('SQL_USER', 'WINDOWS_USER', 'WINDOWS_GROUP', 'EXTERNAL_USER') 
and dp.name not in('dbo','guest','INFORMATION_SCHEMA','sys','NT SERVICE\HealthService') 
and sp.name is not null
;"



$QerytocheckinstanceAuthenticationMode = "DECLARE @AuthenticationMode INT  
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', 
N'Software\Microsoft\MSSQLServer\MSSQLServer',   
N'LoginMode', @AuthenticationMode OUTPUT  

SELECT CASE @AuthenticationMode    
WHEN 1 THEN 'Windows Authentication'   
WHEN 2 THEN 'Windows and SQL Server Authentication'   
ELSE 'Unknown'  
END as [AuthenticationMode]  "

#query change of Authentication mode

$WinAndSQLAuthMode = "USE [master]
GO
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'LoginMode', REG_DWORD, 2
GO
"

#take out the instance name from connectiontest variable
$SourceServer = "$($connectionTestS.ComputerName)\$($connectionTestS.InstanceName)"
$destinationServer = "$($connectionTestD.ComputerName)\$($connectionTestD.InstanceName)"

$SourceServerM = $SourceServer.replace('\', '_')
$DestinationServerM = $destinationServer.replace('\', '_')

$ServerSource, $InstanceNameSource = $SourceServer.Split('\')
$ServerDestination, $InstanceNameDestination = $DestinationServer.Split('\')


Write-Host -ForegroundColor Yellow "Please choose which share you want to USE"
Write-Host -ForegroundColor red "*******************************************"

$share= Read-Host -Prompt "Please place share which will be used for migration "

#creation of backup share catalog
$BackupShare = $Share + "\" + $SourceServerM + "_Migration_Of_Databses_" + $time





IF (!(test-path $BackupShare)) {
    write-host "Creating folder: " $BackupShare -ForegroundColor green
    New-Item -Path $BackupShare -ItemType directory
}
else {
    write-host "The folder already exists: "$BackupShare -ForegroundColor Yellow
}


#Accounts on which instance are runing :
$ServiceAccountSource = Get-DbaService -ComputerName $ServerSource -InstanceName $InstanceNameSource | Where-Object ServiceType -EQ 'Engine' | Select-Object StartName
$ServiceAccountDestination = Get-DbaService -ComputerName $ServerDestination -InstanceName $InstanceNameDestination | Where-Object ServiceType -EQ 'Engine' | Select-Object StartName
    
    
#Set permissons for SQL account to share.
$AccessRuleS = New-Object System.Security.AccessControl.FileSystemAccessRule("$($ServiceAccountSource.StartName)", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
$acl2 = Get-Acl $BackupShare
$acl2.SetAccessRule($AccessRuleS)
$acl2 | Set-Acl $BackupShare
    
$AccessRuleD = New-Object System.Security.AccessControl.FileSystemAccessRule("$($ServiceAccountDestination.StartName)", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
$acl = Get-Acl $BackupShare
$acl.SetAccessRule($AccessRuleD)
$acl | Set-Acl $BackupShare

Start-Transcript -Path $BackupShare\Migration.log




#check size of databases
$SizeAndNameofDatabases = @(foreach ( $database in $Databases) {
        Get-DbaDatabase -SqlInstance $SourceServer -Database $database | Select-Object Name, SizeMB
    })

#query to check if AO is configured
$QueryAO = "SELECT CASE WHEN EXISTS (
    SELECT 1 FROM sys.dm_hadr_availability_group_states
)
THEN 'AO_CONFIGURED'
ELSE 'AO_NOT_CONFIGURED'
END AS AO_STATUS;
"

#check if AO is configured on destination server
$ExecuteQueryAO = Invoke-DbaQuery -SqlInstance $DestinationServer -Query $QueryAO -Database master

if ($ExecuteQueryAO.AO_STATUS -eq 'AO_CONFIGURED') {
    $CheckIfThisIsPrimaryReplica = Get-DbaAgReplica -SqlInstance $DestinationServer -Replica $destinationServer | Select-Object -First 1

    if ($CheckIfThisIsPrimaryReplica.role -eq 'Primary') {
        Write-Host -ForegroundColor Green "$DestinationServer is Primary Replica"
    }
    else {
        Write-Host -ForegroundColor Yellow "$DestinationServer is Secondary Replica, changing variable of destination server"
        
        $GetCurrentPrimaryReplica = Get-DbaAvailabilityGroup -SqlInstance $DestinationServer | Select-Object -ExpandProperty PrimaryReplicaServerName -First 1

        $DestinationServer = $GetCurrentPrimaryReplica

        Write-Host -ForegroundColor Green "Changed context to primary replica $DestinationServer"
    }
}
elseif ($ExecuteQueryAO.AO_STATUS -eq 'AO_NOT_CONFIGURED') {
    Write-Host -ForegroundColor Yellow  "AO is not configured for $DestinationServer"
}


#I have to check how many connections are to database

foreach ($DatabaseName in $SizeAndNameofDatabases) {
    # Get active connections 
    $ActiveConnectionsCount = (Get-DbaProcess -SqlInstance $SourceServer -database $DatabaseName.Name).Count

    # Check if there are any active connections and display the result
    if ($ActiveConnectionsCount -gt 0) {
        Write-Host -ForegroundColor Red "There are $ActiveConnectionsCount active connections to the $($DatabaseName.Name) database. "
    }
    else {
        Write-host -ForegroundColor Green "There are no active connections to the $($DatabaseName.Name) database."
    }
}

#checking which replica is secondary on destination
if ($ExecuteQueryAO.AO_STATUS -eq 'AO_CONFIGURED') {


    $SecondaryAndPrimaryReplica = Get-DbaAgReplica -SqlInstance $DestinationServer | Select-Object -Unique name, role, AvailabilityGroup, ComputerName, InstanceName -First 2

    $AgNAME = Get-DbaAgReplica -SqlInstance $DestinationServer |  Select-Object -ExpandProperty AvailabilityGroup | Sort-Object -Unique

    $SecondaryReplica = $SecondaryAndPrimaryReplica | Where-Object role -EQ 'Secondary' | Select-Object -ExpandProperty name -First 1


}



#Show question regarding initial configuration
##########Dialog boxes

$continue_InitialConfiguration = 'Yes'
$continue_Reeboot = 'Yes'

# Ask user 

$caption = "Question Regarding Initial Configuration"    
$message = "Would You like to perform initial configuration if instance is empty, It will copy instance setting , RECOMENDED ONLY when you migrate to NEW CLEAR INSTANCE, BECAUSE PROPABLY IT WAS NOT DONE BEFORE "

##############question regarding performing initial configuration #
$continue_InitialConfiguration = [System.Windows.MessageBox]::Show($message, $caption, 'YesNo');


if ($continue_InitialConfiguration -eq 'Yes' -and $ExecuteQueryAO.AO_STATUS -eq 'AO_CONFIGURED') {

    #exporting current configuration on source
    $ExportSPS = Export-DbaSpConfigure -SqlInstance $SourceServer -Path C:\Temp
    #it can't export directly on share so it must be done via c:\temp and copy to share
    Copy-Item "C:\Temp\$($ExportSPS.name)" -Destination $BackupShare

    Remove-Item "C:\Temp\$($ExportSPS.name)"

    #exporting current configuration on destination
    $ExportSPD = Export-DbaSpConfigure -SqlInstance $DestinationServer -Path C:\Temp

    Copy-Item "C:\Temp\$($ExportSPD.name)" -Destination $BackupShare

    Remove-Item "C:\Temp\$($ExportSPD.name)"

    $AuthenticationModeSource = Invoke-DbaQuery -SqlInstance  $SourceServer -Query $QerytocheckinstanceAuthenticationMode 
    #checking non standard server roles
    $ServerRolesND = "select name from sys.server_principals where type_desc ='SERVER_ROLE' and name not in
    ('public','sysadmin','securityadmin','serveradmin','setupadmin',
    'processadmin','diskadmin','dbcreator','bulkadmin')"
    #query to create server role permission
    $CreateRoleAndGrantPermissons = "DECLARE @RoleName NVARCHAR(128) = N'Audit_control';
    DECLARE @Script NVARCHAR(MAX) = '';
    
    -- Generate a script to create the server role
    SELECT @Script = @Script + 'CREATE SERVER ROLE [' + @RoleName + '];' + CHAR(13) + CHAR(10);
    
    
    
    -- Generate a script for server role permissions
    SELECT @Script = @Script +
        'GRANT ' + perm.permission_name + ' TO [' + @RoleName + '];' + CHAR(13) + CHAR(10)
    FROM sys.server_permissions AS perm
    JOIN sys.server_principals AS pr ON perm.grantee_principal_id = pr.principal_id
    WHERE pr.name = @RoleName;
    
    PRINT @Script;"

    $ListofNDroles = Invoke-DbaQuery -SqlInstance $SourceServer -Query $ServerRolesND
    #for each role query will be executed
    if ($ListofNDroles.count -gt 0) {
        foreach ($role in $ListofNDroles) {

            $CreateRoleAndGrantPermissons = "DECLARE @RoleName NVARCHAR(128) = N'$($role.name)';
        DECLARE @Script NVARCHAR(MAX) = '';
        
        -- Generate a script to create the server role
        SELECT @Script = @Script + 'CREATE SERVER ROLE [' + @RoleName + '];' + CHAR(13) + CHAR(10);
        
        
        
        -- Generate a script for server role permissions
        SELECT @Script = @Script +
            'GRANT ' + perm.permission_name + ' TO [' + @RoleName + '];' + CHAR(13) + CHAR(10)
        FROM sys.server_permissions AS perm
        JOIN sys.server_principals AS pr ON perm.grantee_principal_id = pr.principal_id
        WHERE pr.name = @RoleName;
        
        PRINT @Script;"
        
            Invoke-DbaQuery -SqlInstance $SourceServer -Database master -Query $CreateRoleAndGrantPermissons  | Out-File -FilePath $BackupShare\serverroles.sql -Append
        
        }
    }
    else { write-host -ForegroundColor Green "There is no not starndard roles which need to be migrated" }
    #
    foreach ( $Replica in $SecondaryAndPrimaryReplica) {

        $replicaName = $Replica.name
        $ReplicaComputer = $Replica.name -replace '\\.*', ''
        $ReplicaInstance = $Replica.name -replace '^.*\\', ''
        $OutFileLocation = "$Backupshare" + "\" + $ReplicaComputer + "_migrated_configuration.txt"


        #Perform check authentication mode for each destination replica if diffrent than source then change it
        $AuthenticationModeDestination = Invoke-DbaQuery -SqlInstance  $replicaName -Query $QerytocheckinstanceAuthenticationMode 
        Write-Host -ForegroundColor Magenta "Performing copy of the configuration for Instance $replicaName"
        $PathtoRoleFIle = "$BackupShare\serverroles.sql"
        if (Test-Path -Path $PathtoRoleFIle -PathType Leaf) {

            Write-Host -ForegroundColor Yellow "Adding missing roles for $replicaname"
            Invoke-DbaQuery -SqlInstance $replicaName -File $PathtoRoleFIle
        }



        If ($AuthenticationModeSource.AuthenticationMode -ne $AuthenticationModeDestination.AuthenticationMode) {

            Write-Host -ForegroundColor Yellow "Source server have $($AuthenticationModeSource.AuthenticationMode) and destination have $($AuthenticationModeDestination.AuthenticationMode) ill change authentication mode on destination " 


            Invoke-DbaQuery -SqlInstance $replicaName -Query $WinAndSQLAuthMode

        }

        else {
            Write-Host -ForegroundColor Green 'Authentication mode is the same on source  and destination'

        }
        #copying Sp_configure, instance configuration for both replica
        Write-Host -ForegroundColor Yellow 'Copying Sp_Configure'

        $SpConfigure = Copy-DbaSpConfigure -Source $SourceServer -Destination $replicaName 

        $SpConfigure | Out-File $OutFileLocation -Append

        Write-Host -ForegroundColor Yellow 'Copying StartupProcedure'

        $StartupProcedure = Copy-DbaStartupProcedure -Source $SourceServer -Destination $replicaName 
        $StartupProcedure | Out-File $OutFileLocation -Append
             
        Write-Host -ForegroundColor Yellow 'Copying DbaSysDbUserObject'

        $SysDbUserObject = Copy-DbaSysDbUserObject -Source $SourceServer -Destination $replicaName 
        $StartupProcedure  | Out-File $OutFileLocation -Append

        Write-Host -ForegroundColor Yellow 'Copy-DbaCustomError'

        $DbaCustomError = Copy-DbaCustomError -Source $SourceServer -Destination $replicaName 
        $DbaCustomError | Out-File $OutFileLocation -Append

        #ask question if user want to restart replica 
        $message_Reeboot = " Restart of instance "
        $caption_Reeboot = "Would you like perform instance restart: $replicaName ?"
        $continue_Reeboot
        $continue_Reeboot = [System.Windows.MessageBox]::Show($message_Reeboot, $caption_Reeboot, 'YesNo');


        if ($continue_Reeboot -eq 'Yes') {

            $time = 60 #minute

            $messageOG = "Migration"


                


            #restarting sql 
            Write-Host -ForegroundColor Yellow "Restarting SQl server instance and waiting 30 sec "
            Restart-DbaService -ComputerName $ReplicaComputer -InstanceName $ReplicaInstance

            Start-Sleep -Seconds 30




        }

        Else {
            Write-Host -ForegroundColor Gray "I wont perform restart of instance"

        }

    }





}
#inital configuration for standalone
elseif ($continue_InitialConfiguration -eq 'Yes' -and $ExecuteQueryAO.AO_STATUS -eq 'AO_NOT_CONFIGURED' ) {



    $ExportSPS = Export-DbaSpConfigure -SqlInstance $SourceServer -Path C:\Temp

    Copy-Item "C:\Temp\$($ExportSPS.name)" -Destination $BackupShare

    Remove-Item "C:\Temp\$($ExportSPS.name)"


    $ExportSPD = Export-DbaSpConfigure -SqlInstance $DestinationServer -Path C:\Temp

    Copy-Item "C:\Temp\$($ExportSPD.name)" -Destination $BackupShare

    Remove-Item "C:\Temp\$($ExportSPD.name)"


    $OutFileLocation = "$Backupshare" + "\" + $DestinationServerM + "_migrated_configuration.txt"


    $AuthenticationModeSource = Invoke-DbaQuery -SqlInstance  $SourceServer -Query $QerytocheckinstanceAuthenticationMode 

    $AuthenticationModeDestination = Invoke-DbaQuery -SqlInstance  $DestinationServer -Query $QerytocheckinstanceAuthenticationMode 

    If ($AuthenticationModeSource.AuthenticationMode -ne $AuthenticationModeDestination.AuthenticationMode) {

        Write-Host -ForegroundColor Yellow "Source server have $($AuthenticationModeSource.AuthenticationMode) and destination have $($AuthenticationModeDestination.AuthenticationMode) ill change authentication mode on destination " 


        Invoke-DbaQuery -SqlInstance $DestinationServer -Query $WinAndSQLAuthMode

    }

    else {
        Write-Host -ForegroundColor Green 'Authentication mode is the same on source  and destination'

    }


    $ServerRolesND = "select name from sys.server_principals where type_desc ='SERVER_ROLE' and name not in
    ('public','sysadmin','securityadmin','serveradmin','setupadmin',
    'processadmin','diskadmin','dbcreator','bulkadmin','AchmeaMonitoring')"

    $CreateRoleAndGrantPermissons = "DECLARE @RoleName NVARCHAR(128) = N'Audit_control';
    DECLARE @Script NVARCHAR(MAX) = '';
    
    -- Generate a script to create the server role
    SELECT @Script = @Script + 'CREATE SERVER ROLE [' + @RoleName + '];' + CHAR(13) + CHAR(10);
    
    
    
    -- Generate a script for server role permissions
    SELECT @Script = @Script +
        'GRANT ' + perm.permission_name + ' TO [' + @RoleName + '];' + CHAR(13) + CHAR(10)
    FROM sys.server_permissions AS perm
    JOIN sys.server_principals AS pr ON perm.grantee_principal_id = pr.principal_id
    WHERE pr.name = @RoleName;
    
    PRINT @Script;"

    $ListofNDroles = Invoke-DbaQuery -SqlInstance $SourceServer -Query $ServerRolesND

    if ($ListofNDroles.count -gt 0) {
        foreach ($role in $ListofNDroles) {

            $CreateRoleAndGrantPermissons = "DECLARE @RoleName NVARCHAR(128) = N'$($role.name)';
        DECLARE @Script NVARCHAR(MAX) = '';
        
        -- Generate a script to create the server role
        SELECT @Script = @Script + 'CREATE SERVER ROLE [' + @RoleName + '];' + CHAR(13) + CHAR(10);
        
        
        
        -- Generate a script for server role permissions
        SELECT @Script = @Script +
            'GRANT ' + perm.permission_name + ' TO [' + @RoleName + '];' + CHAR(13) + CHAR(10)
        FROM sys.server_permissions AS perm
        JOIN sys.server_principals AS pr ON perm.grantee_principal_id = pr.principal_id
        WHERE pr.name = @RoleName;
        
        PRINT @Script;"
        
            Invoke-DbaQuery -SqlInstance $SourceServer -Database master -Query $CreateRoleAndGrantPermissons  | Out-File -FilePath $BackupShare\serverroles.sql -Append
        
        }
    }
    else { write-host -ForegroundColor Green "There is no not starndard roles which need to be migrated" }

    $PathtoRoleFIle = "$BackupShare\serverroles.sql"
    if (Test-Path -Path $PathtoRoleFIle -PathType Leaf) {

        Write-Host -ForegroundColor Yellow "Adding missing roles for $DestinationServer"
        Invoke-DbaQuery -SqlInstance $DestinationServer -File $PathtoRoleFIle
    }


    Write-Host -ForegroundColor Yellow 'Copying Sp_Configure'

    $SpConfigure = Copy-DbaSpConfigure -Source $SourceServer -Destination $DestinationServer
        
    $SpConfigure | Out-File $OutFileLocation -Append
    Write-Host -ForegroundColor Yellow 'Copying StartupProcedure'

    $StartupProcedure = Copy-DbaStartupProcedure -Source $SourceServer -Destination $DestinationServer 

    $StartupProcedure | Out-File $OutFileLocation -Append

    Write-Host -ForegroundColor Yellow 'Copying DbaSysDbUserObject'

    $SysDbUserObject = Copy-DbaSysDbUserObject -Source $SourceServer -Destination $DestinationServer 
       
    $SysDbUserObject | Out-File $OutFileLocation -Append
    Write-Host -ForegroundColor Yellow 'Copy-DbaCustomError'
        

    $DbaCustomError = Copy-DbaCustomError -Source $SourceServer -Destination $DestinationServer 

    $DbaCustomError | Out-File $OutFileLocation -Append

    #ask question if user want to restart replica 
    $message_Reeboot = " Restart of instance "
    $caption_Reeboot = "Would you like perform instance restart ?"
    $continue_Reeboot
    $continue_Reeboot = [System.Windows.MessageBox]::Show($message_Reeboot, $caption_Reeboot, 'YesNo');


    if ($continue_Reeboot -eq 'Yes') {

        $time = 60 #minutes

        $messageOG = "Migration"


           




        Write-Host -ForegroundColor Yellow "Restarting SQl server instance and waiting 30 sec "

        Restart-DbaService -ComputerName $ServerDestination -InstanceName $InstanceNameDestination


        Start-Sleep -Seconds 30

           

    }


}
else {
    Write-Host -ForegroundColor Yellow "Initital configuration has not been choesen for destination server $DestinationServer"
}   


#DATABASE MIGRATION
#doYouwant migrate databases and add them to AO ETC 

$message_Migration = " Migration of Databases"
$caption_Migration = "Would you like migrate databases from file which you provided?"
$continue_Migration
$continue_Migration = [System.Windows.MessageBox]::Show($message_Migration, $caption_Migration, 'YesNo');



if ($continue_Migration -eq 'YES') {
    if ($databases.count -gt 0) {
        <# Action to perform if the condition is true #>
        if ($ExecuteQueryAO.AO_STATUS -eq 'AO_CONFIGURED') {


            $SecondaryAndPrimaryReplica = Get-DbaAgReplica -SqlInstance $DestinationServer | Select-Object -Unique name, role, AvailabilityGroup, ComputerName, InstanceName -First 2

            $AgNAME = Get-DbaAgReplica -SqlInstance $DestinationServer |  Select-Object -ExpandProperty AvailabilityGroup | Sort-Object -Unique

            $SecondaryReplica = $SecondaryAndPrimaryReplica | Where-Object role -EQ 'Secondary' | Select-Object -ExpandProperty name -First 1

            $DestinationServer = $SecondaryAndPrimaryReplica | Where-Object role -EQ 'Primary' | Select-Object -ExpandProperty name -First 1


        }

        Foreach ($database in $SizeAndNameofDatabases) {

            if ($database.SizeMB -gt 300000) 

            { Write-Host -ForegroundColor Yellow "$($database.Name) have more than 300 GB migrate it manually" }


            else {
                Write-Host -ForegroundColor Green "$($database.Name) Have proper size starting migration"


                Write-Host -ForegroundColor Yellow " Restroing Datababase : $($database.Name) "

                Copy-DbaDatabase -Source $SourceServer -Destination $DestinationServer -BackupRestore -Database $database.Name -SharedPath $BackupShare | Format-Table

                Write-Host -ForegroundColor Yellow " Changing compability LVL for : $($database.Name) "

                Set-DbaDbCompatibility -SqlInstance $DestinationServer -Database $database.name | Format-Table

                Write-Host -ForegroundColor Yellow " Set DBowner to SA : $($database.Name) "

                Set-DbaDbOwner -SqlInstance $DestinationServer -Database $database.name | Format-Table

           


                # Add database to AO

                #WE have to define to which AG group we need add databsae :

                # Display the menu and prompt for selection




                If ($database.SizeMB -lt 100000 -and $ExecuteQueryAO.AO_STATUS -eq 'AO_CONFIGURED') {

                    Write-Host -ForegroundColor Yellow " Adding Database to AO with AUTOMATIC SEEDING : $($database.Name) "

                    ##################### Choose AG Group ###############################
                    If ($AgNAME.count -eq 1) {
                        $chosenAGGroup = $AgNAME

                        Write-Host -ForegroundColor Green "There is only one AG GROUP $Agname"
                    }

                    elseif ($AgNAME.count -gt 1) {
                        Write-Host -ForegroundColor magenta "Select an Availability Group:"
                        for ($i = 0; $i -lt $AGNAME.Count; $i++) {
                            Write-Host "$i. $($AGNAME[$i])" 
                        }

                        # Prompt the user for a choice
                        $chosenIndex = Read-Host "Enter the number of the chosen Availability Group"

                        # Get the chosen Availability Group based on the user's input
                        $chosenAGGroup = $AGNAME[$chosenIndex]

                        # Output the chosen Availability Group
                        Write-Host -ForegroundColor Green "You did choose to add database to  $chosenAGGroup "
                   
                    }




                    $AddAgDatabase = Add-DbaAgDatabase -SqlInstance $DestinationServer -AvailabilityGroup $chosenAGGroup -Database $database.Name -SeedingMode Automatic

                    $AddAgDatabase | Select-Object sqlinstance, name, SynchronizationState | Format-Table




                }
                Elseif ($ExecuteQueryAO.AO_STATUS -eq 'AO_CONFIGURED' -and $database.SizeMB -gt 100000 ) {
                    ##################### Choose AG Group ###############################
                    If ($AgNAME.count -eq 1) {
                        $chosenAGGroup = $AgNAME

                        Write-Host -ForegroundColor Green "There is only one AG GROUP $Agname"
                    }

                    elseif ($AgNAME.count -gt 1) {
                        Write-Host -ForegroundColor magenta "Select an Availability Group:"
                        for ($i = 0; $i -lt $AGNAME.Count; $i++) {
                            Write-Host "$i. $($AGNAME[$i])" 
                        }

                        # Prompt the user for a choice
                        $chosenIndex = Read-Host "Enter the number of the chosen Availability Group"

                        # Get the chosen Availability Group based on the user's input
                        $chosenAGGroup = $AGNAME[$chosenIndex]

                        # Output the chosen Availability Group
                        Write-Host -ForegroundColor Green "You did choose to add database to  $chosenAGGroup "
                   
                    }

                    Write-Host -ForegroundColor Yellow "adding $($database.Name) using backup and restore"


                    $AddAgDatabaseBR = Add-DbaAgDatabase -SqlInstance $DestinationServer -AvailabilityGroup $chosenAGGroup -Database $database.Name -SeedingMode Manual -SharedPath $BackupShare

                    $AddAgDatabaseBR | Select-Object sqlinstance, name, SynchronizationState | Format-Table


          

                }

                Else {
                    Write-host "Single Instance not addding to AO"
                }




            }



        }

    
    }
    else { Write-Host -ForegroundColor Red "Variable Databses is empty I wont migrate databases because of that or you did not choose to migrate databases " }

}


#Show question do you want migrate logins prepare scripts ETC 


$message_Copying = " Copying database stuff "
$caption_Copying = "Would you like perform copy all logins, perform scripts etc for listed databases from : $sourceserver ?"
$continue_Copying
$continue_Copying = [System.Windows.MessageBox]::Show($message_Copying, $caption_Copying, 'YesNo');


if ($continue_Copying -eq 'Yes') {

    If ($SizeAndNameofDatabases.Count -gt 0) {

        $QueryAO = "SELECT CASE WHEN EXISTS (
    SELECT 1 FROM sys.dm_hadr_availability_group_states
)
THEN 'AO_CONFIGURED'
ELSE 'AO_NOT_CONFIGURED'
END AS AO_STATUS;
"

        if ($ExecuteQueryAO.AO_STATUS -eq 'AO_CONFIGURED') {


            $SecondaryAndPrimaryReplica = Get-DbaAgReplica -SqlInstance $DestinationServer | Select-Object -Unique name, role, AvailabilityGroup, ComputerName, InstanceName -First 2

            $SecondaryReplica = $SecondaryAndPrimaryReplica | Where-Object role -EQ 'Secondary' | Select-Object -ExpandProperty name -First 1

            $DestinationServer = $SecondaryAndPrimaryReplica | Where-Object role -EQ 'Primary' | Select-Object -ExpandProperty name -First 1


        }



        #copying logins which belongs to chosen database
        Foreach ($database in $SizeAndNameofDatabases) {

            Write-Host -ForegroundColor Yellow " Copying logins which have users in database : $($database.Name) "

            $ListOfLoginsWhichBelongsToDatabase = Invoke-DbaQuery -Query $QueryLogins -SqlInstance $SourceServer -Database $database.Name 

            $loginNamesArray = $ListOfLoginsWhichBelongsToDatabase | Select-Object -ExpandProperty LoginName 
            

            if ($loginNamesArray.count -gt 0) {
                $Logins = Copy-DbaLogin -Source $SourceServer -Destination $DestinationServer -Login $loginNamesArray

                $Logins | Format-Table
            }
            else {

                Write-Host -ForegroundColor Green "There is no logins assosiated with this database" 
            }


            foreach ($insertlogin in $ListOfLoginsWhichBelongsToDatabase) {




                else {
                    Write-Host -ForegroundColor Green 'There was no SQL logins which has been migrated'
                }
            }




            

            If ($ExecuteQueryAO.AO_STATUS -eq 'AO_CONFIGURED') {

                Write-Host -ForegroundColor Yellow " Copying logins to secondary node for : $($database.Name) "

                if ($loginNamesArray.count -gt 0) {
                    $LoginsSecondary = Copy-DbaLogin -Source $SourceServer -Destination $SecondaryReplica -Login $loginNamesArray

                    $LoginsSecondary | Format-Table

                    
                }
                else {

                    Write-Host -ForegroundColor Green "There is no logins assosiated with this database" 
                }



                foreach ($insertlogin in $ListOfLoginsWhichBelongsToDatabase) {


 
                }

            }


            Else {
                Write-host "Single Instance "
            }


        }

        #logins with server roles but without specified database
        $QueryLoginsWithServerRolePermissons = "SELECT
		roles.name									AS RolePrincipalName
			,	members.name								AS MemberPrincipalName
FROM sys.server_role_members AS server_role_members
INNER JOIN sys.server_principals AS roles
    ON server_role_members.role_principal_id = roles.principal_id
INNER JOIN sys.server_principals AS members 
    ON server_role_members.member_principal_id = members.principal_id  
where members.name not in (
'$($ServiceAccountSource.StartName)'

)  and members.name not like 'NT Service\%'  and members.name not like 'NT AUTHORITY\%'
;"


        $LoginsWithServerRolePermissons = Invoke-DbaQuery -SqlInstance $SourceServer -Query $QueryLoginsWithServerRolePermissons -Database master  

        $LoginsToCopy = $LoginsWithServerRolePermissons | Out-GridView -PassThru

        $LoginsToCopySelected = $LoginsToCopy.MemberPrincipalName


        #Check if not empty list $LoginsToCopy.MemberPrincipalName -gt 0
        IF ($LoginsToCopySelected.count -gt 0) {

            IF ($ExecuteQueryAO.AO_STATUS -eq 'AO_CONFIGURED') {

                Write-Host -ForegroundColor Yellow "Copying chosen logins with server roles to primary"

                $CopyLoginsWithSR = Copy-DbaLogin -Source $SourceServer -Destination $DestinationServer -Login $LoginsToCopySelected 
                $CopyLoginsWithSR | Format-Table

                Write-Host -ForegroundColor Yellow "Copying chosen logins with server roles to Secondary"

                $CopyLoginsWithSRS = Copy-DbaLogin -Source $SourceServer -Destination $SecondaryReplica -Login $LoginsToCopySelected 
                $CopyLoginsWithSRS | Format-Table

            }
            elseif ($ExecuteQueryAO.AO_STATUS -eq 'AO_NOT_CONFIGURED') {


                $CopyLoginsWithSR = Copy-DbaLogin -Source $SourceServer -Destination $DestinationServer -Login $LoginsToCopySelected 
                $CopyLoginsWithSR



            }




        }

        elseif ($LoginsWithServerRolePermissons.count -eq 0) {
            Write-Host -ForegroundColor Green "There is no logins with servers roles which can be migrated"

        }  




        #creating default database conf
        $LoginsSourceDefualtDatabase = Get-DbaLogin -SqlInstance $SourceServer | Select-Object Name, DefaultDatabase

        $outputFile = "$BackupShare\defaultdatabase.sql"


        Write-host -ForegroundColor Yellow "Getting configuration of defaultdatabases for logins for $SourceServer and saving to file in $outputFile"

        foreach ($login in $LoginsSourceDefualtDatabase) {
            if ($login.DefaultDatabase -ne 'master') {
                # Generate the command to alter the default database
                $UpdateLogin = "If exists (
select name from sys.databases where name ='$($login.DefaultDatabase)')
ALTER LOGIN [$($login.Name)] WITH DEFAULT_DATABASE = [$($login.DefaultDatabase)]
else print 'Database $($login.DefaultDatabase) doesnt exist on instance';"

                # Append the command to the output file
                $UpdateLogin | Out-File -FilePath $outputFile -Append
            }
        }




        #Copying jobs

        Write-Host -ForegroundColor Yellow "Checking if i need to copy jobs"

        $Jobs = Get-DbaAgentJob -SqlInstance $SourceServer 
        $jobsToCopy = $Jobs | Out-GridView -PassThru 
        $ChoosenJobs = $jobsToCopy | Select-Object -ExpandProperty name
        if ($jobsToCopy.count -gt 0) {

            IF ($ExecuteQueryAO.AO_STATUS -eq 'AO_CONFIGURED') {
                Write-Host -ForegroundColor Yellow "Copying choosen jobs to primary"

                $CopyJobs = Copy-DbaAgentJob -Source $SourceServer -Destination $DestinationServer -Job $ChoosenJobs
                $CopyJobs | Format-Table
                Write-Host -ForegroundColor Yellow "Copying choosen jobs to secondary"
                $CopyJobsS = Copy-DbaAgentJob -Source $SourceServer -Destination $SecondaryReplica -Job $ChoosenJobs
                $CopyJobsS | Format-Table

            }
            elseif ($ExecuteQueryAO.AO_STATUS -eq 'AO_NOT_CONFIGURED') {
            
                Write-Host -ForegroundColor Yellow "Copying choosen jobs"

                $CopyJobs = Copy-DbaAgentJob -Source $SourceServer -Destination $DestinationServer -Job $ChoosenJobs
                $CopyJobs | Format-Table



            }

            else { write-host -ForegroundColor Green "There was no choosen any jobs" }

 



            Write-Host -ForegroundColor Green "Copying of configuration for databases has been complete"
        
      


        }


        If (Test-Path -Path $outputFile -PathType Leaf) {
        
            IF ($ExecuteQueryAO.AO_STATUS -eq 'AO_CONFIGURED') {
                Write-Host -ForegroundColor Yellow "Executing query with default database on primary "

                Invoke-DbaQuery -SqlInstance $DestinationServer -File $outputFile
                Write-Host -ForegroundColor Yellow "Executing query with default database on secondary "
                Invoke-DbaQuery -SqlInstance $SecondaryReplica -File $outputFile
            

            }
            elseif ($ExecuteQueryAO.AO_STATUS -eq 'AO_NOT_CONFIGURED') {
        
                Write-Host -ForegroundColor Yellow "Executing query with default database"

                Invoke-DbaQuery -SqlInstance $DestinationServer -File $outputFile


    



            }
        }








    }
}
else { Write-Host -ForegroundColor Green "You did choose to not migrate anything related with databases" }

Write-Host -ForegroundColor Green "Thank you for using script "
Write-Host -ForegroundColor Green "At $backupshare you will find script which have to be started later already prepared for you"
Write-Host -ForegroundColor Magenta "If you like a script leave a positive comment Linkedin ;"   
Stop-Transcript
break
