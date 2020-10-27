Create direct UDRs for published Microsoft Azure Datacentre IPs
===============================================================


  *  

SYNOPSIS
This script creates UDRs for the Microsoft Published Datacenter IP addresses for the specified region in all VNets found in the specified subscription and resource group.
This script can be uploaded as an Azure Automation Runbook and scheduled to allow for any IP address changes.


  *  

DESCRIPTION
This script retrieves the published Microsoft Azure Datacenter IPs address, creates a common table based on location or uses an existing route table if one is already bound to the subnet and creates the UDRs.
Also included is a route for the Microsoft KMS service to allow for windows activation.


  *  

PRE-REQUISITES
A RunAs account named 'AzureRunAsConnection' must be created and have at least network contributor access to the subscriptions and resource groups to be passed as parameters.


  *  
MODULES

  *  
AzureRM > 3.6.0

  *  
AzurePublicIPAddresses > 0.8.3


  *  
INPUTS

  *  $InParam_SubscriptionID
The subscription ID to authenticate to and operate in 
  *  $InParam_ResourceGroupName
The Resource Group to find all VNets in and update routes and route tables 
  *  $InParam_AzureRegion
The Azure Datacenter region to retrieve IP address for.
Please see the attached spreadsheet for the available Datacenters, use the shortname field for this parameter.
AzureDatacenterDetails.xlsx
The current CIDR count has been included and is accurate at time of writing, some regions will exceed the default 100 routes limit.
This can be increased to a maximum of 400 upon request and justification via a support ticket.

  *  $InParam_RouteLimit
The current route limit imposed on the subscription and region, used to avoid errors if the limit is exceeded.

  *  $InParam_CommonRouteTablePrefix
A route table will be created, starting with this Prefix followed by '-' and the Location of the VNet being updated.

  *  $inParam_OverRideRTwithCommon
If this parameter is passed as true, all existing Route Tables will be un-associated with the subnets and replaced with the common one.

  *  $inParam_RemoveOther
If True, all existing Datacenter routes (only) will be removed.
If False, all existing routes will be left intact. 

 



 

 


        
    
TechNet gallery is retiring! This script was migrated from TechNet script center to GitHub by Microsoft Azure Automation product group. All the Script Center fields like Rating, RatingCount and DownloadCount have been carried over to Github as-is for the migrated scripts only. Note : The Script Center fields will not be applicable for the new repositories created in Github & hence those fields will not show up for new Github repositories.
