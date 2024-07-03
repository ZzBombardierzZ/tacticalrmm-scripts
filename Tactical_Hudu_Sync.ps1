<#
.SYNOPSIS
    Syncs agents from Tactical RMM to Hudu.

.REQUIREMENTS
    - You will need an API key from Hudu and Tactical RMM which should be passed as parameters (DO NOT hard code in script).  
    - This script imports/installs powershell module https://github.com/lwhitelock/HuduAPI which you may have to manually install if errors.

.NOTES
    - Ideally, this script should be run on the Tactical RMM server however since there is no linux agent, 
      you'll have to run this on one of your trusted Windows devices.
    - This script compares Tactical's Client Name with Hudu's Company Names and if there is a match (case sensitive) 
      it creates/syncs asset based on hostname.  Nothing will be created or synced if a company match is not found.  

.PARAMETERS
    - $ApiKeyTactical   - Tactical API Key
    - $ApiUrlTactical   - Tactical API Url
    - $ApiKeyHudu       - Hudu API Key
    - $ApiUrlHudu       - Hudu API Url
    - $HuduAssetName    - The name of the asset in Hudu.  Defaults to "TacticalRMM Agents"
    - $CopyMode         - If set, the script will not delete the assets in Hudu before syncing (Any items deleted from Tactical will remain in Hudu until manually removed).  
.EXAMPLE
    - Tactical_Hudu_Sync.ps1 -ApiKeyTactical 1234567 -ApiUrlTactical api.yourdomain.com -ApiKeyHudu 1248ABBCD3 -ApiUrlHudu hudu.yourdomain.com -HuduAssetName "Tactical Agents" -CopyMode
.TODO
    - fix Get-ArrayData so that it doesn't display all in one line
    - add optional Hudu Relations to the built in Office 365 integration (e.g. last_logged_in_user so you can match a logged in user with their respective workstations)
    - add more tactical fields
    - reduce the amount of rest calls made
        
.VERSION
    - v1.0 Initial Release by https://github.com/bc24fl/tacticalrmm-scripts/
    - v1.1 Fixed and added a ton, by Bomb.
#>

param(
    [string] $ApiKeyTactical,
    [string] $ApiUrlTactical,
    [string] $ApiKeyHudu,
    [string] $ApiUrlHudu,
    [string] $HuduAssetName,
    [switch] $CopyMode
)

function Get-ArrayData {
    param(
        $data
    )
    $formattedData = ""
    foreach ($item in $data){
        $formattedData += $item -join ", "
    }
    return $formattedData
}

function Get-CustomFieldData {
    param(
        $label,
        $arrayData
    )
    $value = ""
    foreach ($f in $arrayData) {
        if ($f.label -eq $label){
            $value = $f.value
        }
    }
    return $value
}

function Get-TacticalCustomFieldData {
    param(
        $field_id,
        $arrayData
    )
    $value = ""
    foreach ($f in $arrayData) {
        if ($f.field -eq $field_id){
            $value = $f.value
        }
    }
    return $value
}

function Get-TacticalCustomFieldAgentIDNumber {
    param(
        $field_id,
        $arrayData
    )
    $value = ""
    foreach ($f in $arrayData) {
        $value = $f.agent
    }
    return $value
}

function Get-TacticalSites {
    param(
        [string] $ApiUrlTactical,
        [hashtable] $Headers
    )
    try {
        $sitesResult = Invoke-RestMethod -Method 'Get' -Uri "https://$ApiUrlTactical/clients/sites" -Headers $Headers -ContentType "application/json"
        return $sitesResult
    }
    catch {
        throw "Error invoking rest call on Tactical RMM for sites with error: $($PSItem.ToString())"
    }
}

function SiteIdInList {
    param(
        $site,
        $id
    )
    $siteIds = Get-CustomFieldData -label "RMM Site ID(s)" -arrayData $site.fields
    $idList = $siteIds -split ",\s*"
    return $idList -contains $id
}

if ([string]::IsNullOrEmpty($ApiKeyTactical)) {
    throw "ApiKeyTactical must be defined. Use -ApiKeyTactical <value> to pass it."
}

if ([string]::IsNullOrEmpty($ApiUrlTactical)) {
    throw "ApiUrlTactical without the https:// must be defined. Use -ApiUrlTactical <value> to pass it."
}

if ([string]::IsNullOrEmpty($ApiKeyHudu)) {
    throw "ApiKeyHudu must be defined. Use -ApiKeyHudu <value> to pass it."
}

if ([string]::IsNullOrEmpty($ApiUrlHudu)) {
    throw "ApiUrlHudu without the https:// must be defined. Use -ApiUrlHudu <value> to pass it."
}

if ([string]::IsNullOrEmpty($HuduAssetName)) {
    Write-Host "HuduAssetName param not defined.  Using default name TacticalRMM Agents."
    $HuduAssetName = "TacticalRMM Agents"
}

try {
    if (Get-Module -ListAvailable -Name HuduAPI) {
        Import-Module HuduAPI 
    } else {
        Install-Module HuduAPI -Force
        Import-Module HuduAPI
    }
}
catch {
    throw "Installation of HuduAPI failed.  Please install HuduAPI manually first by running: 'Install-Module HuduAPI' on server."
}

$headers= @{
    'X-API-KEY' = $ApiKeyTactical
}

New-HuduAPIKey $ApiKeyHudu 
New-HuduBaseURL "https://$ApiUrlHudu" 

$huduSiteName = "Sites"

# Sites
$huduSiteLayout = Get-HuduAssetLayouts -name $huduSiteName

if (!$huduSiteLayout){
    Write-Host "WARNING: Hudu Site layout wasn't found. Creating one now." -ForegroundColor Yellow
    $fields = @(
    @{
        label = 'Address'
        field_type = 'Text'
        position = 1
        show_in_list = $true
    },
    @{
        label = 'Office Phone'
        field_type = 'Phone'
        position = 2
        show_in_list = $true
    },
    @{
        label = 'RMM Site ID(s)'
        field_type = 'Text'
        position = 3
        required = $true
    })
    New-HuduAssetLayout -name $huduSiteName -icon "fas fa-building" -color "#5B17F2" -icon_color "#ffffff" -include_passwords $false -include_photos $false -include_comments $false -include_files $false -fields $fields
}

$huduSiteLayout = Get-HuduAssetLayouts -name $huduSiteName
$huduSites = Get-HuduAssets -assetlayoutid $huduSiteLayout.id

if (!$huduSites) {
    Write-Host "WARNING: Hudu has no sites in $huduSiteName" -ForegroundColor Yellow
}

Write-Host "Hudu Site Layout: $($huduSiteLayout.id) - $($huduSiteLayout.name)"
Write-Host "Hudu Sites: $($huduSites.Count)"

$huduSitesList = @($huduSites)  # Initialize as array to avoid method invocation error

# Fetch Tactical RMM Sites
$tacticalSites = Get-TacticalSites -ApiUrlTactical $ApiUrlTactical -Headers $headers

# Create a mapping for Tactical site names to RMM Site IDs
$tacticalSiteMap = @{}
foreach ($site in $tacticalSites) {
    $tacticalSiteMap[$site.name] = $site.id
}

# Create a mapping for Hudu RMM Site IDs
$huduSiteMap = @{}
foreach ($site in $huduSitesList) {
    $siteIds = Get-CustomFieldData -label "RMM Site ID(s)" -arrayData $site.fields
    $siteIdList = $siteIds -split ",\s*"
    foreach ($siteId in $siteIdList) {
        $huduSiteMap[$siteId] = $site
    }
}

$huduAssetLayout = Get-HuduAssetLayouts -name $HuduAssetName

# Create Hudu Asset Layout if it does not exist
if (!$huduAssetLayout){
    $fields = @(
    @{
        label = 'Site'
        field_type = 'AssetTag'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 1
        show_in_list = $true
        linkable_id = $huduSiteLayout.id
    },
    @{
        label = 'Status'
        field_type = 'CheckBox'
        hint = 'Online/Offline - DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 2
    },
    @{
        label = 'Description'
        field_type = 'Text'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 3
    },
    @{
        label = 'Patches Pending'
        field_type = 'CheckBox'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 4
    },
    @{
        label = 'Last Seen'
        field_type = 'Date'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 5
        show_in_list = $true
    },
    @{
        label = 'Last Logged Username'
        field_type = 'Text'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 6
        show_in_list = $true
    },
    @{
        label = 'Needs Reboot'
        field_type = 'CheckBox'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 7
        show_in_list = $true
    },
    @{
        label = 'Overdue Dashboard Alert'
        field_type = 'CheckBox'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 8
    },
    @{
        label = 'Overdue Email Alert'
        field_type = 'CheckBox'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 9
    },
    @{
        label = 'Overdue Text Alert'
        field_type = 'CheckBox'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 10
    },
    @{
        label = 'Pending Actions Count'
        field_type = 'Number'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 11
    },
    @{
        label = 'Make Model'
        field_type = 'Text'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 12
        show_in_list = $true
    },
    @{
        label = 'CPU Model'
        field_type = 'RichText'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 13
    },
    @{
        label = 'Total GB of RAM'
        field_type = 'Number'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 14
    },
    @{
        label = 'Operating System'
        field_type = 'Text'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 15
    },
    @{
        label = 'Local Ips'
        field_type = 'Text'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 16
    },
    @{
        label = 'Public Ip'
        field_type = 'Text'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 17
    },
    @{
        label = 'Graphics'
        field_type = 'Text'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 18
    },
    @{
        label = 'Disks'
        field_type = 'RichText'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 19
    },    
    @{
        label = 'Created Time'
        field_type = 'Text'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 20
    },
    @{  # Custom ones
        label = 'Warranty Expiration'
        field_type = 'Date'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 21
        show_in_list = $true
        expiration = $true
    },
    @{  # Custom ones
        label = 'Serial Number'
        field_type = 'Text'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 22
        show_in_list = $true
    },
    @{  # Custom ones
        label = 'Custom Asset Tag'
        field_type = 'Text'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 23
        show_in_list = $true
    },
    @{
        label = 'Agent Id'
        field_type = 'Text'
        hint = 'DO NOT EDIT SYNCED ASSETS FROM HUDU. EDIT THEM IN THE RMM SYSTEM.'
        position = 24
    })
    New-HuduAssetLayout -name $HuduAssetName -icon "fas fa-fire" -color "#5B17F2" -icon_color "#ffffff" -include_passwords $false -include_photos $false -include_comments $false -include_files $false -fields $fields
    Start-Sleep -s 5
    $huduAssetLayout = Get-HuduAssetLayouts -name $HuduAssetName
    Write-Host "Hudu Asset Layout created: $($huduAssetLayout.id) - $($huduAssetLayout.name)" -ForegroundColor Green
}

# If not CopyMode set, delete all assets before performing sync
if (!$CopyMode){
    $assetsToDelete = Get-HuduAssets -assetlayoutid $huduAssetLayout.id
    foreach ($asset in $assetsToDelete){
        $assetId        = $asset.id
        $assetName      = $asset.name
        $assetCompanyId = $asset.company_id
        Write-Host "Deleting $assetName from company id $assetCompanyId with an asset id of $assetId"
        Remove-HuduAsset -Id $asset.id -CompanyId $asset.company_id
    }
}

try {
    $agentsResult = Invoke-RestMethod -Method 'Get' -Uri "https://$ApiUrlTactical/agents" -Headers $headers -ContentType "application/json"
    Write-Host "Agents Result: $(Get-ArrayData -data $agentsResult)"
}
catch {
    throw "Error invoking rest call on Tactical RMM with error: $($PSItem.ToString())"
}

$for_each_index = 0

foreach ($agent in $agentsResult) {
    $for_each_index++
    Write-Host "Processing agent number $for_each_index of $($agentsResult.Count)"

    $agentId = $agent.agent_id
    $serial_number = $agent.serial_number # Custom added

    $huduCompaniesFiltered = Get-HuduCompanies -name $agent.client_name

    # If Hudu Company matches a Tactical Client
    if (!$huduCompaniesFiltered){
        Write-Host "Company does not exist in Hudu: $($agent.client_name)" -ForegroundColor Red
        continue
    }

    # Check if site exists in Hudu
    $siteToLinkArray = @()
    if ($tacticalSiteMap.ContainsKey($agent.site_name)) {
        $tacticalSiteId = $tacticalSiteMap[$agent.site_name].ToString()
        if ($huduSiteMap.ContainsKey($tacticalSiteId)) {
            $site = $huduSiteMap[$tacticalSiteId]
            $siteName = $site.name
            $siteId = $site.id
            $siteAddress = Get-CustomFieldData -label "Address" -arrayData $site.fields
            $sitePhone = Get-CustomFieldData -label "Office Phone" -arrayData $site.fields
            Write-Host "Site: $siteName - $siteId - $siteAddress - $sitePhone"
            $siteToLink = $site | Select-Object id, url, name
            $siteToLink.url = $siteToLink.url -replace "https://$ApiUrlHudu", ""
            $siteToLinkArray += $siteToLink
        } else {
            Write-Host "RMM RMM Site ID $tacticalSiteId does not exist in Hudu: $($agent.site_name)" -ForegroundColor Red
            # Create Site in Hudu
            New-HuduAsset -name $agent.site_name -company_id $huduCompaniesFiltered.id -assetlayoutid $huduSiteLayout.id -fields @(@{address = ''; office_phone = ''; "RMM Site ID(s)" = $tacticalSiteId})
            $site = Get-HuduAssets -name $agent.site_name -assetlayoutid $huduSiteLayout.id # Get the site that was just created. New-HuduAsset does not return the asset... 🙄
            $huduSitesList += @($site)
            $siteToLink = $site | Select-Object id, url, name
            $siteToLink.url = $siteToLink.url -replace "https://$ApiUrlHudu", ""
            $siteToLinkArray += $siteToLink
            # Update the site map
            foreach ($newSiteId in ($tacticalSiteId -split ",\s*")) {
                $huduSiteMap[$newSiteId] = $site
            }
            Write-Host "Site created in Hudu: $($agent.site_name)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Site name $($agent.site_name) not found in Tactical site map." -ForegroundColor Red
    }

    $siteToLinkJson = $siteToLinkArray | ConvertTo-Json -Compress -AsArray
    Write-Host "Site(s) found or created: $($siteToLinkJson)" -ForegroundColor Yellow

    try {
        $agentDetailsResult = Invoke-RestMethod -Method 'Get' -Uri "https://$ApiUrlTactical/agents/$agentId" -Headers $headers -ContentType "application/json"
    }
    catch {
        Write-Error "Error invoking agent detail rest call on Tactical RMM with error: $($PSItem.ToString())"
    }

    #Write-Host "Full details: $agentDetailsResult"

    $textDisk   = Get-ArrayData -data $agentDetailsResult.disks
    $textCpu    = Get-ArrayData -data $agentDetailsResult.cpu_model
    $warrantyExp = Get-TacticalCustomFieldData -field_id 32 -arrayData $agentDetailsResult.custom_fields
    $CustomAssetTag = Get-TacticalCustomFieldData -field_id 5 -arrayData $agentDetailsResult.custom_fields
    $agent_id_number = Get-TacticalCustomFieldAgentIDNumber -arrayData $agentDetailsResult.custom_fields # agent has to have been online since the custom field was created. Field 1 (serial number) was added before any/most devices.

    # The name on the left needs to match the label in the Hudu Asset Layout listed above... (caps dont matter, spaces need to be _'s)
    $fieldData = @(
    @{
        site                    = $siteToLinkJson
        status                  = $agent.status
        description             = $agent.description
        patches_pending         = $agent.has_patches_pending
        last_seen               = $agent.last_seen
        last_logged_username    = $agentDetailsResult.last_logged_in_user
        needs_reboot            = $agent.needs_reboot
        overdue_dashboard_alert = $agent.overdue_dashboard_alert
        overdue_email_alert     = $agent.overdue_email_alert
        overdue_text_alert      = $agent.overdue_text_alert
        pending_actions_count   = $agent.pending_actions_count
        total_ram               = $agentDetailsResult.total_ram
        local_ips               = $agentDetailsResult.local_ips
        created_time            = $agentDetailsResult.created_time
        graphics                = $agentDetailsResult.graphics
        make_model              = $agentDetailsResult.make_model
        operating_system        = $agentDetailsResult.operating_system
        public_ip               = $agentDetailsResult.public_ip
        disks                   = $textDisk
        cpu_model               = $textCpu
        # Custom ones 
        warranty_expiration     = $warrantyExp
        serial_number           = $serial_number
        custom_asset_tag        = $CustomAssetTag
        # Agent ID - Used to match Tactical Agent ID with Hudu Agent ID
        agent_id                = $agentId
    })

    $asset = Get-HuduAssets -assetlayoutid $huduAssetLayout.id -companyid $huduCompaniesFiltered.id | Where-Object { $_.fields | Where-Object { $_.label -eq "Agent Id" -and $_.value -eq $agentId } }

    # If asset exist and the Hudu asset matches Tactical based on $agent_id_number update.  Else create new asset
    if ($asset){
        Write-Host "Updating Agent $agent_id_number for $($agent.hostname)" -ForegroundColor Green
        Set-HuduAsset -name $agent.hostname -company_id $huduCompaniesFiltered.id -asset_layout_id $huduAssetLayout.id -fields $fieldData -asset_id $asset.id
    } else {
        Write-Host "Asset does not exist in Hudu.  Creating Agent $agent_id_number for $($agent.hostname)" -ForegroundColor Yellow
        New-HuduAsset -name $agent.hostname -company_id $huduCompaniesFiltered.id -asset_layout_id $huduAssetLayout.id -fields $fieldData
    }

    #pause;           # uncomment to pause after each agent
}
