#Requires -Modules VMware.VimAutomation.Core
#Requires -Modules VMware.VumAutomation

function Install-VUMPatch
{
    [CmdletBinding()]
    param
    (
    [Parameter(Mandatory=$true)]
    [string]$VCenter,

    [Parameter(Mandatory=$true)]
    [pscredential]$Credential,

    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$BaselineName = 'Critical Host Patches (Predefined)',

    [Parameter(Mandatory=$true)]
    [string]$VM
    )
    begin 
    {
        ##Try connecting to vcenter
        try
        {
            Connect-VIServer $VCenter -Credential $Credential -ErrorAction Stop
        }
        catch
        {
            $ErrorMessage = $_.Exception.Message
            Write-Error $ErrorMessage 
            break
        }
    }
    process 
    {
        Try 
        {
            # Put baseline into variable and validate existence for later use
            $Baseline = Get-Baseline -Name $BaselineName -ErrorAction stop
            # Attach baseline to all hosts in cluster
            Attach-Baseline -Entity $ClusterName -Baseline $Baseline -ErrorAction stop
            # Test compliance against all hosts in cluster
            Test-Compliance -Entity $ClusterName -UpdateType HostPatch -Verbose -ErrorAction stop
            # Build array of noncompliant hosts
            $VMHosts = (Get-Compliance -Entity $ClusterName -Baseline $Baseline -ComplianceStatus NotCompliant -ErrorAction Stop).Entity.Name
            #Copy patches to noncompliant hosts
            Copy-Patch -Entity $VMhosts -Confirm:$false -ErrorAction stop
        }
        Catch 
        {
            $ErrorMessage = $_.Exception.Message
            Write-Error $ErrorMessage 
            Write-Output 'Error getting $Vmhosts variable'
            break
        }
        # For each noncompliant host install patches
        foreach ($VMhost in $VMHosts)
        {
            Write-Output "Patching $VMHost"
            try 
            {   
                # Put VMHost in maintenance mode
                Set-VMHost $VMhost -State Maintenance -Confirm:$false -ErrorAction Inquire | Select-Object Name,State | Format-Table -AutoSize
                # Remediate VMHost
                $UpdateTask = Update-Entity -Baseline $baseline -Entity $vmhost -RunAsync -Confirm:$false -ErrorAction Stop
                Start-Sleep -Seconds 05
                # Wait for patch task to complete
                while ($UpdateTask.PercentComplete -ne 100)
                {   
                    Write-Progress -Activity "Waiting for $VMhost to finish patch installation" -PercentComplete $UpdateTask.PercentComplete 
                    Start-Sleep -seconds 10
                    $UpdateTask = Get-Task -id $UpdateTask.id
                }
                # Check to see if remediation was sucessful
                if ($UpdateTask.State -ne 'Success')
                {
                    Write-Warning "Patch for $VMHost was not successful"
                    Read-Host 'Press enter to continue to next host or CTL+C to exit script'
                    Continue
                }
                # Check to see if host is now in compliance
                $CurrentCompliance = Get-Compliance -Entity $VMHost -Baseline $Baseline -ErrorAction Stop
                if  ($CurrentCompliance.Status -ne 'Compliant')
                {
                    Write-Warning "$VMHost is not compliant"
                    Read-Host 'Press enter to continue to next host or CTL+C to exit script'
                    Continue
                }
                # Set VMHost out of maintenance mode 
                Set-VMHost $vmhost -State Connected -Confirm:$false -ErrorAction Inquire | Select-Object Name,State | Format-Table -AutoSize
                # VMotion VM to VMHost and sleep for 3 seconds
                Move-VM -VM $VM -Destination $VMhost -Confirm:$false -ErrorAction Stop | Out-Null
                Start-Sleep -seconds 3
                # Test network connectivity to VM to ensure VMHost is operating correctly
                Test-Connection $VM -Count 4 -Quiet -ErrorAction Stop | Out-Null
                Write-Output "$VMHost patch successful."
            }
            catch 
            {
                $ErrorMessage = $_.Exception.Message
                Write-Warning $ErrorMessage 
                # Comment out the Read-Host if you do not want the script to prompt after an error. 
                Read-Host -Prompt 'Press enter to continue to next VMHost or CTRL + C to exit' 
                Continue
            }
        }
    }
    end 
    {
        Disconnect-ViServer -Confirm:$False -Force
        Write-Output  'Script completed'
    }
}

