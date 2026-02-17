# Script to discover and analyze SQL Elastic Pool utilization across all subscriptions
$spl_digital = "ca4b9986-c729-4ee0-a5be-39c116865241"
$spl = "50b52b92-3783-42b4-9db8-9a2064125c06"

$entra_tenant = $spl_digital

# Connect to Azure (uncomment if not already connected)
# Connect-AzAccount -Tenant $entra_tenant -UseDeviceAuthentication

Write-Host "🔍 Discovering SQL Elastic Pools across all subscriptions..." -ForegroundColor Cyan

# Get all subscriptions
$subscriptions = Get-AzSubscription
$results = @()
$totalPools = 0

$subscription = "https://portal.azure.com/#resource/subscriptions/945c9455-d93f-487e-bfc5-03e5410eae09"
$resourceGroups = @("rg-splg-logsp-common-prd-ger-01", "rg-splg-logsp-common-uat-ger-01", "rg-splg-logsp-common-dev-ger-01") # Add more resource groups if needed   
$sqlServerNames = @("sql-splg-logsp-prd-ger-01", "sql-splg-logsp-uat-ger-01","sql-splg-logsp-dev-ger-01")


foreach ($subscription in $subscriptions) {
    Write-Host "`n📍 Checking subscription: $($subscription.Name)" -ForegroundColor Yellow
    
    try {
        Set-AzContext -SubscriptionId $subscription.Id | Out-Null
        
        # Get all resource groups in this subscription
        $resourceGroups = Get-AzResourceGroup
        
        foreach ($rg in $resourceGroups) {
            Write-Host "   🔍 Checking resource group: $($rg.ResourceGroupName)" -ForegroundColor Gray
            
            try {
                # Get all SQL servers in this resource group
                $sqlServers = Get-AzSqlServer -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
                
                foreach ($server in $sqlServers) {
                    Write-Host "      🖥️ Checking SQL Server: $($server.ServerName)" -ForegroundColor DarkGray
                    
                    try {
                        # Get all elastic pools for this server
                        $elasticPools = Get-AzSqlElasticPool -ResourceGroupName $rg.ResourceGroupName -ServerName $server.ServerName -ErrorAction SilentlyContinue
                        
                        foreach ($pool in $elasticPools) {
                            $totalPools++
                            Write-Host "         💎 Found Elastic Pool: $($pool.ElasticPoolName)" -ForegroundColor Green
                            
                            try {
                                # Get utilization metrics for the pool (last 24 hours)
                                $endTime = Get-Date
                                $startTime = $endTime.AddHours(-24)
                                
                                # Try different metric names based on pool edition
                                $metricName = if ($pool.Edition -eq "Basic" -or $pool.Edition -eq "Standard" -or $pool.Edition -eq "Premium") {
                                    "dtu_consumption_percent"
                                } else {
                                    "cpu_percent"  # For vCore-based pools
                                }
                                
                                $metrics = Get-AzMetric -ResourceId $pool.ResourceId `
                                    -MetricName $metricName `
                                    -StartTime $startTime `
                                    -EndTime $endTime `
                                    -AggregationType Average `
                                    -ErrorAction SilentlyContinue
                                
                                # Calculate average utilization if metrics exist
                                $avgUtilization = 0
                                $maxUtilization = 0
                                if ($metrics.Data -and $metrics.Data.Count -gt 0) {
                                    $validData = $metrics.Data | Where-Object { $_.Average -ne $null }
                                    if ($validData) {
                                        $avgUtilization = ($validData | Measure-Object -Property Average -Average).Average
                                        $maxUtilization = ($validData | Measure-Object -Property Average -Maximum).Maximum
                                    }
                                }
                                
                                $results += [PSCustomObject]@{
                                    SubscriptionName   = $subscription.Name
                                    SubscriptionId     = $subscription.Id
                                    ResourceGroup      = $rg.ResourceGroupName
                                    ServerName         = $server.ServerName
                                    PoolName          = $pool.ElasticPoolName
                                    Edition           = $pool.Edition
                                    DTU               = $pool.Dtu
                                    vCores            = $pool.VCore
                                    StorageGB         = [math]::Round($pool.StorageMB / 1024, 2)
                                    AvgUtilization    = [math]::Round($avgUtilization, 2)
                                    MaxUtilization    = [math]::Round($maxUtilization, 2)
                                    State             = $pool.State
                                    Location          = $pool.Location
                                    MetricType        = $metricName
                                }
                            }
                            catch {
                                Write-Warning "         ⚠️ Error retrieving metrics for pool $($pool.ElasticPoolName): $($_.Exception.Message)"
                                
                                # Still add the pool info even without metrics
                                $results += [PSCustomObject]@{
                                    SubscriptionName   = $subscription.Name
                                    SubscriptionId     = $subscription.Id
                                    ResourceGroup      = $rg.ResourceGroupName
                                    ServerName         = $server.ServerName
                                    PoolName          = $pool.ElasticPoolName
                                    Edition           = $pool.Edition
                                    DTU               = $pool.Dtu
                                    vCores            = $pool.VCore
                                    StorageGB         = [math]::Round($pool.StorageMB / 1024, 2)
                                    AvgUtilization    = "N/A"
                                    MaxUtilization    = "N/A"
                                    State             = $pool.State
                                    Location          = $pool.Location
                                    MetricType        = "Error retrieving metrics"
                                }
                            }
                        }
                    }
                    catch {
                        Write-Verbose "No elastic pools found for server $($server.ServerName) or access denied"
                    }
                }
            }
            catch {
                Write-Verbose "No SQL servers found in resource group $($rg.ResourceGroupName) or access denied"
            }
        }
    }
    catch {
        Write-Warning "Error accessing subscription $($subscription.Name): $($_.Exception.Message)"
    }
}

# Display results
Write-Host "`n📊 RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "=================" -ForegroundColor Cyan

if ($results) {
    Write-Host "Total SQL Elastic Pools found: $totalPools" -ForegroundColor Green
    
    # Display detailed results
    $results | Format-Table -AutoSize
    
    # Calculate statistics for pools with valid metrics
    $poolsWithMetrics = $results | Where-Object { $_.AvgUtilization -ne "N/A" -and $_.AvgUtilization -gt 0 }
    
    if ($poolsWithMetrics) {
        $overallAverage = ($poolsWithMetrics.AvgUtilization | Measure-Object -Average).Average
        $highestUtil = ($poolsWithMetrics.AvgUtilization | Measure-Object -Maximum).Maximum
        $lowestUtil = ($poolsWithMetrics.AvgUtilization | Measure-Object -Minimum).Minimum
        
        Write-Host "`n📈 UTILIZATION STATISTICS" -ForegroundColor Yellow
        Write-Host "========================" -ForegroundColor Yellow
        Write-Host "Overall Average Utilization: $([math]::Round($overallAverage, 2))%" -ForegroundColor Green
        Write-Host "Highest Utilization: $([math]::Round($highestUtil, 2))%" -ForegroundColor $(if($highestUtil -gt 80) {"Red"} else {"Green"})
        Write-Host "Lowest Utilization: $([math]::Round($lowestUtil, 2))%" -ForegroundColor Green
        Write-Host "Pools with metrics: $($poolsWithMetrics.Count) out of $totalPools" -ForegroundColor Cyan
        
        # Identify underutilized pools (less than 30% average)
        $underutilized = $poolsWithMetrics | Where-Object { $_.AvgUtilization -lt 30 }
        if ($underutilized) {
            Write-Host "`n⚠️ UNDERUTILIZED POOLS (< 30% avg utilization):" -ForegroundColor Yellow
            $underutilized | Select-Object PoolName, ServerName, ResourceGroup, AvgUtilization | Format-Table
        }
        
        # Identify highly utilized pools (more than 80% average)
        $highlyUtilized = $poolsWithMetrics | Where-Object { $_.AvgUtilization -gt 80 }
        if ($highlyUtilized) {
            Write-Host "`n🔥 HIGHLY UTILIZED POOLS (> 80% avg utilization):" -ForegroundColor Red
            $highlyUtilized | Select-Object PoolName, ServerName, ResourceGroup, AvgUtilization, MaxUtilization | Format-Table
        }
    }
    
    # Export results to CSV
    $csvPath = ".\SqlElasticPoolUtilization_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    $results | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Host "`n💾 Results exported to: $csvPath" -ForegroundColor Green
}
else {
    Write-Host "No SQL Elastic Pools found in any subscription." -ForegroundColor Yellow
}