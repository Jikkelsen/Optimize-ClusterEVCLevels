#Requires -Version 5.1
#Requires -Modules VMware.VimAutomation.Core
<#
   ____        _   _           _                 _____ _           _            ________      _______ _                    _     
  / __ \      | | (_)         (_)               / ____| |         | |          |  ____\ \    / / ____| |                  | |    
 | |  | |_ __ | |_ _ _ __ ___  _ _______ ______| |    | |_   _ ___| |_ ___ _ __| |__   \ \  / / |    | |     _____   _____| |___ 
 | |  | | '_ \| __| | '_ ` _ \| |_  / _ \______| |    | | | | / __| __/ _ \ '__|  __|   \ \/ /| |    | |    / _ \ \ / / _ \ / __|
 | |__| | |_) | |_| | | | | | | |/ /  __/      | |____| | |_| \__ \ ||  __/ |  | |____   \  / | |____| |___|  __/\ V /  __/ \__ \
  \____/| .__/ \__|_|_| |_| |_|_/___\___|       \_____|_|\__,_|___/\__\___|_|  |______|   \/   \_____|______\___| \_/ \___|_|___/
        | |                                                                                                                      
        |_|                                                                                                                      
#>
#region------------------------------------------| HELP |------------------------------------------------#
<#
    .Synopsis
        Loops over all Compute clusters in a VMware environment, and makes suggestions on EVC mode upgrades for better performance
    .PARAMETER vCenterCredential
        Creds to import for authorization on vCenters
#>
#endregion
#region---------------------------------------| PARAMETERS |---------------------------------------------#
# Set parameters for the script here
param
(
    [Parameter(Mandatory)]
    [pscredential]
    $vCenterCredential,

    [Parameter(Mandatory)]
    [String]
    $TargetViServer
)
#endregion
#region------------------------------------------| SETUP |-----------------------------------------------#
try
{
    Write-Host "Connecting to $TargetViServer ... " -NoNewline
    [void]::(Connect-VIServer -Server $TargetViServer -Credential $vCenterCredential -AllLinked)
    Write-Host "OK"
}
catch 
{
    Write-Host "FAIL!"
    Throw
}

# Minimize vCenter calls by loading large variables at runtime to use locally later
Write-Host "Preparing Variables ... " -NoNewline
$AllClusters          = Get-Cluster
$AllVMhosts           = Get-VMHost
$AllSupportedEVCModes = $global:DefaultVIServer.ExtensionData.Capability.SupportedEVCMode
$ListOfGoodClusters   = [System.Collections.ArrayList]::new()
$ListOfChangeClusters = [System.Collections.ArrayList]::new()
$ListOfBadClusters    = [System.Collections.ArrayList]::new()
Write-Host "OK"
#endregion
#region-----------------------------------| Suggest EVC Changes |----------------------------------------#
# Loop over all Compute Clusters
Foreach ($Cluster in $AllClusters)
{
    Write-HostSeperator "Now Working in $Cluster"
    if ($null -eq $Cluster.EVCMode)
    {
        Write-Host "EVC Disabled"
        Continue
    }
    
    # Map EVC from cluster to type VMware.Vim.EVCMode
    $ClusterEVC = $AllSupportedEVCModes | Where-Object {$_.Key -eq $Cluster.EVCMode}

    Write-Host "EVC in cluster is set to $($ClusterEVC.Key)"

    # Get all CPU generations in the cluster
    $ClusterVMhosts         = $AllVMhosts | Where-Object {$_.Parent.Name -eq $Cluster.Name}
    $CPUGenerationInCluster = $ClusterVMhosts.MaxEVCMode | Sort-Object | Get-Unique
    Write-Host "Found $($CPUGenerationInCluster.Count) CPU generations on VMhost(s) in Cluster"

    # Assume EVC is set too low; try to disprove this
    $EVCTooLow = $True

    # Iterate over each present CPU generation in cluster
    Foreach ($Generation in $CPUGenerationInCluster)
    {
        $GenerationEVC = $AllSupportedEVCModes | Where-Object {$_.Key -eq $Generation}

        if ($GenerationEVC.VendorTier -gt $ClusterEVC.VendorTier)
        {
            Write-Host "- $($GenerationEVC.Key) is higher than the cluster at $($ClusterEVC.Key)"
        }
        elseif ($GenerationEVC.VendorTier -eq $ClusterEVC.VendorTier)
        {
            Write-Host "- $($GenerationEVC.Key) matches cluster at $($ClusterEVC.Key)"
            $EVCTooLow = $False
        }
        else 
        {
            # Note JVM: This should not happen, but bugs do occur 
            Write-Host "- $($GenerationEVC.Key) is lower than allowed in cluster at $($ClusterEVC.Key)" -BackgroundColor "Green" -ForegroundColor "Black"
        }
    }

    if ($EVCTooLow)
    {
        Write-Host "`nThe EVC mode in the cluster is lower than what every VMhost in the cluster offers - VMs are losing out on performance and features" -BackgroundColor "Red"

        $LowestSuggestedMode = ($CPUGenerationInCluster | Sort-Object -Property "VendorTier") | Select-Object -first 1

        $SuggestedAction = [pscustomobject]@{
            Cluster    = $Cluster.Name
            CurrentEVC = $Cluster.EVCMode
            TargetEVC  = $LowestSuggestedMode
        }
        [Void]::($ListOfChangeClusters.Add($SuggestedAction))

        Write-Host "The EVC mode should be set as high as the lowest VMhost allows, which is $LowestSuggestedMode"
    }
    else 
    {
        Write-Host "`nThe Cluster is configured correctly"
        [Void]::($ListOfGoodClusters.Add($Cluster.Name))
    }
}

Write-HostSeperator "End"
Write-Host "Of all $($AllClusters.Count) Clusters, $($ListOfChangeClusters.Count) can achieve better performance"

#EndRegion

$ListOfChangeClusters
Disconnect-VIServer * -Confirm:$false
