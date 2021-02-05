<#
    .NOTES
        Author: Mark McGill, VMware
        Last Edit: 2/3/2021
        Version 3.0.0.2
    .SYNOPSIS
        Calculates the optimal vCPU (sockets & cores) based on the current VM and Host architecture
    .DESCRIPTION
        Uses the logic from Mark Achtemichuk's blog "Virtual Machine vCPU and vNUMA Rightsizing – Guidelines"
        https://blogs.vmware.com/performance/2017/03/virtual-machine-vcpu-and-vnuma-rightsizing-rules-of-thumb.html

        If no -vmName is specified, Get-OptimalvCPU will get all VMs from connected vCenters
        Only the VM information will be returned unless the -full option is specified
    .EXAMPLE
        Get-OptimalvCPU    #Gets all VMs from currently connected vCenters
    .EXAMPLE
        Get-OptimalvCPU | Export-CSV -path "c:\temp\vNUMA.csv" -NoTypeInformation    #Exports results to csv
        Get-OptimalvCPU | Out-GridView    #Opens results in a grid window - Windows OS only
    .EXAMPLE
        Get-OptimalvCPU -vmName "MyVmName"   #Gets results on only the VM named "MyVmName"
    .EXAMPLE
        Get-OptimalvCPU -vmName (Get-VM -Name "*NY-DC*")    #Gets results on any VM with "NY-DC" in its name
    .EXAMPLE
        Get-OptimalvCPU -full    #Returns all vCenter, Cluster, and VMHost information
   .EXAMPLE
        Get-OptimalvCPU -tdmJsonFile <FilePath>    #Generates report based on VMware TAM TDM reports in JSON format    
    .OUTPUTS
        Object containing vCenter,Cluster,Host and VM information, as well as optimal vCPU recommendations
#>
function Get-OptimalvCPU
{
    #Requires -Version 5.0
    #Requires -Modules @{ModuleName="VMware.PowerCLI"; ModuleVersion="11.0.0.10380590"}
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory=$false)]$vmName,
        [Parameter(Mandatory=$false)]$tdmJsonFile,
        [Parameter(Mandatory=$false)][switch]$full
    )

    $nameFilter = ""
    $vmFilter = @{'RunTime.ConnectionState'='^(?!disconnected|inaccessible|invalid|orphaned).*$';'Runtime.PowerState'='poweredOn';'Config.Template'='False'}
    $hostFilter = @{'Runtime.ConnectionState'='connected';'Runtime.PowerState'='poweredOn'}
    $results = @()
    $vms = @()
    Write-Verbose "Retrieving VMs information - Skipping Disconnected, Powered Off, or Template VMs"

    Function Get-OptSockets ($vm,$vmMemoryGB,$vmCPUs,$vmHostMemPerChannel,$vmHostCPUs,$vmHostCoresPerSocket)
    {
        #calculations for optimal vCPU
        $i = 0
        try 
        {
            Do 
            {
                $i++
            }
            Until (
                ((($vmMemoryGB / $i -le $vmHostMemPerChannel) -or ($vmCPUs / $i -eq 1) -or ($vmCPUs -eq $vmHostCPUs)) `
                    -and (($vmCPUs / $i -le $vmHostCoresPerSocket) -or ($vmCPUs / $i -eq 1)) `
                    -and (($vmCPUs / $i)  % 2 -eq 0 -or ($vmCPUs / $i)  % 2 -eq 1)) `
                    -or $i -eq $vmHostCPUs / $vmHostCoresPerSocket
                )
            $optSockets = $i
            Return $optSockets           
        }
        Catch
        {
            Return "ERROR calculating Optimal vCPU for $vm : $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
        }
    }#end Get-OptSockets

    Function Get-vSphereInfo($vmName)
    {
        Try
        {
            If ($VMName -ne $null)
            {
                foreach ($name in $VMName)
                {
                    #escapes parentheses in VM name (ie, Tanzu VMs)
                    $name = ($name.Replace('(','\(')).Replace(')','\)')
                    $nameFilter += "^$($name)$|"
                }
                $nameFilter = $nameFilter.TrimEnd("|")
                $vmFilter += @{"Name" = $nameFilter}
            }
            #gets all VMs from connected vCenter servers
            $vms = get-view -ViewType VirtualMachine -Filter $vmFilter -Property Name,Config.Hardware.MemoryMB,Config.Hardware.NumCPU,Config.Hardware.NumCoresPerSocket,Config.CpuHotAddEnabled,Config.Version,Config.ExtraConfig,Runtime.Host | `
                Select Name, @{n='MemoryGB'; e={[math]::Round(($_.Config.Hardware.MemoryMB / 1024),2)}},@{n='Sockets';e={($_.Config.Hardware.NumCPU)/($_.Config.Hardware.NumCoresPerSocket)}},@{n='CoresPerSocket'; 
                e={$_.Config.Hardware.NumCoresPerSocket}},@{n='NumCPU';e={$_.Config.Hardware.NumCPU}},@{n='CpuHotAdd';e={$_.Config.CpuHotAddEnabled}},@{n='HWVersion';e={$_.Config.Version}},@{n='HostId';
                e={$_.Runtime.Host.Value}},@{n='vCenter';e={([uri]$_.client.ServiceUrl).Host}},@{n='NumaVcpuMin';e={($_.Config.ExtraConfig | where {$_.Key -eq "numa.vcpu.min"}).Value}}
            If($vms -eq $null)
            {
                Throw "ERROR retrieving VM Information. No VMs found, or VMs are not powered on, or connected"
            }

            Write-Verbose "Retrieving Host information. Skipping Disconnected or Powered Off Hosts"
            If ($VMName -ne $null)
            {
                $hostsUnique = $vms | Select @{n="Id";e={"HostSystem-" + "$($_.HostId)"}},vCenter | Sort-Object -Property @{e="Id"},@{e="vCenter"} -Unique
                $hostCommand = {get-view -Id $($hostsUnique.Id) -Property Name,Parent,Config.Product.Version,Config.HyperThread,Hardware.MemorySize,Hardware.CpuInfo,Config.PowerSystemInfo.CurrentPolicy.Key,Config.Option}
            }
            Else
            {
                $hostCommand = {get-view -ViewType HostSystem -Filter $hostFilter -Property Name,Parent,Config.Product.Version,Config.HyperThread,Hardware.MemorySize,Hardware.CpuInfo,Config.PowerSystemInfo.CurrentPolicy.Key,Config.Option}
            }
        
            $vmHosts = Invoke-Command $hostCommand | select Name,@{n='Id';e={$_.MoRef.Value}},@{n='Version';e={$_.Config.Product.Version}},@{n='vCenter';e={([uri]$_.Client.serviceurl).Host}},@{n="ClusterId";
                e={$_.Parent | Where{$_.Type -eq "ClusterComputeResource"} | select -expand Value}},@{n='MemoryGB';e={[int](($_.Hardware.MemorySize)/1073741824)}},@{n="MemPerChannel";
                e={[int](($_.Hardware.MemorySize)/1073741824) / ($_.Hardware.CpuInfo.NumCpuPackages)}},@{n='Sockets';e={($_.Hardware.CpuInfo.NumCpuPackages)}},@{n='CoresPerSocket';
                e={($_.Hardware.CpuInfo.NumCPUCores)/$($_.Hardware.CpuInfo.NumCpuPackages)}},@{n='CPUs';e={$_.Hardware.CpuInfo.NumCPUCores}},@{n='CpuThreads';e={($_.Hardware.CpuInfo.NumCpuThreads)}},@{n='HTActive';
                e={$_.Config.HyperThread.Active}},@{n='NumaVcpuMin'; e={$_.Config.Option | where {$_.Key -eq "numa.vcpu.min"}}},@{n='PowerPolicy'; 
                e={
                    switch($_.Config.PowerSystemInfo.CurrentPolicy.Key)
                    {
                        "1" {"HighPerformance"}
                        "2" {"Balanced"}
                        "3" {"LowPower"}
                        "4" {"Custom"}
                    }
                   }
            }

            Write-Verbose "Retrieving Cluster information" 
            $clustersUnique = $vmHosts | Where{$_.ClusterId -ne $null} | Select @{n="Id";e={"ClusterComputeResource-" + "$($_.ClusterId)"}},vCenter | Sort-Object -Property @{e="Id"},@{e="vCenter"} -Unique
            #accounts for hosts with no cluster
            If ($clustersUnique -ne $Null)
            {
                $clusters = get-view -Id $($clustersUnique.Id) -Property Name,Configuration.DrsConfig | Select Name,@{n="Id";e={$_.MoRef.Value}},@{n="vCenter"; e={([uri]$_.Client.serviceurl).Host}},@{n="DRSEnabled"; 
                    e={$_.Configuration.DrsConfig.Enabled}},MinMemoryGB,MinSockets,MinCoresPerSocket -ErrorAction Stop
     
                foreach ($cluster in $clusters)
                {
                    $clusterHosts = $vmHosts | Where{($_.vCenter -eq $cluster.vCenter) -and $_.clusterID -eq $cluster.Id} | select Name,Id,MemoryGB,Sockets,CoresPerSocket
                    $cluster.MinMemoryGB = ($clusterHosts.MemoryGB | measure -Minimum).Minimum
                    $cluster.MinSockets = ($clusterHosts.Sockets | measure -Minimum).Minimum
                    $cluster.MinCoresPerSocket = ($clusterHosts.CoresPerSocket | measure -Minimum).Minimum
                }
            }

            $returnObj = "" | Select vms,vmHosts,clusters
            $returnObj.vms = $vms
            $returnObj.vmHosts = $vmHosts
            $returnObj.clusters = $clusters
            Return $returnObj
        }#end Try
        Catch
        {
            Return "ERROR retrieving VM information: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
        }
    } #end Get-vSphereInfo
    Function Import-TDMData ($jsonFile)
    {
        Try
        {
            Write-Host "Importing JSON Data from $jsonFile" -ForegroundColor Green
            $content = get-content -Path $jsonFile -Raw 
            #Accounts for 'duplicates' that are the same text, but different case.  
            Do
            {
                Try
                {
                    $json = $content | ConvertFrom-Json -ErrorAction Stop
                    $success = $true
                }
                Catch [System.InvalidOperationException]
                {
                    $duplicateKey = ($_.Exception.Message).Split("'")[1]
                    $replace = $duplicateKey + "_"
                    $content = $content.Replace($duplicateKey,$replace) | Out-String 
                    $success = $false
                }
                Catch
                {
                    Throw "ERROR converting file content to JSON: $($_.Exception.Message)" 
                }
            }
            Until($success)

            Write-Host "Collecting Host Information..." -ForegroundColor Green
            $vmHosts = $json.hosts | select Name, @{n="Id";e={$_.mobId}},Version,vCenter,@{n="ClusterName"; e={$_.Cluster}},ClusterId, @{n='MemoryGB'; 
                e={[int](($_.ram)/1073741824)}},@{n="MemPerChannel";e={([int](($_.ram)/1073741824))/$_.cpus}},@{n="Sockets";e={$_.cpus}},@{n="CoresPerSocket"; e={$_.cores / $_.cpus}}, cpus, @{n="CpuThreads"; e={$_.Threads}},@{n="HTActive"; 
                e={if($_.Threads -gt $_.cores){$true}Else{$false}}}, NumaVcpuMin, @{n="PowerPolicy";e={"N/A"}}

            Write-Host "Collecting vCenter and Cluster information and calculating cluster minimums..." -ForegroundColor Green
            $clusters = $vmHosts | Select @{n="Name"; e={$_.clusterName}},@{n="Id"; e={$_.ClusterId}},@{n="DRSEnabled"; e={"N/A"}},vCenter,MinMemoryGB,MinSockets,MinCoresPerSocket | Where{$_.cluster -ne "n/a"} | Sort-Object -Property @{e="Id"},@{e="vCenter"} -Unique
            foreach ($cluster in $clusters)
            {
                $clusterHosts = $vmHosts | Where{($_.vCenter -eq $cluster.vCenter) -and ($_.clusterID -eq $cluster.Id)} | select Name,Id,MemoryGB,Sockets,CoresperSocket
                $cluster.MinMemoryGB = ($clusterHosts.MemoryGB | measure -Minimum).Minimum
                $cluster.MinSockets = ($clusterHosts.Sockets | measure -Minimum).Minimum
                $cluster.MinCoresPerSocket = ($clusterHosts.CoresPerSocket | measure -Minimum).Minimum
            }
        
            Write-Host "Processing Virtual Machine Information..." -ForegroundColor Green
            $vms = $json.vms | Where{$_.powerState -eq "POWERED_ON" -and $_.isTemplate -eq "no"} | Select Name, @{n="MemoryGB"; e={[math]::Round(($_.memoryInMb/1024),2)}},@{n="Sockets"; e={$_.numCpus/$_.num_cores_per_socket}},@{n="CoresPerSocket";
                e={$_.num_cores_per_socket}},@{n='NumCPU';e={$_.numCpus}},@{n='CpuHotAdd';e={"N/A"}},@{n='HWVersion';e={$_.version}},@{n='HostId';e={$_.parent_esx_mo_id}},@{n='vCenter';e={$_.vCenter}},NumaVcpuMin

            $returnObj = "" | Select vms,vmHosts,clusters
            $returnObj.vms = $vms
            $returnObj.vmHosts = $vmHosts
            $returnObj.clusters = $clusters
            Return $returnObj
        }#end Try
        Catch
        {
            Return "ERROR importing TDM JSON file: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
        }
    }#end Import-TDMData

    #Main code body
    Try
    {
        If ($tdmJsonFile -ne $null)
        {
            If (Test-Path $tdmJsonFile)
            {
                $vSphereData = Import-TDMData($tdmJsonFile)
                If($vSphereData -match "ERROR")
                {
                    Throw $vSphereData
                }
            }
            else 
            {
                Throw "Cannot find TDM JSON File: $tdmJsonFile"    
            }
        }
        #if no TMD file is specified
        else 
        {
            $vSphereData = Get-vSphereInfo($vmName)
            If($vSphereData -match "ERROR")
            {
                Throw $vSphereData
            }            
        }

        $vms = $vSphereData.vms
        $vmHosts = $vSphereData.vmHosts
        $clusters = $vSphereData.clusters

        #process VM calculations
        $vmCount = ($vms | Measure-Object).Count
        Write-Verbose "Calculating Optimal vCPU settings for $vmCount VMs"
        $n = 1
    }
    Catch
    {
        Write-Error "$($_.Exception.Message)"
        break
    }
      
    foreach ($vm in $vms)
    {
        Try 
        {
            $vmsPercent = [math]::Round(($n / $vmCount) * 100)
            Write-Progress -Activity "Calculating Optimal vCPU Config for VMs" -Status "$vmsPercent% Complete:" -PercentComplete $vmsPercent -CurrentOperation "Current VM: $($vm.Name)"
                
            $priorities = @() 
            $priorities += 0   
            $details = ""
            $pNumaNotExpDetails = ""
            $pNumaNotExp = $null

            $vmHost = $vmHosts | where {$($_.vCenter) -eq $($vm.vCenter) -and $($_.Id) -eq $($vm.HostId)} | select -first 1

            If ($vmHost.ClusterId -eq $null -or $vmHost.ClusterId -eq "n/a")
            {
                If($vmHost.ClusterId -eq "n/a")
                {
                    $vmHost.ClusterId = $null
                }
                $cluster = "" | Select Name,MinMemoryGB,MinSockets,MinCoresPerSocket
                $clusterInconsistent = $false
            }
            Else
            {
                $cluster = $clusters | Where{($($_.Id) -eq $($vmHost.ClusterId)) -and ($($_.vCenter) -eq $($vmHost.vCenter))} | Select Name,DRSEnabled,MinMemoryGB,MinSockets,MinCoresPerSocket | Select -first 1
                #flags if hosts in a cluster are of different size memory or CPU
                If (($vmHost.MemoryGB -ne $cluster.MinMemoryGB -or $vmHost.Sockets -ne $cluster.MinSockets -or $vmHost.CoresPerSocket -ne $cluster.MinCoresPerSocket) -and $cluster.MinMemoryGB -ne "")
                {
                    $clusterMemPerChannel = $cluster.MinMemoryGB / $cluster.MinSockets
                    $clusterCPUs = $cluster.MinSockets * $cluster.MinCoresPerSocket
                    $clusterInconsistent = $true
                    $details += "Host hardware in the cluster is inconsistent | "
                    $priorities += 1
                }
                else 
                {
                    $clusterInconsistent = $false
                }
            }#end Else

            #flags if vmMemory spans pNUMA node
            If ($vm.MemoryGB -gt $vmHost.MemPerChannel)
            {
                $memWide = $true
                $memWideDetail = "memory"
            }
            Else
            {
                $memWide = $false
                $memWideDetail = ""
            } 
            #flags if vCPUs span pNUMA node
            If ($vm.NumCPU -gt $vmHost.CoresPerSocket)
            {
                $cpuWide = $true
                $cpuWideDetail = "CPU"
            }
            Else
            {
                $cpuWide = $false
                $cpuWideDetail = ""
            }
        
            #if #vCPUs is odd and crosses pNUMA nodes
            If (($memWide -or $cpuWide) -and (($vm.NumCPU % 2) -ne 0))
            {
                $calcVmCPUs = $vm.NumCPU + 1
                $cpuOdd = $true
            }
            Else
            {
                $calcVmCPUs = $vm.NumCPU
                $cpuOdd = $false
            }
            #call function to calculate the optimal sockets based on VM/Host/Cluster info
            $optSockets = Get-OptSockets $vm.Name $vm.MemoryGB $calcVmCPUs $vmHost.MemPerChannel $vmHost.CPUs $vmHost.CoresPerSocket
            If($optSockets -match "Error")
            {
                Throw $optSockets
            }
            If ($clusterInconsistent)
            {
                $clusterOptSockets = Get-OptSockets $vm.Name $vm.MemoryGB $calcVmCPUs $clusterMemPerChannel $clusterCPUs $cluster.MinCoresPerSocket
                If ($clusterOptSockets -ne $optSockets)
                {
                    $optSockets = $clusterOptSockets
                    If ($cluster.DRSEnabled -eq $True)
                    {
                        $details = "Host hardware in the cluster is inconsistent and DRS is enabled. VM will cross pNUMA boundaries on smallest host in the cluster | "
                        $priorities += 4
                    }
                    else 
                    {
                        $details = "Host hardware in the cluster is inconsistent. VM will cross pNUMA boundaries on smallest host in the cluster | "
                        $priorities += 3                        
                    }
                }
            }

            $optCoresPerSocket = $calcVmCPUs / $optSockets

            #flags if adjustments had to be made to the vCPUs
            If (($optSockets -ne $vm.Sockets) -or ($optCoresPerSocket -ne $vm.CoresPerSocket) -or $cpuOdd)
            {
                $cpuOpt = $false
            }
            Else
            {
                $cpuOpt = $true
            }
            #vCPUs are not optimal, but VM is not wide
            If (-not ($memWide -or $cpuWide) -and (-not $cpuOpt))
            {
                $details += "VM does not span pNUMA nodes, but consider configuring it to match pNUMA architecture | "
                $priorities += 2
            }

            ######################################################
            #if crossing pNUMA node(s), additional flags
            If (($memWide -or $cpuWide) -and (-not $cpuOpt))
            {
                If ($memWideDetail -ne "" -and $cpuWideDetail -ne "")
                {
                    $wideDetails = "$memWideDetail and $cpuWideDetail"
                }
                Else
                {
                    $wideDetails = ("$memWideDetail $cpuWideDetail").Trim()
                }
                $details += "VM $wideDetails spans pNUMA nodes and should be distributed evenly across as few as possible | "
                $priorities += 4
                #flags if VM is crossing pNUMA nodes, and vHW version is less than 8 (pNUMA not exposed to guest) 
                $vmHWVerNo = [int]$vm.HWVersion.Split("-")[1]
                If($vmHWVerNo -lt 8)
                {
                    $pNumaNotExp = $true
                    $pNumaNotExpDetails = "(vHW < 8) "
                    $priorities += 4
                }
                #flags if VM is crossing pNUMA nodes, and CPUHotAdd is enabled (pNUMA not exposed to guest) 
                If($vm.CpuHotAdd -eq $true)
                {
                    $pNumaNotExp = $true
                    $pNumaNotExpDetails = $pNumaNotExpDetails + " (CpuHotAddEnabled = TRUE)"
                    $priorities += 4
                }
                #flags if VM is crossing pNUMA nodes, and vCPUs is less than 9 (pNUMA not exposed to guest)
                If($vm.NumCPU -lt 9 -and $vm.NumaVcpuMin -eq $null -and $vmHost.NumaVcpuMin -eq $null)
                {
                    $pNumaNotExp = $true
                    $pNumaNotExpDetails = $pNumaNotExpDetails + " (vCPUs < 9). Consider modifying advanced setting ""Numa.Vcpu.Min"" to $($vm.NumCPU) or lower. "
                    $priorities += 4 
                }
                #if NumaVcpuMin has been modified
                Elseif($vm.NumaVcpuMin -ne $null -or $vmHost.NumaVcpuMin -ne $null)
                {
                    If($vm.NumaVcpuMin -ne $null)
                    {
                        $modVM = "VMValue: $($vm.NumaVcpuMin) "
                    }
                    ElseIf($vmHost.NumaVcpuMin -ne $null)
                    {
                        $modHost = "HostValue: $($vmHost.NumaVcpuMin)"
                    }
                    $modDetail = ("$modVM, $modHost").Trim(", ")

                    switch($vm.NumaVcpuMin -le $vm.NumCPU -or $vmHost.NumaVcpuMin -le $vm.NumCPU)
                    {
                        $true 
                        {
                            $details += "vCPUs < 9, but advanced setting ""Numa.Vcpu.Min"" has been modified ($modDetail) to expose pNUMA to guest OS | "
                            $priorities += 1
                        }
                        $false 
                        {
                            $pNumaNotExp = $true
                            $pNumaNotExpDetails = $pNumaNotExpDetails + " (Advanced setting ""Numa.Vcpu.Min"" is > VM vCPUs). The setting has been modified ($modDetail), but is still higher than VM vCPUs. Change the value to $($vm.NumCPU) or lower to expose pNUMA to the guest OS"
                            $priorities += 4
                        }
                    }
                }
                If($pNumaNotExp)
                {
                    $pNumaNotExpDetails = $pNumaNotExpDetails.Trim() 
                    $details += "VM spans pNUMA nodes, but pNUMA is not exposed to the guest OS: $pNumaNotExpDetails | "
                    $priorities += 4
                }
             
                #flags if VM has odd # of vCPUs and spans pNUMA nodes
                If ($cpuOdd)
                {
                    $details += "VM has an odd number of vCPUs and spans pNUMA nodes | "
                    $priorities += 4
                }

            }#end if (($memWide -or $cpuWide) -and (-not $cpuOpt))

            #flags VMs with CPU count higher than physical cores
            If($vm.NumCPU -gt ($vmHost.Sockets * $vmHost.CoresPerSocket))
            {
                $optSockets = $vmHost.Sockets
                $optCoresPerSocket = $vmHost.CoresPerSocket
                $priorities += 4
                $details += "VM vCPUs exceed the host's physical cores. Consider reducing the number of vCPUs | "
            }
            #flags if vCPU count is > 8 and Host PowerPolicy is not "HighPerformance"
            If($vm.NumCPU -gt 8 -and $vmHost.PowerPolicy -ne "HighPerformance" -and $vmHost.PowerPolicy -ne "N/A")
            {
                $priorities += 3
                $details += 'Consider changing the host Power Policy to "High Performance" for hosts with VMs larger than 8 vCPUs | '
            } 
  
            #gets highest priority
            $highestPriority = ($priorities | measure -Maximum).Maximum
            Switch($highestPriority)
            {
                0    {$priority = "N/A"}
                1    {$priority = "INFO"}
                2    {$priority = "LOW"}
                3    {$priority = "MEDIUM"}
                4    {$priority = "HIGH"}
            }

            #flags whether the VM is configured optimally or not
            If ($priority -eq "N/A" -or $priority -eq "INFO")
            {
                $vmOptimized = $True
            }
            Else
            {
                $vmOptimized = $False
            }
            #creates object with data to return from function
            If ($full -eq $true)
            {
                $objInfo = [pscustomobject]@{
                    vCenter                  = $($vmHost.vCenter);
                    Cluster                  = $($cluster.Name);
                    ClusterMinMemoryGB       = $($cluster.MinMemoryGB);
                    ClusterMinSockets        = $($cluster.MinSockets);
                    ClusterMinCoresPerSocket = $($cluster.MinCoresPerSocket);
                    DRSEnabled               = $($cluster.DRSEnabled);
                    HostName	             = $($vmHost.Name);
                    ESXi_Version             = $($vmHost.Version);
                    HostMemoryGB             = $($vmHost.MemoryGB);
                    HostSockets              = $($vmHost.Sockets);
                    HostCoresPerSocket       = $($vmHost.CoresPerSocket);
                    HostCpuThreads           = $($vmHost.CpuThreads);
                    HostHTActive             = $($vmHost.HTActive);
                    HostPowerPolicy          = $($vmHost.PowerPolicy);
                    VMName                   = $($vm.Name);
                    VMHWVersion              = $($vm.HWVersion);
                    VMCpuHotAddEnabled       = $($vm.CpuHotAdd).ToString();
                    VMMemoryGB               = $($vm.MemoryGB);
                    VMSockets                = $($vm.Sockets);
                    VMCoresPerSocket         = $($vm.CoresPerSocket);
                    vCPUs                    = $($vm.NumCPU);
                    VMOptimized              = $vmOptimized;
                    OptimalSockets           = $optSockets;
                    OptimalCoresPerSocket    = $optCoresPerSocket;;
                    Priority                 = $priority;
                    Details                  = $details.Trim("| ")
                    } #end pscustomobject                
            }#end If
            Else
            {
                $objInfo = [pscustomobject]@{
                    VMName                   = $($vm.Name);
                    VMSockets                = $($vm.Sockets);
                    VMCoresPerSocket         = $($vm.CoresPerSocket);
                    vCPUs                    = $($vm.NumCPU);
                    VMOptimized              = $vmOptimized;
                    OptimalSockets           = $optSockets;
                    OptimalCoresPerSocket    = $optCoresPerSocket;
                    Priority                 = $priority;
                    Details                  = $details.Trim("| ")
                    } #end pscustomobject
            }

            $results += $objInfo
            $n++
        }#end Try
        Catch
        {
            Write-Error "Error calculating optimal CPU for $($vm.Name): $($_.Exception.Message)"
            break
        }
    }#end foreach ($vm in $vms)
    Write-Progress -Activity "Calculating Optimum vCPU Config for VMs" -Completed
    Return $results    
}