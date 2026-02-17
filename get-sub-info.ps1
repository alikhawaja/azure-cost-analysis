$spl_digital = "ca4b9986-c729-4ee0-a5be-39c116865241"
$spl = "50b52b92-3783-42b4-9db8-9a2064125c06"

$entra_tenant = $spl_digital

Connect-AzAccount -Tenant $entra_tenant -UseDeviceAuthentication

# Retrieve all subscriptions
$subscriptions = Get-AzSubscription

# Get estimated costs for each subscription
$results = @()
foreach ($subscription in $subscriptions) {
    Set-AzContext -SubscriptionId $subscription.Id | Out-Null
    
    $costData = Get-AzCostManagementQuery -Timeframe MonthToDate -Granularity Daily `
        -Scope "/subscriptions/$($subscription.Id)" `
        -Metric "BlendedCost" -GroupBy @{name="ResourceType"; type="Dimension"}
    
    $estimatedCost = ($costData.Column | Where-Object { $_.Name -eq "BlendedCost" }).Value | Measure-Object -Sum | Select-Object -ExpandProperty Sum
    
    $results += [PSCustomObject]@{
        SubscriptionName = $subscription.Name
        SubscriptionId   = $subscription.Id
        EstimatedCost    = $estimatedCost
    }
}

$results | Format-Table -AutoSize
