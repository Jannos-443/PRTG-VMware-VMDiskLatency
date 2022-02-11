<#   
    .SYNOPSIS
    VMWare VM disk latency monitoring

    .DESCRIPTION
    Using VMware PowerCLI this Script checks VMware disk latency
    Exceptions can be made within this script by changing the variable $IgnoreScript. This way, the change applies to all PRTG sensors 
    based on this script. If exceptions have to be made on a per sensor level, the script parameter $IgnorePattern can be used.

    Copy this script to the PRTG probe EXEXML scripts folder (${env:ProgramFiles(x86)}\PRTG Network Monitor\Custom Sensors\EXEXML)
    and create a "EXE/Script Advanced. Choose this script from the dropdown and set at least:

    + Parameters: VCenter, User, Password
    + Scanning Interval: minimum 10 minutes

    .PARAMETER ViServer
    The Hostname of the VCenter Server

    .PARAMETER User
    Provide the VCenter Username

    .PARAMETER Password
    Provide the VCenter Password

    .PARAMETER IgnorePattern
    Regular expression to describe a disk to exclude.

    Example1:
    exclude "C:\" from the VM "FileSVR1"
    -IgnorePattern '^(Test-Server01|Test2.*)$'


    #https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_regular_expressions?view=powershell-7.1
    
    .PARAMETER LimitMAX
    Disk latency limit in ms for the maximum value
    
    .PARAMETER TimeMAX
    Hours to check for the max value. 
    For example 8 gives the maximum from the last 8 hours
    
    .PARAMETER ExcludeFolder
    Regular expression to describe a VMWare Folder to exclude

    .PARAMETER ExcludeRessource
    Regular expression to describe a VMWare Ressource to exclude.

    .EXAMPLE
    Sample call from PRTG EXE/Script Advanced
    PRTG-VMware-DiskLatency.ps1 -ViServer '%VCenter%' -User '%Username%' -Password '%PW%' -IgnorePattern '^(TestVM)$' -TimeMAX 1 -LimitMAX 20

    Author:  Jannos-443
    https://github.com/Jannos-443/PRTG-VMware-VMDiskLatency

#>
param(
    [string]$ViServer = '',
    [string]$User = '',
    [string]$Password = '',
    [string]$IgnorePattern = '',
    [string]$ExcludeFolder = '',
    [string]$ExcludeRessource = '',
    [int]$LimitMAX = 20, # Disk Latency in (ms) limit. VMs over this limit are in the Text Output
    [int]$TimeMAX = 1, #hours to check for max Maximum latency
    [boolean]$ShowStats = $true #Show Stats >> VMs per latency
)

#Catch all unhandled Errors
trap{
    if($connected)
        {
        $null = Disconnect-VIServer -Server $ViServer -Confirm:$false -ErrorAction SilentlyContinue
        }
    $Output = "line:$($_.InvocationInfo.ScriptLineNumber.ToString()) char:$($_.InvocationInfo.OffsetInLine.ToString()) --- message: $($_.Exception.Message.ToString()) --- line: $($_.InvocationInfo.Line.ToString()) "
    $Output = $Output.Replace("<","")
    $Output = $Output.Replace(">","")
    $Output = $Output.Replace("#","")
    Write-Output "<prtg>"
    Write-Output "<error>1</error>"
    Write-Output "<text>$Output</text>"
    Write-Output "</prtg>"
    Exit
}

#https://stackoverflow.com/questions/19055924/how-to-launch-64-bit-powershell-from-32-bit-cmd-exe
#############################################################################
#If Powershell is running the 32-bit version on a 64-bit machine, we 
#need to force powershell to run in 64-bit mode .
#############################################################################
if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") 
    {
    if ($myInvocation.Line) 
        {
        [string]$output = &"$env:WINDIR\sysnative\windowspowershell\v1.0\powershell.exe" -NonInteractive -NoProfile $myInvocation.Line
        }
    else
        {
        [string]$output = &"$env:WINDIR\sysnative\windowspowershell\v1.0\powershell.exe" -NonInteractive -NoProfile -file "$($myInvocation.InvocationName)" $args
        }

    #Remove any text after </prtg>
    try{
        $output = $output.Substring(0,$output.LastIndexOf("</prtg>")+7)
        }

    catch
        {
        }

    Write-Output $output
    exit
    }

#############################################################################
#End
#############################################################################     

$connected = $false

# Error if there's anything going on
$ErrorActionPreference = "Stop"


# Import VMware PowerCLI module
try {
    Import-Module "VMware.VimAutomation.Core" -ErrorAction Stop
} catch {
    Write-Output "<prtg>"
    Write-Output " <error>1</error>"
    Write-Output " <text>Error Loading VMware Powershell Module ($($_.Exception.Message))</text>"
    Write-Output "</prtg>"
    Exit
}

# PowerCLI Configuration Settings
try
    {
    #Ignore certificate warnings
    Set-PowerCLIConfiguration -InvalidCertificateAction ignore -Scope User -Confirm:$false | Out-Null

    #Disable CEIP
    Set-PowerCLIConfiguration -ParticipateInCeip $false -Scope User -Confirm:$false | Out-Null
    }

catch
    {
    Write-Host "Error in Set-PowerCLIConfiguration but we will ignore it." #Error when another Script is currently accessing it.
    }

# Connect to vCenter
try {
    Connect-VIServer -Server $ViServer -User $User -Password $Password
            
    $connected = $true
    }
 
catch
    {
    Write-Output "<prtg>"
    Write-Output " <error>1</error>"
    Write-Output " <text>Could not connect to vCenter server $ViServer. Error: $($_.Exception.Message)</text>"
    Write-Output "</prtg>"
    Exit
    }

# VM Latency
$ErrorText = ""
$ErrorCount = 0
$0_19 = 0
$20_39 = 0
$40_59 = 0
$60_79 = 0
$80_99 = 0
$100_149 = 0
$150_199 = 0
$200plus = 0
$highestlatency = 0
$highestAVGlatency = 0
$VMs = Get-VM | Where-Object {$_.PowerState -eq "PoweredOn"}

# hardcoded list that applies to all hosts
$IgnoreScript = '^(TestIgnore)$' 

#Remove Ignored VMs
if ($IgnorePattern -ne "") {
    $VMs = $VMs | Where-Object {$_.Name -notmatch $IgnorePattern}  
}

if ($IgnoreScript -ne "") {
    $VMs = $VMs | Where-Object {$_.Name -notmatch $IgnoreScript}  
}

if ($ExcludeFolder -ne "") {
    $VMs = $VMs | Where-Object {$_.Folder.Name -notmatch $ExcludeFolder}  
}

if ($ExcludeRessource -ne "") {
    $VMs = $VMs | Where-Object {$_.ResourcePool.Name -notmatch $ExcludeRessource}  
}


$Latencys = $VMs | Select-Object Name, @{n="AVGMaxLatency (ms)";e={(get-stat -Entity $_ -Stat Disk.MaxTotalLatency.Latest -Start (Get-Date).AddHours(-$TimeMAX) | Measure-Object Value -Average ).Average }},@{n="Max Latency (ms)";e={(get-stat -Entity $_ -Stat Disk.MaxTotalLatency.Latest -Start (Get-Date).AddHours(-$TimeMAX) | Measure-Object Value -Maximum ).Maximum }}| Sort-Object "Max Latency (ms)" -Descending

foreach($latency in $Latencys)
    {
    $avg = $latency.'AVG Max Latency (ms)'
    $max = $latency.'Max Latency (ms)'
    
    if($max -gt $highestlatency)
        {
        if($highestlatency -le 999999999)
            {
            $highestlatency = $max
            }
        }

    if($avg -gt $highestAVGlatency)
        {
        $highestAVGlatency = $avg
        }

    if($ShowStats)
        {
        switch ($max)
            {
            {($_ -ge 0) -and ($_ -lt 20)} {$0_19 += 1}
            {($_ -ge 20) -and ($_ -lt 40)} {$20_39 += 1}
            {($_ -ge 40) -and ($_ -lt 60)} {$40_59 += 1}
            {($_ -ge 60) -and ($_ -lt 80)} {$60_79 += 1}
            {($_ -ge 80) -and ($_ -lt 100)} {$80_99 += 1}
            {($_ -ge 100) -and ($_ -lt 150)} {$100_149 += 1}
            {($_ -ge 150) -and ($_ -lt 200)} {$150_199 += 1}
            {($_ -ge 200)} {$200plus += 1}
            }
        }

    if($max -gt $LimitMAX)
        {
            $ErrorCount += 1
            $ErrorText += "$($latency.Name): $([System.Math]::Round($max, 2))ms ||   "
        }   
    }

# Datastore Latency
$chkdatastore = $false
if($chkdatastore)
    {
    $Datastores = Get-Datastore

    foreach($Datastore in $Datastores)
        {
        $VMHosts = Get-VMHost -Datastore $Datastore.Name
        foreach($VMHost in $VMHosts)
            {
                if($null -eq $Datastore.ExtensionData.Info.Vmfs)
                    {}
                else 
                    {
                    $UID = $Datastore.ExtensionData.Info.Vmfs.Uuid
                    $readlatency =  Get-Stat -Entity $VMHost -Stat datastore.totalReadLatency.average -MaxSamples 1 -Realtime -Instance $UID 
                    $writelatency = Get-Stat -Entity $VMHost -Stat datastore.totalWriteLatency.average -MaxSamples 1 -Realtime -Instance $UID
                    Write-Host "$($Datastore.Name) $($VMHost.Name)"
                    Write-Host $readlatency
                    Write-Host $writelatency
                    }
            }

        }
    }

# Disconnect from vCenter
Disconnect-VIServer -Server $ViServer -Confirm:$false

$connected = $false

# Results
$xmlOutput = '<prtg>'
if ($ErrorCount -ge 1) {
    $xmlOutput = $xmlOutput + "<text>last $($TimeMAX)h over $($LimitMAX)ms: $($ErrorText)</text>"
    }

elseif($ErrorCount -eq 0) {
    $xmlOutput = $xmlOutput + "<text>No disks latency above $($LimitMAX)ms in the last $($TimeMAX)h</text>"
}

$xmlOutput = $xmlOutput + "<result>
        <channel>highest latency</channel>
        <value>$($highestlatency)</value>
        <unit>Custom</unit>
        <CustomUnit>ms</CustomUnit>
        <limitmode>1</limitmode>
        <LimitMAXError>$($LimitMAX)</LimitMAXError>
        </result>
        <result>
        <channel>highest AVG latency</channel>
        <value>$($highestAVGlatency)</value>
        <unit>Custom</unit>
        <CustomUnit>ms</CustomUnit>
        </result>
        "
        
if($ShowStats)
    {
    $xmlOutput = $xmlOutput + "<result>
        <channel>1latency 0-19ms VMs</channel>
        <value>$($0_19)</value>
        <unit>Count</unit>
        </result>
        <result>
        <channel>2latency 20-39ms VMs</channel>
        <value>$($20_39)</value>
        <unit>Count</unit>
        </result>
        <result>
        <channel>3latency 40-59ms VMs</channel>
        <value>$($40_59)</value>
        <unit>Count</unit>
        </result>
        <result>
        <channel>4latency 60-79ms VMs</channel>
        <value>$($60_79)</value>
        <unit>Count</unit>
        </result>
        <result>
        <channel>5latency 80-99ms VMs</channel>
        <value>$($80_99)</value>
        <unit>Count</unit>
        </result>
        <result>
        <channel>6latency 100-149ms VMs</channel>
        <value>$($100_149)</value>
        <unit>Count</unit>
        </result>
        <result>
        <channel>7latency 150-199ms VMs</channel>
        <value>$($150_199)</value>
        <unit>Count</unit>
        </result>
        <result>
        <channel>8latency 200+ms VMs</channel>
        <value>$($200plus)</value>
        <unit>Count</unit>
        </result>"
    }  
        



$xmlOutput = $xmlOutput + "</prtg>"

Write-Output $xmlOutput
