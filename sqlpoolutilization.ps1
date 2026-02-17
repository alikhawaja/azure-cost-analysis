# Script to discover and analyze SQL Elastic Pool utilization across all subscriptions
$spl_digital = "ca4b9986-c729-4ee0-a5be-39c116865241"
$spl = "50b52b92-3783-42b4-9db8-9a2064125c06"

$entra_tenant = $spl_digital

# Connect to Azure (uncomment if not already connected)
# Connect-AzAccount -Tenant $entra_tenant -UseDeviceAuthentication

# Initialize results
$results = @()
$totalPools = 0

$subscriptionId = "945c9455-d93f-487e-bfc5-03e5410eae09"

# Create a collection of resource groups paired with their SQL server names
$rgwithsqlsrvs = @(
    @{ ResourceGroup = "rg-splg-logsp-common-prd-ger-01"; SqlServer = "sql-splg-logsp-prd-ger-01" },
    @{ ResourceGroup = "rg-splg-logsp-common-uat-ger-01"; SqlServer = "sql-splg-logsp-uat-ger-01" },
    @{ ResourceGroup = "rg-splg-logsp-common-dev-ger-01"; SqlServer = "sql-splg-logsp-dev-ger-01" }
)

Set-AzContext -SubscriptionId $subscriptionId | Out-Null

foreach ($rgwithsqlsrv in $rgwithsqlsrvs) {
     $rgName = $rgwithsqlsrv.ResourceGroup
     $sqlServerName = $rgwithsqlsrv.SqlServer
     
     Write-Host "   🔍 Checking resource group: $rgName and SQL Server: $sqlServerName" -ForegroundColor Gray
     
     try {
         # Get the specified SQL server
         $sqlServer = Get-AzSqlServer -ResourceGroupName $rgName -ServerName $sqlServerName -ErrorAction SilentlyContinue
         
         if ($sqlServer) {
             Write-Host "      🖥️ Found SQL Server: $($sqlServer.ServerName)" -ForegroundColor DarkGray
             
             # Get all elastic pools for this server
             $elasticPools = Get-AzSqlElasticPool -ResourceGroupName $rgName -ServerName $sqlServer.ServerName -ErrorAction SilentlyContinue
             
             foreach ($pool in $elasticPools) 
             {
                 $totalPools++
                    Write-Host "         💎 Found Elastic Pool: $($pool.ElasticPoolName)" -ForegroundColor Green
                    
                    try {
                        # Get utilization metrics for the pool (last 14 days)
                        $endTime = Get-Date
                        $startTime = $endTime.AddDays(-14)
                        
                        # Try different metric names based on pool edition
                        # Ref: https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-sql-servers-elasticpools-metrics
                        $metricName = if ($pool.Edition -eq "Basic" -or $pool.Edition -eq "Standard" -or $pool.Edition -eq "Premium") {
                            "dtu_consumption_percent"
                        } else {
                            "sql_instance_cpu_percent"  # SQL instance CPU (all user + system workloads) for vCore-based pools
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
                                $SqlUtilization = ($validData | Measure-Object -Property Average -Maximum).Maximum
                            }
                        }

                        # Get storage used metric (returns bytes)
                        $storageUsedGB = "N/A"
                        $storageMetrics = Get-AzMetric -ResourceId $pool.ResourceId `
                            -MetricName "storage_used" `
                            -StartTime $endTime.AddHours(-1) `
                            -EndTime $endTime `
                            -AggregationType Average `
                            -ErrorAction SilentlyContinue
                        if ($storageMetrics.Data -and $storageMetrics.Data.Count -gt 0) {
                            $validStorageData = $storageMetrics.Data | Where-Object { $_.Average -ne $null } | Select-Object -Last 1
                            if ($validStorageData) {
                                $storageUsedGB = [math]::Round($validStorageData.Average / 1GB, 2)
                            }
                        }
                        
                        $results += [PSCustomObject]@{
                            SubscriptionId     = $subscriptionId
                            ResourceGroup      = $rgName
                            ServerName         = $sqlServer.ServerName
                            PoolName          = $pool.ElasticPoolName
                            Edition           = $pool.Edition
                            DTU               = $pool.Dtu
                            vCores            = $pool.VCore
                            StorageAllocated  = [math]::Round($pool.StorageMB / 1024, 2)
                            StorageUsed     = $storageUsedGB
                            SqlUtilization    = [math]::Round($SqlUtilization, 2)
                            State             = $pool.State
                            MetricType        = $metricName
                        }
                    }
                    catch {
                        Write-Warning "         ⚠️ Error retrieving metrics for pool $($pool.ElasticPoolName): $($_.Exception.Message)"
                        
                        # Still add the pool info even without metrics
                        $results += [PSCustomObject]@{
                            SubscriptionId     = $subscriptionId
                            ResourceGroup      = $rgName
                            ServerName         = $sqlServer.ServerName
                            PoolName          = $pool.ElasticPoolName
                            Edition           = $pool.Edition
                            DTU               = $pool.Dtu
                            vCores            = $pool.VCore
                            StorageAllocated = [math]::Round($pool.StorageMB / 1024, 2)
                            StorageUsed     = "N/A"
                            SqlUtilization    = "N/A"
                            State             = $pool.State
                            MetricType        = "Error retrieving metrics"
                        }
                    }
                }
            }
        }
    catch {
        Write-Verbose "Error processing SQL Server $sqlServerName in resource group ${rgName}: $($_.Exception.Message)"
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
    $poolsWithMetrics = $results | Where-Object { $_.SqlUtilization -ne "N/A" -and $_.SqlUtilization -gt 0 }
    
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
        $underutilized = $poolsWithMetrics | Where-Object { $_.SqlUtilization -lt 30 }
        if ($underutilized) {
            Write-Host "`n⚠️ UNDERUTILIZED POOLS (< 30% avg utilization):" -ForegroundColor Yellow
            $underutilized | Select-Object PoolName, ServerName, ResourceGroup, SqlUtilization | Format-Table
        }
        
        # Identify highly utilized pools (more than 80% average)
        $highlyUtilized = $poolsWithMetrics | Where-Object { $_.SqlUtilization -gt 80 }
        if ($highlyUtilized) {
            Write-Host "`n🔥 HIGHLY UTILIZED POOLS (> 80% avg utilization):" -ForegroundColor Red
            $highlyUtilized | Select-Object PoolName, ServerName, ResourceGroup, SqlUtilization | Format-Table
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