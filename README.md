Virtual Machine Compute Optimizer (VMCO)
========================================

This repository is a Powershell module that can be installed to calculate Virtual Machines' optimal vCPU configuration
(number of sockets and cores) based on the physical NUMA of the host it is running on, and the minimums in the cluster.
It will also make recommendations based on host Power Policy, cluster HW inconsistency, and changes in host or VM 
advanced settings.

The calculations are based on Mark Achtemichuk's Blog on Virtual Machine vCPU and vNUMA Rightsizing - Guidelines
blogs.vmware.com/performance/2017/03/virtual-machine-vcpu-and-vnuma-rightsizing-rules-of-thumb.html


INSTALLATION
========================================

Install the module for current user
     Install-Module VMCO -Scope CurrentUser
Install the module for everyone (requires privilege escalation)
     Install-Module VMCO
Copy the VMCO folder to a Powershell Path
     Run the command $Env:Path
     Copy the VMCO folder to one of those paths (ie, C:\Users\%USERNAME%\Documents\WindowsPowerShell\Scripts)

REQUIREMENTS
========================================

Powershell v5 or higher (come on...upgrade to Powershell Core!)
PowerCLI v 11.0.0.10380590 or higher (it will probably run on earlier versions, but has not been tested on lower versions)
Connection to one or more vCenter Servers* (Connect-VIServer)
*The -tdmJsonFile flag can be used to run this offline using the VMware TAM TDM output in JSON format

SAMPLE USAGE
========================================

.EXAMPLE
    Get-OptimalvCPU       #Gets all VMs from currently connected vCenters
.EXAMPLE
    Get-OptimalvCPU | Export-CSV -path "c:\temp\vNUMA.csv" -NoTypeInformation
.EXAMPLE
    Get-OptimalvCPU -vmName "MyVmName"
.EXAMPLE
    Get-OptimalvCPU -vmName (Get-VM -Name "*NY-DC*")
.EXAMPLE
    Get-OptimalvCPU -full   #Returns all vCenter, Cluster, and VMHost information
.EXAMPLE
    Get-OptimalvCPU -tdmJsonFile <FilePath>   #Generates report based on VMware TAM TDM reports in JSON format

========================================
SAMPLE OUTPUT
Get-OptimalvCPU brm-vra-app01
    VMName                : brm-vra-app01
    VMSockets             : 12
    VMCoresPerSocket      : 1
    vCPUs                 : 12
    VMOptimized           : False
    OptimalSockets        : 2
    OptimalCoresPerSocket : 6
    Priority              : HIGH
    Details               : VM CPU spans pNUMA nodes and should be distributed evenly across as few as possible | Consider changing the host Power Policy to "High Performance" for hosts with VMs larger than 8 vCPU

Get-OptimalvCPU brm-vra-app01 -full
    vCenter                  : brm-prod-vc
    Cluster                  : Colorado Management Cluster
    ClusterMinMemoryGB       : 768
    ClusterMinSockets        : 2
    ClusterMinCoresPerSocket : 10
    DRSEnabled               : True
    HostName                 : brm-dell-02
    ESXi_Version             : 7.0.1
    HostMemoryGB             : 768
    HostSockets              : 2
    HostCoresPerSocket       : 10
    HostCpuThreads           : 40
    HostHTActive             : True
    HostPowerPolicy          : Balanced
    VMName                   : brm-vra-app01
    VMHWVersion              : vmx-10
    VMCpuHotAddEnabled       : False
    VMMemoryGB               : 40
    VMSockets                : 12
    VMCoresPerSocket         : 1
    vCPUs                    : 12
    VMOptimized              : False
    OptimalSockets           : 2
    OptimalCoresPerSocket    : 6
    Priority                 : HIGH
    Details                  : VM CPU spans pNUMA nodes and should be distributed evenly across as few as possible | Consider changing the host Power Policy to "High Performance" for hosts with VMs larger than 8 vCPUs

========================================
CHANGE LOG

2-5-2021
v3.0.0.2
Added escape for parentheses in VM Names (ie, Tanzu VMs) so they will show up in Get-View Filters by VMName

2-5-2021
v3.0.0.3
Removed requirement for VMware.PowerCLI due to error re: HorizonView module not supported in Powershell Core

2-5-2021
v3.0.0.4
Modified Get-vSphereInfo so it checks the VMName type and if Object or UniversalVirtualMachineImpl it selects just the name