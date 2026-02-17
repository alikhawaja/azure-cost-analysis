$spldigital = "ca4b9986-c729-4ee0-a5be-39c116865241"
$saudipost = "50b52b92-3783-42b4-9db8-9a2064125c06"

$entra_tenant = $spldigital # or $saudipost

# --- Login ---
Connect-AzAccount -TenantId $entra_tenant -ErrorAction Stop

# --- Get matching subscriptions ---
# Get all subscriptions with 'prd' in their name
$subscriptions = Get-AzSubscription -TenantId $entra_tenant | Where-Object { $_.Name -like "*prd*" }

if (-not $subscriptions) {
    Write-Warning "No subscriptions found matching filter '*$SubscriptionFilter*'"
    return
}

$results = @()

foreach ($sub in $subscriptions) {
    $subscriptionId = $sub.Id
    $subscriptionName = $sub.Name
    Write-Output "`n--- Subscription: $subscriptionName ($subscriptionId) ---"

    try {
        # Query month-to-date usage costs with daily granularity
        # Ref: https://learn.microsoft.com/powershell/module/az.costmanagement/invoke-azcostmanagementquery
        $costQuery = Invoke-AzCostManagementQuery `
            -Scope "/subscriptions/$subscriptionId" `
            -Type Usage `
            -Timeframe MonthToDate `
            -DatasetGranularity 'Daily'

        if ($costQuery.Row) {
            # Inspect columns to find the Cost and Currency positions
            $columns = $costQuery.Column | ForEach-Object { $_.Name }
            Write-Verbose "Columns: $($columns -join ', ')"

            # Sum the cost column (index 1) by casting each value to double
            $totalCost = 0.0
            $currency = "USD"
            foreach ($row in $costQuery.Row) {
                $totalCost += [double]$row[1]
                $currency = $row[2]  # last non-null currency wins
            }

            Write-Output "  Month-to-Date Cost: $([math]::Round($totalCost, 2)) $currency"
            Write-Output "  Days with data: $($costQuery.Row.Count)"

            $results += [PSCustomObject]@{
                Subscription = $subscriptionName
                SubscriptionId = $subscriptionId
                MonthToDateCost = [math]::Round($totalCost, 2)
                Currency = $currency
            }
        }
        else {
            Write-Output "  No cost data returned for this subscription."
        }
    }
    catch {
        Write-Warning "  Failed to query costs for $subscriptionName : $_"
    }
}

# --- Summary ---
Write-Output "`n=== Cost Summary ==="
$results | Format-Table -AutoSize

# Optionally export to CSV
# $results | Export-Csv -Path ".\cost-report-$(Get-Date -Format 'yyyy-MM-dd').csv" -NoTypeInformation
