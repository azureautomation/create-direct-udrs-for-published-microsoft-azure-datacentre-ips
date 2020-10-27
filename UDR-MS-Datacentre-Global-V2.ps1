    param(

        [parameter(Mandatory=$true)]
        [String] $InParam_SubscriptionID,

        [parameter(Mandatory=$true)]
        [String] $InParam_ResourceGroupName,
		
        [parameter(Mandatory=$true)]
        [string] $InParam_AzureRegion,

        [parameter(Mandatory=$false)]
        [int] $InParam_RouteLimit = 100,

        [parameter(Mandatory=$false)]
        [string] $InParam_CommonRouteTablePrefix="",

        [parameter(Mandatory=$False)]
        [boolean] $inParam_OverRideRTwithCommon = $false,
        
        [parameter(Mandatory=$False)]
        [boolean] $inParam_RemoveOther = $true
    )



$VerbosePreference = 'Continue'
$StartTime = Get-Date
Write-Output "Passed parameters"
Write-Output "SubscriptionID: $($InParam_SubscriptionID)"
Write-Output "ResourceGroupName: $($InParam_ResourceGroupName)"
Write-Output "AzureRegion: $($InParam_AzureRegion)"
Write-Output "RouteLimit: $($InParam_RouteLimit)"
Write-Output "CommonRouteTablePrefix: $($InParam_CommonRouteTablePrefix)"
Write-Output "RemoveOther Flag: $($inParam_RemoveOther)"

$Conn = Get-AutomationConnection -Name 'AzureRunAsConnection'

Add-AzureRMAccount -ServicePrincipal -Tenant $Conn.TenantID `
    -ApplicationId $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint

Login-AzureRmAccount -ServicePrincipal -TenantId $Conn.TenantId `
    -ApplicationId $Conn.ApplicationID -CertificateThumbprint $Conn.CertificateThumbprint

$AvailableSubs = Get-AzureRmSubscription
if ($InParam_SubscriptionID -notin $AvailableSubs.SubscriptionId) {
    Write-Error "Access to selected Subscription is denied"
} else {
    select-azurermsubscription -SubscriptionID $InParam_SubscriptionID 
}

#$InParam_ResourceGroupName = Get-AutomationVariable -Name 'vNetRGNameANZOnprod'
#$inParam_VNetName = Get-AutomationVariable -Name 'vNetNames'
#$InParam_AzureRegion = Get-AutomationVariable -Name 'auUDRRegions'
#Write-Output "VNet: $($Vnet.Name) - Subnet: $($Subnet.Name)"
Write-Output "Region: $($InParam_AzureRegion)"

#$inParam_RemoveOther = $true

$azureRegionSearch = '*' + $inParam_AzureRegion + '*'


#!!# added "-ListAvailable" to get CMDLet to return expected values
$PubIPModuleVersion = (Get-Module -Name "AzurePublicIPAddresses" -ListAvailable).Version
$ReqVersion = New-Object system.version(0,8,3)
if ($PubIPModuleVersion -lt $ReqVersion) {
    Write-Error "AzurePublicIPAddresses module not installed or older version"
}


$limit = $InParam_RouteLimit


#AzureRegion search text
$locations=@()
$locations = Get-AzureRmLocation | Where-Object {$_.Location -like $azureRegionSearch}


### Create and populate a new array with the IP ranges of each datacenter in the specified locations
$ipRanges = @()
foreach($location in $locations){
    Write-Output "location: $($location.DisplayName)"
    $ipRanges += Get-MicrosoftAzureDatacenterIPRange -AzureRegion $location.DisplayName
}
$ipRanges = $ipRanges | Sort-Object
Write-Output "IPRanges Count: $($ipRanges.count)"

$VNets=@()

#Query for VNet resources
#$VNets += Get-AzureRmVirtualNetwork -Name $inParam_VNetName -ResourceGroupName $inParam_ResourceGroupName
$VNets += Get-AzureRmVirtualNetwork -ResourceGroupName $inParam_ResourceGroupName
#$VNets += Get-AzureRmVirtualNetwork


########################################################################################
#Start vNet Loop
########################################################################################

foreach ($VNet in $VNets) {
    ##Uncomment below if validating logic of script
    #$vnet = $VNets
    #Flag for VNet change
    $VNetUpdateRequ = $false
    
    if ($InParam_CommonRouteTablePrefix -ne "") {
        $CommonRTName = "$($InParam_CommonRouteTablePrefix)-$($Vnet.Location)"
        $RTTblResource = $null
        $RTTblResource = Find-AzureRmResource -ResourceNameEquals $CommonRTName -ResourceType "Microsoft.Network/routeTables"

        if ($RTTblResource.Location -eq $VNet.Location -or $RTTblResource -eq $null) {
            if ($RTTblResource -ne $null) {
                Write-Verbose "Using Common Route Table: $($CommonRTName)"
                $CommonRTTable = Get-AzureRmRouteTable -Name $CommonRTName `
                    -ResourceGroupName $RTTblResource.ResourceGroupName
            } else {
                Write-Verbose "Create New Common Route Table: $($CommonRTName)"
                $CommonRTTable = New-AzureRmRouteTable -Name $CommonRTName `
                    -ResourceGroupName $InParam_ResourceGroupName `
                    -Location $VNet.Location
            }
            if ($inParam_OverRideRTwithCommon -eq $true) {
                Write-Output "OVERRIDING ALL ROUTE TABLES WITH: $($CommonRTName)"
            }
        } else {
            Write-Output "Common Route Table Error! Continuing without"
            $inParam_OverRideRTwithCommon = $false
            $CommonRTName = $null
            $CommonRTTable = $null
        }
    } else {
        $inParam_OverRideRTwithCommon = $false
        $CommonRTName = $null
        $CommonRTTable = $null
    }


    $subnets = @()
    $subnets = $vnet.Subnets | Where-Object {$_.Name -ne 'GatewaySubnet'}
    
########################################################################################

    #Iterate through each subnet in the virtual network
    foreach($subnet in $subnets){
        ##Uncomment below if validating logic of script
        #$subnet = $subnets[0]

        $AddedIPs = 0
        $UpdIPs = 0
        $newRoute = 0

        #Flag for RouteTable change
        $RouteUpdateRequ = $false

        Write-Output "VNet: $($Vnet.Name) - Subnet: $($Subnet.Name)"
        
        Write-Output "ROUTE TABLE ASSIGNMENT:"
        $RouteTable = $null
        
        #Check if Subnet already has a route table associated
        if ($Subnet.RouteTable.Id -ne $null) {
            
            if ( ($CommonRTTable -ne $null) -and `
                 ($inParam_OverRideRTwithCommon -eq $true) -and `
                 ($Subnet.RouteTable.Id -ne $CommonRTTable.Id) ) {

                Write-Output "OverRiding RouteTable From: $($Subnet.RouteTable.Id)"
                Write-Output " To: $($CommonRTTable.Id)"
                
                $RouteTable = $CommonRTTable
                $subnet.RouteTable = $RouteTable
                $VNetUpdateRequ = $true

            } else {
                #Get current Route Table
                Write-Output "Route Table Exists: $($Subnet.RouteTable.Id)"

                $RouteTableRes = Get-AzureRmResource -ResourceId $Subnet.RouteTable.Id
                $RouteTable = Get-AzureRmRouteTable -Name $RouteTableRes.Name -ResourceGroupName $RouteTableRes.ResourceGroupName
            }
        } else {
            #No route table associated with Subnet
            if ($CommonRTTable -eq $null) {
                $RouteTableName = 'route-' + $subnet.Name
            } else {
                Write-Output "Using Common Route Table: $($CommonRTTable.Id)"
                $RouteTableName = $CommonRTName
            }
            $RouteTable = $null
            $RouteTable = Get-AzureRmRouteTable -Name $RouteTableName -ResourceGroupName $Vnet.ResourceGroupName -ErrorAction Ignore
            #if the route table does not exist then create a new one
            if ($RouteTable -eq $null) {
                Write-Output "Creating New Route Table: $($RouteTableName)"
                $RouteTable = New-AzureRmRouteTable `
                    -Name $RouteTableName `
                    -ResourceGroupName $VNet.ResourceGroupName `
                    -Location $VNet.Location
            } else {
                Write-Output "Using Existing Route Table: $($RouteTableName)"
            }
            #Associate the route table to the subnet
            #Set-AzureRmVirtualNetworkSubnetConfig -VirtualNetwork $VNet -Name $($Subnet.Name) -RouteTable $RouteTable 
            $subnet.RouteTable = $RouteTable
            $countRoutes = 0
            $VNetUpdateRequ = $true
        }
        #$countRoutes = (Get-AzureRmRouteTable -Name (Get-AzureRmResource -ResourceId $Subnet.RouteTable.Id).Name -ResourceGroupName $RouteTableRes.ResourceGroupName).Routes.Count
        $TestcountRoutes = (Get-AzureRmRouteTable -Name (Get-AzureRmResource -ResourceId $Subnet.RouteTable.Id).Name -ResourceGroupName $InParam_ResourceGroupName).Routes.Count     
        $countRoutes = $RouteTable.Routes.Count
        Write-Output "Test Route Counts: OLD:$($TestcountRoutes) NEW:$($countRoutes)"

########################################################################################

        ### Include a routing configuration to give direct access to Microsoft's KMS servers for Windows activation
        $KMS_FQDN = "kms.core.windows.net"
        #Get KMS server IP address from DNS
        $KMSIpDetails = [System.Net.Dns]::GetHostAddresses($KMS_FQDN)
        $KMSPrefix = "$($KMSIpDetails.IPAddressToString)/32"
        $KMSRouteName = "AzureKMS"
        #Check if KMS route name (or prefix) already exists in route table

        if ($RouteTable.Routes.Count -gt 0) {
            $RtNameIndex = $RouteTable.Routes.Name.IndexOf($KMSRouteName)
            $RtPrefixIndex = $RouteTable.Routes.AddressPrefix.IndexOf($KMSPrefix)
        } else {
            $RtNameIndex = -1
            $RtPrefixIndex = -1     
        }

        #If the correct route is already defined somewhere else, don't do anything
        if ($RtPrefixIndex -eq -1) {
            #If route doesn't exist
            if ($RtNameIndex -eq -1) {
                Write-Output "Adding KMS Host route"
                $AddedIPs = $AddedIPs + 1
                Add-AzureRmRouteConfig `
                    -Name $KMSRouteName `
                    -AddressPrefix $KMSPrefix `
                    -NextHopType Internet `
                    -RouteTable $RouteTable | Out-Null #!!# Added "Out-Null"
                $RouteUpdateRequ = $true
                $newRoute = 1
            } else {
                #if route exists but the prefix has changed
                if ($Routetable.routes[$RtNameIndex].AddressPrefix -ne $KMSPrefix) {
                    Write-Output "Updating KMS Host route"
                    $UpdIPs = $UpdIPs + 1
                    Set-AzureRmRouteConfig `
                        -Name $KMSRouteName `
                        -AddressPrefix $KMSPrefix `
                        -NextHopType Internet `
                        -RouteTable $RouteTable
                    $RouteUpdateRequ = $true
                }
            }
        }

########################################################################################

#Script validation - Remove comment below
#$inParam_RemoveOther = $true
        if ($inParam_RemoveOther -eq $true) {
            Write-Output "At line 159"
            $RoutesToRemove = @()
            $ExistingRoutes = $RouteTable.Routes | Where-Object {$_.Name -like 'MSDCAuto-*'} 
            Write-Output "ExistingRoutes: $($ExistingRoutes.Count)"

#Script validation - Remove comment below
#$ExRoute = $ExistingRoutes
#$RtPrefixIndex = -1

            foreach ($ExRoute in $ExistingRoutes) {
                $RtPrefixIndex = $ipRanges.Subnet.IndexOf($ExRoute.AddressPrefix)
                if ($RtPrefixIndex -eq -1) {
                    $RoutesToRemove += $ExRoute.Name
                }
            }
            Write-Output "Removed Redundant Routes: $($RoutesToRemove.count)"
            foreach ($RemRoute in $RoutesToRemove) {
                Remove-AzureRmRouteConfig -Name $RemRoute -RouteTable $RouteTable | Out-Null
            }
            #!!#Set Variable to commit delete(s)
            $RouteUpdateRequ = $true
        }

########################################################################################

        if ($newRoute -eq 1) {
            #$countRoutes = ((Get-AzureRmRouteTable -Name (Get-AzureRmResource -ResourceId $Subnet.RouteTable.Id).Name -ResourceGroupName $RouteTableRes.ResourceGroupName).Routes.Count) + 1     
            $countRoutes = ((Get-AzureRmRouteTable -Name (Get-AzureRmResource -ResourceId $Subnet.RouteTable.Id).Name -ResourceGroupName $InParam_ResourceGroupName).Routes.Count) + 1     

        } else {
            #$countRoutes = (Get-AzureRmRouteTable -Name (Get-AzureRmResource -ResourceId $Subnet.RouteTable.Id).Name -ResourceGroupName $RouteTableRes.ResourceGroupName).Routes.Count     
            $countRoutes = (Get-AzureRmRouteTable -Name (Get-AzureRmResource -ResourceId $Subnet.RouteTable.Id).Name -ResourceGroupName $InParam_ResourceGroupName).Routes.Count     
        }

        #loop through the IPRanges retrieved
        foreach($ipRange in $ipRanges) {

                if ($countRoutes -lt $limit) {
                    $routeName = 'MSDCAuto-' + ($ipRange.Region.Replace(' ','').ToLower()) + '-' + $ipRange.Subnet.Replace('/','-')
            
                    if ($RouteTable.Routes.Count -eq 0 ) {
                        $RtNameIndex = -1
                        $RtPrefixIndex = -1
                    } else {
                        $RtNameIndex = $RouteTable.Routes.Name.IndexOf($routeName)
                        $RtPrefixIndex = $RouteTable.Routes.AddressPrefix.IndexOf($ipRange.Subnet)
                    }
            #If the correct route is already defined somewhere else, don't do anything
            if ($RtPrefixIndex -eq -1) {
                #if routename does not exist
                if (($RtNameIndex -eq -1) ) {
                    $AddedIPs = $AddedIPs + 1
                    Add-AzureRmRouteConfig `
                        -Name $routeName `
                        -AddressPrefix $ipRange.Subnet `
                        -NextHopType Internet `
                        -RouteTable $RouteTable | Out-Null
                    $RouteUpdateRequ = $true
                } else {
                    #if route name exists but prefix has changed (and doesn't exist elsewhere)
                    if ($RouteTable.routes[$RtNameIndex].AddressPrefix -ne $ipRange.Subnet) {
                        $UpdIPs = $UpdIPs + 1
                        Set-AzureRmRouteConfig `
                            -Name $routeName `
                            -AddressPrefix $ipRange.Subnet `
                            -NextHopType Internet `
                            -RouteTable $RouteTable | Out-Null
                        $RouteUpdateRequ = $true
                    }
                }
            }

        $countRoutes = $countRoutes + 1
      }
      } #End ipRanges loop

########################################################################################                         

        if ($countRoutes -ge $limit) {
            $routesOverMax = @()

            #loop through the IPRanges retrieved to report routes not written over limit
            foreach($ipRange in $ipRanges){
                    $RtPrefixIndex = $RouteTable.Routes.AddressPrefix.IndexOf($ipRange.Subnet)
                    if ($RtPrefixIndex -eq -1) {
                        $routesOverMax = $routesovermax + $ipRange
                    }
            }
            $routesOverMax = $routesOverMax | Sort-Object -Property Region
            Write-Output "Routes NOT Written - over Limit: $($routesOverMax.Count)" 
        } else {

            if ($RouteUpdateRequ -eq $true) {
                Write-Output "Added New Routes: $($AddedIPs)"
                Write-Output "Updated Existing Routes: $($UpdIPs)"
                ### Apply the route table to the subnet
                Set-AzureRmRouteTable -RouteTable $RouteTable | Out-Null
            }
        }
######################################################################################## 


            #!!# Added recal of total routes
            $totalRoute = Get-AzureRmResource -ResourceId $Subnet.RouteTable.Id
            $totalRoutes = Get-AzureRmRouteTable -Name $totalRoute.Name -ResourceGroupName $totalRoute.ResourceGroupName
            Write-Output "Total Routes in Route Table: $($totalRoutes.Routes.Count)"
            Write-Output "Total Azure DC Public IP Ranges for Selected Locations: $($ipRanges.Count)
            
            "  

            $SubnetRef = $VNet.Subnets.Name.IndexOf($subnet.Name)
            $VNet.Subnets[$SubnetRef] = $subnet
            
            Write-Output "Subnet: $($subnet.Name)"
            Write-Output "SubnetRef: $($SubnetRef)"
            Write-Output "VNetUpdateRequ: $($VNetUpdateRequ)"         

}#######################################################################################
#Finish Subnet Loop
########################################################################################
if ($VNetUpdateRequ -eq $true) {
    Set-AzureRmVirtualNetwork -VirtualNetwork $vnet | Out-Null
}

}#######################################################################################
#Finish vNet Loop
########################################################################################
$EndTime = Get-Date
$RunTime = ($EndTime - $StartTime).Minutes
Write-Output "RunTime: $($RunTime) Minutes"