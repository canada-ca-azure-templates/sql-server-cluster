#
# Copyright="© Microsoft Corporation. All rights reserved."
#

configuration PrepareAlwaysOnSqlServer
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$DomainCreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$SQLServicecreds,

        [System.Management.Automation.PSCredential]$SQLAuthCreds,

        [Parameter(Mandatory)]
        [String]$SqlAlwaysOnEndpointName,

        [UInt32]$DatabaseEnginePort = 1433,

        [UInt32]$DatabaseMirrorPort = 5022,

        [UInt32]$ListenerPortNumber = 59999,

        [Parameter(Mandatory)]
        [UInt32]$NumberOfDisks,

        [Parameter(Mandatory)]
        [String]$WorkloadType,

        [String]$DomainNetbiosName=(Get-NetBIOSName -DomainName $DomainName),

        [String]$serverOUPath,
        [String]$accountOUPath,

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30,
        [Int]$RebootRetryCount=3
    )

    Import-DscResource -ModuleName xComputerManagement,xActiveDirectory,xSql,xNetworking
    [System.Management.Automation.PSCredential]$DomainCredentials = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($DomainCreds.UserName)", $DomainCreds.Password)
    [System.Management.Automation.PSCredential]$DomainFQDNCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($DomainCreds.UserName)", $DomainCreds.Password)
    [System.Management.Automation.PSCredential]$SQLCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($SQLServicecreds.UserName)", $SQLServicecreds.Password)

    $RebootVirtualMachine = $false

    if ($DomainName)
    {
        $RebootVirtualMachine = $true
    }

    #Finding the next avaiable disk letter for Add disk
    #$NewDiskLetter = ls function:[f-z]: -n | ?{ !(test-path $_) } | select -First 1 

    #$NextAvailableDiskLetter = $NewDiskLetter[0]
    
    WaitForSqlSetup

    Node localhost
    {
       #Done by the new Microsoft.SqlVirtualMachine/SqlVirtualMachines
        # xSqlCreateVirtualDataDisk NewVirtualDisk
       # {
       #     NumberOfDisks = $NumberOfDisks
       #     NumberOfColumns = $NumberOfDisks
       #     DiskLetter = $NextAvailableDiskLetter
       #     OptimizationType = $WorkloadType
       #     StartingDeviceID = 2
       #     RebootVirtualMachine = $RebootVirtualMachine
       # }

        WindowsFeature FC
        {
            Name = "Failover-Clustering"
            Ensure = "Present"
        }

        WindowsFeature FailoverClusterTools 
        { 
            Ensure = "Present" 
            Name = "RSAT-Clustering-Mgmt"
            DependsOn = "[WindowsFeature]FC"
        } 

        WindowsFeature FCPS
        {
            Name = "RSAT-Clustering-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature ADPS
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        Script SqlServerPowerShell
        {
            SetScript = 'Install-PackageProvider -Name NuGet -Force; Install-Module -Name SqlServer -AllowClobber -Force; Import-Module -Name SqlServer -ErrorAction SilentlyContinue'
            TestScript = 'Import-Module -Name SqlServer -ErrorAction SilentlyContinue; if (Get-Module -Name SqlServer) { $True } else { $False }'
            GetScript = 'Import-Module -Name SqlServer -ErrorAction SilentlyContinue; @{Ensure = if (Get-Module -Name SqlServer) {"Present"} else {"Absent"}}'
        }

        xWaitForADDomain DscForestWait 
        { 
            DomainName = $DomainName 
            DomainUserCredential= $DomainCredentials
            RetryCount = $RetryCount 
            RetryIntervalSec = $RetryIntervalSec
            RebootRetryCount = $RebootRetryCount
	        DependsOn = "[WindowsFeature]ADPS"
        }
        
        Computer DomainJoin
        {
            Name = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = $DomainCredentials
            JoinOU = $serverOUPath
	        DependsOn = "[xWaitForADDomain]DscForestWait"
        }

        xFirewall DatabaseEngineFirewallRule
        {
            Direction = "Inbound"
            Name = "SQL-Server-Database-Engine-TCP-In"
            DisplayName = "SQL Server Database Engine (TCP-In)"
            Description = "Inbound rule for SQL Server to allow TCP traffic for the Database Engine."
            DisplayGroup = "SQL Server"
            State = "Enabled"
            Access = "Allow"
            Protocol = "TCP"
            LocalPort = $DatabaseEnginePort -as [String]
            Ensure = "Present"
            DependsOn = "[Computer]DomainJoin"
        }

        xFirewall DatabaseMirroringFirewallRule
        {
            Direction = "Inbound"
            Name = "SQL-Server-Database-Mirroring-TCP-In"
            DisplayName = "SQL Server Database Mirroring (TCP-In)"
            Description = "Inbound rule for SQL Server to allow TCP traffic for the Database Mirroring."
            DisplayGroup = "SQL Server"
            State = "Enabled"
            Access = "Allow"
            Protocol = "TCP"
            LocalPort = $DatabaseMirrorPort -as [String]
            Ensure = "Present"
            DependsOn = "[Computer]DomainJoin"
        }

        xFirewall ListenerFirewallRule
        {
            Direction = "Inbound"
            Name = "SQL-Server-Availability-Group-Listener-TCP-In"
            DisplayName = "SQL Server Availability Group Listener (TCP-In)"
            Description = "Inbound rule for SQL Server to allow TCP traffic for the Availability Group listener."
            DisplayGroup = "SQL Server"
            State = "Enabled"
            Access = "Allow"
            Protocol = "TCP"
            LocalPort = $ListenerPortNumber -as [string]
            Ensure = "Present"
            DependsOn = "[Computer]DomainJoin"
        }

        xSqlLogin AddDomainAdminAccountToSysadminServerRole
        {
            Name = $DomainCredentials.UserName
            LoginType = "WindowsUser"
            ServerRoles = "sysadmin"
            Enabled = $true
            Credential = $Admincreds
            PsDscRunAsCredential = $Admincreds
            DependsOn = "[Computer]DomainJoin"
        }

        xADUser CreateSqlServerServiceAccount
        {
            DomainAdministratorCredential = $DomainCredentials
            DomainName = $DomainName
            Path = $accountOUPath
            UserName = $SQLServicecreds.UserName
            Password = $SQLServicecreds
            Ensure = "Present"
            DependsOn = "[xSqlLogin]AddDomainAdminAccountToSysadminServerRole"
        }

        xSqlLogin AddSqlServerServiceAccountToSysadminServerRole
        {
            Name = $SQLCreds.UserName
            LoginType = "WindowsUser"
            ServerRoles = "sysadmin"
            Enabled = $true
            Credential = $Admincreds
            PsDscRunAsCredential = $Admincreds 
            DependsOn = "[xADUser]CreateSqlServerServiceAccount"
        }
        
        xSqlTsqlEndpoint AddSqlServerEndpoint
        {
            InstanceName = "MSSQLSERVER"
            PortNumber = $DatabaseEnginePort
            SqlAdministratorCredential = $Admincreds
            PsDscRunAsCredential = $Admincreds
            DependsOn = "[xSqlLogin]AddSqlServerServiceAccountToSysadminServerRole"
        }

     #   xSQLServerStorageSettings AddSQLServerStorageSettings
     #   {
     #       InstanceName = "MSSQLSERVER"
     #       OptimizationType = $WorkloadType
     #       DependsOn = "[xSqlTsqlEndpoint]AddSqlServerEndpoint"
     #   }

        xSqlServer ConfigureSqlServerWithAlwaysOn
        {
            InstanceName = $env:COMPUTERNAME
            SqlAdministratorCredential = $Admincreds
            ServiceCredential = $SQLCreds
            MaxDegreeOfParallelism = 1
            FilePath = "F:\DATA"
            LogPath = "F:\LOG"
            DomainAdministratorCredential = $DomainFQDNCreds
            EnableTcpIp = $true
            PsDscRunAsCredential = $DomainCredentials #JN-switched from $Admincreds, fixes spn error 
            DependsOn = "[xSqlLogin]AddSqlServerServiceAccountToSysadminServerRole"
        }

        LocalConfigurationManager 
        {
            RebootNodeIfNeeded = $true
        }

    }
}
function Get-NetBIOSName
{ 
    [OutputType([string])]
    param(
        [string]$DomainName
    )

    if ($DomainName.Contains('.')) {
        $length=$DomainName.IndexOf('.')
        if ( $length -ge 16) {
            $length=15
        }
        return $DomainName.Substring(0,$length)
    }
    else {
        if ($DomainName.Length -gt 15) {
            return $DomainName.Substring(0,15)
        }
        else {
            return $DomainName
        }
    }
}
function WaitForSqlSetup
{
    # Wait for SQL Server Setup to finish before proceeding.
    while ($true)
    {
        try
        {
            Get-ScheduledTaskInfo "\ConfigureSqlImageTasks\RunConfigureImage" -ErrorAction Stop
            Start-Sleep -Seconds 5
        }
        catch
        {
            break
        }
    }
}
