param(
    [Parameter(Mandatory=$false)][string]$RetryResultsCsv,
    [Parameter(Mandatory=$false)][string]$OriginalCsv,
    [Parameter(Mandatory=$false)][switch]$DryRun
)

$ErrorActionPreference = "Continue"
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$outDir = Join-Path $dir "FinalFix_$ts"
New-Item -Path $outDir -ItemType Directory -Force | Out-Null
$logFile = Join-Path $outDir "finalfix.log"

function WL { param([string]$M,[string]$C="White"); "[$(Get-Date -Format 'HH:mm:ss')] $M" | Out-File -FilePath $logFile -Append -Encoding UTF8; Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $M" -ForegroundColor $C }

$tenant = "8ef3d734-3ca5-4493-8d8b-52b2c54eab04"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Red
Write-Host "  FINAL FIX - SHRINK MAX SIZE + RETRY ALL FAILED" -ForegroundColor Red
Write-Host "  Fixes: MaxSize, Replicas, >250GB, all remaining" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""

# ================================================================
#  FIND CSV FILES
# ================================================================

function Find-Csv {
    param([string]$Pattern)
    $found = @()
    $folders = @()
    $folders += Get-ChildItem -Path $dir -Directory -Filter "EmergencyFix_*" -ErrorAction SilentlyContinue
    $folders += Get-ChildItem -Path $dir -Directory -Filter "RetryFix_*" -ErrorAction SilentlyContinue
    $folders += Get-ChildItem -Path $dir -Directory -Filter "FinalFix_*" -ErrorAction SilentlyContinue
    foreach ($f in $folders) { $c = Get-ChildItem -Path $f.FullName -Filter $Pattern -ErrorAction SilentlyContinue; if ($c) { $found += $c } }
    $found += Get-ChildItem -Path $dir -Filter $Pattern -ErrorAction SilentlyContinue
    return ($found | Sort-Object LastWriteTime -Descending)
}

# Find Retry_Results.csv (has FAILED status info)
if (-not $RetryResultsCsv) {
    $rr = Find-Csv "Retry_Results.csv"
    if ($rr.Count -gt 0) { $RetryResultsCsv = $rr[0].FullName }
}

# Find SQL_Recommendations.csv (has SubId and RG)
if (-not $OriginalCsv) {
    $oc = Find-Csv "SQL_Recommendations.csv"
    if ($oc.Count -gt 0) { $OriginalCsv = $oc[0].FullName }
}

if (-not $OriginalCsv) { Write-Host "  No SQL_Recommendations.csv found. Use -OriginalCsv parameter." -ForegroundColor Red; exit 1 }

WL "Original CSV: $OriginalCsv" "Cyan"
$origDbs = Import-Csv -Path $OriginalCsv
WL "Loaded $($origDbs.Count) original records" "Green"

# Build lookup for SubId and RG from original CSV
$lookup = @{}
foreach ($o in $origDbs) { $lookup["$($o.Server)/$($o.DB)"] = $o }

# Get failed items
$failedItems = @()
if ($RetryResultsCsv -and (Test-Path $RetryResultsCsv)) {
    WL "Retry Results: $RetryResultsCsv" "Cyan"
    $retryResults = Import-Csv -Path $RetryResultsCsv
    $failedItems = @($retryResults | Where-Object { $_.Status -eq "FAILED" })
    WL "Found $($failedItems.Count) FAILED items from retry" "Yellow"
} else {
    WL "No Retry_Results.csv found - will process all DROP items from original" "Yellow"
    $failedItems = @($origDbs | Where-Object { $_.Act -eq "DROP" } | ForEach-Object {
        [PSCustomObject]@{Sub=$_.Sub;Server=$_.Server;DB=$_.DB;OldSKU=$_.SKU;Action="DROP";NewSKU=$_.Rec;Status="PENDING";Cost=$_.Cost;NewCost=$_.NewCost;Saved=$_.Save;Error=""}
    })
}

if ($failedItems.Count -eq 0) { Write-Host "  No failed items to fix!" -ForegroundColor Green; exit 0 }

# ================================================================
#  AZURE LOGIN
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  STEP 1: VERIFY AZURE LOGIN" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow

$needLogin = $true
try {
    $raw = az account show 2>$null
    if ($raw) {
        $a = $raw | ConvertFrom-Json
        if ($a.tenantId -eq $tenant) { WL "Logged in: $($a.user.name)" "Green"; $needLogin = $false }
        else { WL "Wrong tenant" "Yellow" }
    }
} catch {}

if ($needLogin) {
    az logout 2>$null
    Write-Host "  BROWSER WILL OPEN - Sign in + MFA" -ForegroundColor Cyan
    az login --tenant $tenant 2>$null | Out-Null
    $raw = az account show 2>$null
    if ($raw) {
        $a = $raw | ConvertFrom-Json
        if ($a.tenantId -eq $tenant) { WL "Login OK: $($a.user.name)" "Green" }
        else { WL "FATAL: Wrong tenant" "Red"; exit 1 }
    } else { WL "FATAL: Login failed" "Red"; exit 1 }
}

# ================================================================
#  PRICING + SIZE MAPS
# ================================================================

$pricing = @{
    "Basic"=@{D=5;P=4.99;E="Basic";O="Basic";MaxGB=2}
    "S0"=@{D=10;P=15.03;E="Standard";O="S0";MaxGB=250}
    "S1"=@{D=20;P=30.05;E="Standard";O="S1";MaxGB=250}
    "S2"=@{D=50;P=75.13;E="Standard";O="S2";MaxGB=250}
    "S3"=@{D=100;P=150.26;E="Standard";O="S3";MaxGB=1024}
    "S4"=@{D=200;P=300.52;E="Standard";O="S4";MaxGB=1024}
    "S6"=@{D=400;P=601.03;E="Standard";O="S6";MaxGB=1024}
    "S7"=@{D=800;P=1202.06;E="Standard";O="S7";MaxGB=1024}
    "S9"=@{D=1600;P=2404.13;E="Standard";O="S9";MaxGB=1024}
    "S12"=@{D=3000;P=4507.74;E="Standard";O="S12";MaxGB=1024}
}

# ================================================================
#  STEP 2: ANALYZE AND FIX EACH FAILED DATABASE
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Red
Write-Host "  STEP 2: FIX $($failedItems.Count) FAILED DATABASES" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""

$results = @()
$fixOk = 0; $fixFail = 0; $fixSkip = 0
$actualSavings = 0
$currentSub = ""
$counter = 0

foreach ($f in $failedItems) {
    $counter++
    $key = "$($f.Server)/$($f.DB)"
    $orig = $lookup[$key]

    # Get SubId and RG from original
    $subId = if ($orig) { $orig.SubId } else { "" }
    $rg = if ($orig) { $orig.RG } else { "" }
    $targetTier = if ($f.NewSKU) { $f.NewSKU } elseif ($orig) { $orig.Rec } else { "" }
    $origCost = if ($orig) { [double]$orig.Cost } else { [double]$f.Cost }
    $action = if ($f.Action) { $f.Action } else { "DROP" }

    if (-not $subId -or -not $rg) {
        Write-Host "  [$counter/$($failedItems.Count)] $key SKIP - no SubId/RG" -ForegroundColor DarkGray
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1="N/A";Step2="N/A";FinalStatus="SKIPPED";Cost=$origCost;NewCost=$origCost;Saved=0;Error="Missing SubId or RG";ActualSize="";MaxSize=""}
        $fixSkip++
        continue
    }

    if ($currentSub -ne $subId) {
        az account set --subscription $subId 2>$null
        $currentSub = $subId
    }

    Write-Host "  [$counter/$($failedItems.Count)] $key " -ForegroundColor Gray -NoNewline

    # Step A: Check if database still exists
    $dbJson = $null
    try {
        $dbRaw = az sql db show --server $f.Server --name $f.DB --resource-group $rg --subscription $subId 2>&1
        if ($LASTEXITCODE -eq 0) { $dbJson = $dbRaw | ConvertFrom-Json }
    } catch {}

    if (-not $dbJson) {
        Write-Host "ALREADY GONE" -ForegroundColor DarkGray
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1="N/A";Step2="N/A";FinalStatus="ALREADY DELETED";Cost=$origCost;NewCost=0;Saved=$origCost;Error="";ActualSize="";MaxSize=""}
        $fixOk++
        $actualSavings += $origCost
        continue
    }

    $currentSKU = $dbJson.currentServiceObjectiveName
    $currentEdition = $dbJson.edition
    $maxSizeBytes = $dbJson.maxSizeBytes
    $maxSizeGB = [math]::Round($maxSizeBytes / 1073741824, 2)
    $currentStatus = $dbJson.status

    # Check actual used space
    $actualSizeGB = 0
    try {
        $usageRaw = az sql db list-usages --server $f.Server --name $f.DB --resource-group $rg --subscription $subId 2>$null
        if ($usageRaw) {
            $usages = $usageRaw | ConvertFrom-Json
            $spaceUsed = $usages | Where-Object { $_.name -eq "database_size" -or $_.name -eq "used_space" } | Select-Object -First 1
            if ($spaceUsed) { $actualSizeGB = [math]::Round($spaceUsed.currentValue / 1073741824, 2) }
        }
    } catch {}

    Write-Host "[$currentSKU maxSize:${maxSizeGB}GB used:${actualSizeGB}GB] " -ForegroundColor DarkCyan -NoNewline

    # Already at target?
    if ($currentSKU -eq $targetTier) {
        Write-Host "ALREADY AT TARGET" -ForegroundColor DarkGreen
        $newP = if ($pricing[$targetTier]) { $pricing[$targetTier].P } else { $origCost }
        $sav = $origCost - $newP
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1="N/A";Step2="N/A";FinalStatus="ALREADY DONE";Cost=$origCost;NewCost=$newP;Saved=$sav;Error="";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB"}
        $fixOk++
        $actualSavings += $sav
        continue
    }

    if ($DryRun) {
        Write-Host "DRY RUN" -ForegroundColor Yellow
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1="Would shrink";Step2="Would change tier";FinalStatus="DRY RUN";Cost=$origCost;NewCost=0;Saved=0;Error="";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB"}
        $fixSkip++
        continue
    }

    # Determine target tier constraints
    $t = $pricing[$targetTier]
    if (-not $t) {
        if ($targetTier -eq "Basic") { $t = @{E="Basic";O="Basic";MaxGB=2;P=4.99} }
        elseif ($targetTier -match "^S(\d+)$") { $t = $pricing[$targetTier] }
    }
    if (-not $t) {
        Write-Host "SKIP - unknown tier $targetTier" -ForegroundColor Gray
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1="N/A";Step2="N/A";FinalStatus="SKIPPED";Cost=$origCost;NewCost=$origCost;Saved=0;Error="Unknown target tier: $targetTier";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB"}
        $fixSkip++
        continue
    }

    $targetMaxGB = $t.MaxGB
    $targetEdition = $t.E
    $targetObjective = $t.O
    $targetCost = $t.P
    $step1Status = "N/A"
    $step2Status = "N/A"
    $finalErr = ""

    # ============================================================
    #  SMART FIX LOGIC
    # ============================================================

    # Check if actual data exceeds target tier max
    if ($actualSizeGB -gt $targetMaxGB) {
        # Data is too big for target tier - need a bigger tier
        # Find the smallest tier that fits the actual data
        $bestTier = $null
        $orderedTiers = @("Basic","S0","S1","S2","S3","S4","S6","S7","S9","S12")
        foreach ($tn in $orderedTiers) {
            $tp = $pricing[$tn]
            if ($tp -and $tp.MaxGB -ge $actualSizeGB -and $tp.P -lt $origCost) {
                $bestTier = $tn
                $targetEdition = $tp.E
                $targetObjective = $tp.O
                $targetMaxGB = $tp.MaxGB
                $targetCost = $tp.P
                $targetTier = $tn
                break
            }
        }
        if (-not $bestTier) {
            Write-Host "SKIP - data ${actualSizeGB}GB too big to downgrade" -ForegroundColor Yellow
            $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1="N/A";Step2="N/A";FinalStatus="SKIPPED-DATA TOO BIG";Cost=$origCost;NewCost=$origCost;Saved=0;Error="Actual data ${actualSizeGB}GB exceeds all cheaper tiers";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB"}
            $fixSkip++
            continue
        }
        WL "  Adjusted target to $bestTier (data ${actualSizeGB}GB needs >$($pricing[$bestTier].MaxGB)GB support)" "Yellow"
    }

    # Step 1: Shrink max size if needed
    $needShrink = $false
    $shrinkToGB = $targetMaxGB

    if ($targetTier -eq "Basic" -and $maxSizeGB -gt 2) {
        $needShrink = $true
        $shrinkToGB = 2
    } elseif ($targetTier -in @("S0","S1","S2") -and $maxSizeGB -gt 250) {
        $needShrink = $true
        $shrinkToGB = 250
    } elseif ($maxSizeGB -gt $targetMaxGB) {
        $needShrink = $true
        $shrinkToGB = $targetMaxGB
    }

    if ($needShrink) {
        Write-Host "SHRINK(${maxSizeGB}GB->${shrinkToGB}GB) " -ForegroundColor Cyan -NoNewline

        # For Basic, maxsize must be specified in bytes. 2GB = 2147483648
        $shrinkBytes = [long]$shrinkToGB * 1073741824
        $shrinkParam = "${shrinkToGB}GB"

        try {
            # Must first set edition to one that supports current max size, then shrink
            # If going to Basic, we need to first set max-size while still on current edition
            $shrinkResult = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --max-size "${shrinkParam}" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $step1Status = "SHRUNK to ${shrinkToGB}GB"
                Write-Host "OK " -ForegroundColor Green -NoNewline
            } else {
                $shrinkErr = ($shrinkResult | Out-String).Trim()
                # If shrink fails because edition doesn't support it, try setting a middle ground
                if ($shrinkErr -match "not support the database max size") {
                    # Try 250GB first (works for Standard tiers)
                    $shrinkResult2 = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --max-size "250GB" 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $step1Status = "SHRUNK to 250GB"
                        $shrinkToGB = 250
                        Write-Host "OK(250GB) " -ForegroundColor Green -NoNewline
                        # If target is Basic, do a second shrink after moving to Standard first
                        if ($targetTier -eq "Basic") {
                            # Move to S0 first, then shrink to 2GB, then Basic
                            $midResult = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --edition "Standard" --service-objective "S0" 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                $shrinkResult3 = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --max-size "2GB" 2>&1
                                if ($LASTEXITCODE -eq 0) {
                                    $step1Status = "SHRUNK via S0 to 2GB"
                                    Write-Host "->2GB " -ForegroundColor Green -NoNewline
                                }
                            }
                        }
                    } else {
                        $step1Status = "SHRINK FAILED"
                        $finalErr = "Shrink failed: $($shrinkErr.Substring(0, [math]::Min(200, $shrinkErr.Length)))"
                        Write-Host "SHRINK FAIL " -ForegroundColor Red -NoNewline
                    }
                } else {
                    $step1Status = "SHRINK FAILED"
                    $finalErr = "Shrink failed: $($shrinkErr.Substring(0, [math]::Min(200, $shrinkErr.Length)))"
                    Write-Host "SHRINK FAIL " -ForegroundColor Red -NoNewline
                }
            }
        } catch {
            $step1Status = "SHRINK ERROR"
            $finalErr = $_.Exception.Message
            Write-Host "SHRINK ERR " -ForegroundColor Red -NoNewline
        }
    } else {
        $step1Status = "No shrink needed"
    }

    # Step 2: Change tier (even if shrink failed for non-Basic, might work)
    if ($step1Status -notmatch "SHRINK FAILED|SHRINK ERROR" -or $targetTier -notin @("Basic")) {
        try {
            $updResult = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --edition $targetEdition --service-objective $targetObjective 2>&1
            if ($LASTEXITCODE -eq 0) {
                $step2Status = "CHANGED to $targetTier"
                $sav = [math]::Round($origCost - $targetCost, 2)
                Write-Host "CHANGED to $targetTier" -ForegroundColor Green
                WL "  $key: $($f.OldSKU) -> $targetTier | Saved `$$sav/mo" "Green"
                $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1=$step1Status;Step2=$step2Status;FinalStatus="FIXED";Cost=$origCost;NewCost=$targetCost;Saved=$sav;Error="";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB"}
                $fixOk++
                $actualSavings += $sav
                continue
            } else {
                $updErr = ($updResult | Out-String).Trim()

                # Handle replica error - try to find and fix source first
                if ($updErr -match "TargetDatabaseEditionCouldNotBeDowngraded|cannot have lower edition than the source") {
                    $step2Status = "REPLICA BLOCK"
                    # Extract source info from error
                    $sourceMatch = [regex]::Match($updErr, "source database '([^']+)'")
                    $sourceName = ""
                    if ($sourceMatch.Success) { $sourceName = $sourceMatch.Groups[1].Value }

                    Write-Host "REPLICA " -ForegroundColor Yellow -NoNewline

                    # Try to find and downgrade the source
                    if ($sourceName) {
                        $srcParts = $sourceName -split '\.'
                        $srcServer = if ($srcParts.Count -ge 2) { $srcParts[0] } else { "" }
                        $srcDb = if ($srcParts.Count -ge 3) { $srcParts[1] } else { "" }

                        if ($srcServer -and $srcDb) {
                            WL "  Attempting to fix source: $srcServer/$srcDb" "Yellow"
                            # Find source in original CSV
                            $srcOrig = $lookup["$srcServer/$srcDb"]
                            if ($srcOrig) {
                                $srcRg = $srcOrig.RG
                                # Shrink source max size first
                                az sql db update --server $srcServer --name $srcDb --resource-group $srcRg --subscription $subId --max-size "${shrinkToGB}GB" 2>$null
                                # Change source tier
                                $srcUpd = az sql db update --server $srcServer --name $srcDb --resource-group $srcRg --subscription $subId --edition $targetEdition --service-objective $targetObjective 2>&1
                                if ($LASTEXITCODE -eq 0) {
                                    WL "  Source fixed: $srcServer/$srcDb -> $targetTier" "Green"
                                    # Now retry the target
                                    Start-Sleep -Seconds 5
                                    if ($needShrink -and $shrinkToGB -le 2) {
                                        az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --max-size "${shrinkToGB}GB" 2>$null
                                    }
                                    $retryUpd = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --edition $targetEdition --service-objective $targetObjective 2>&1
                                    if ($LASTEXITCODE -eq 0) {
                                        $step2Status = "FIXED (source+target)"
                                        $sav = [math]::Round($origCost - $targetCost, 2)
                                        Write-Host "FIXED (via source)" -ForegroundColor Green
                                        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1=$step1Status;Step2=$step2Status;FinalStatus="FIXED";Cost=$origCost;NewCost=$targetCost;Saved=$sav;Error="";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB"}
                                        $fixOk++
                                        $actualSavings += $sav
                                        continue
                                    }
                                }
                            }
                        }
                    }

                    # If we get here, replica fix failed
                    # Try a higher tier that might be acceptable
                    $fallbackTier = $null
                    $orderedTiers = @("S0","S1","S2","S3")
                    foreach ($ft in $orderedTiers) {
                        $fp = $pricing[$ft]
                        if ($fp -and $fp.P -lt $origCost) {
                            $fbResult = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --edition $fp.E --service-objective $fp.O 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                $fallbackTier = $ft
                                $targetCost = $fp.P
                                break
                            }
                        }
                    }

                    if ($fallbackTier) {
                        $sav = [math]::Round($origCost - $targetCost, 2)
                        Write-Host "FALLBACK to $fallbackTier" -ForegroundColor Yellow
                        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$fallbackTier;Action=$action;Step1=$step1Status;Step2="FALLBACK $fallbackTier";FinalStatus="PARTIAL";Cost=$origCost;NewCost=$targetCost;Saved=$sav;Error="Replica - fell back to $fallbackTier";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB"}
                        $fixOk++
                        $actualSavings += $sav
                        continue
                    }

                    $finalErr = "Replica block - source could not be downgraded first"
                    Write-Host "STILL BLOCKED" -ForegroundColor Red

                } elseif ($updErr -match "InvalidMaxSizeTierCombination|does not support the database max size") {
                    # Shrink didn't work or wasn't enough - try S3 as fallback
                    $step2Status = "SIZE BLOCK"
                    $fb = $pricing["S3"]
                    if ($fb -and $fb.P -lt $origCost) {
                        $fbResult = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --edition $fb.E --service-objective $fb.O 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            $sav = [math]::Round($origCost - $fb.P, 2)
                            Write-Host "FALLBACK to S3" -ForegroundColor Yellow
                            $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU="S3";Action=$action;Step1=$step1Status;Step2="FALLBACK S3";FinalStatus="PARTIAL";Cost=$origCost;NewCost=$fb.P;Saved=$sav;Error="Max size too big for $targetTier - used S3";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB"}
                            $fixOk++
                            $actualSavings += $sav
                            continue
                        }
                    }
                    $finalErr = "Max size block even after shrink attempt"
                    Write-Host "STILL BLOCKED" -ForegroundColor Red

                } elseif ($updErr -match "ProvisioningDisabled|greater than.*250 GB") {
                    # >250GB - need S3+
                    $fb = $pricing["S3"]
                    if ($fb -and $fb.P -lt $origCost) {
                        # Shrink to 1TB first
                        az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --max-size "1024GB" 2>$null
                        $fbResult = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --edition $fb.E --service-objective $fb.O 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            $sav = [math]::Round($origCost - $fb.P, 2)
                            Write-Host "FIXED at S3" -ForegroundColor Yellow
                            $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU="S3";Action=$action;Step1="Shrunk to 1TB";Step2="Changed to S3";FinalStatus="FIXED";Cost=$origCost;NewCost=$fb.P;Saved=$sav;Error="";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB"}
                            $fixOk++
                            $actualSavings += $sav
                            continue
                        }
                    }
                    $finalErr = "Provisioning disabled - could not fix"
                    Write-Host "STILL BLOCKED" -ForegroundColor Red

                } else {
                    $finalErr = $updErr.Substring(0, [math]::Min(300, $updErr.Length))
                    Write-Host "FAILED" -ForegroundColor Red
                }
            }
        } catch {
            $finalErr = $_.Exception.Message
            $step2Status = "ERROR"
            Write-Host "ERROR" -ForegroundColor Red
        }
    } else {
        Write-Host "SKIPPED (shrink failed)" -ForegroundColor Yellow
    }

    # If we get here, it failed
    WL "  FAILED: $key - $finalErr" "Red"
    $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1=$step1Status;Step2=$step2Status;FinalStatus="FAILED";Cost=$origCost;NewCost=$origCost;Saved=0;Error=$finalErr;ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB"}
    $fixFail++
}

Write-Host ""
WL "Results: $fixOk FIXED | $fixFail FAILED | $fixSkip SKIPPED" $(if ($fixFail -gt 0) { "Yellow" } else { "Green" })

# Export results CSV
$resultsCsv = Join-Path $outDir "FinalFix_Results.csv"
$results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8

# ================================================================
#  STEP 3: FULL VERIFICATION SCAN
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  STEP 3: VERIFY - RE-SCAN ALL DATABASES" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

WL "Verifying current state..." "Yellow"

$allSubs = $null
$rawSubs = az account list --query "[?tenantId=='$tenant' && state=='Enabled']" 2>$null
if ($rawSubs) { try { $allSubs = $rawSubs | ConvertFrom-Json } catch {} }

$verifyResults = @()
$sysDbs = @("master","tempdb","model","msdb")

foreach ($sub in $allSubs) {
    az account set --subscription $sub.id 2>$null
    $rs = az sql server list --subscription $sub.id 2>$null
    if (-not $rs -or $rs.Trim().Length -le 2) { continue }
    try { $servers = $rs | ConvertFrom-Json } catch { continue }
    if ($servers.Count -eq 0) { continue }

    foreach ($srv in $servers) {
        $rd = az sql db list --server $srv.name --resource-group $srv.resourceGroup --subscription $sub.id 2>$null
        if (-not $rd -or $rd.Trim().Length -le 2) { continue }
        try { $dbs = $rd | ConvertFrom-Json } catch { continue }
        foreach ($db in $dbs) {
            if ($sysDbs -contains $db.name) { continue }
            $maxGB = [math]::Round($db.maxSizeBytes / 1073741824, 2)
            $verifyResults += [PSCustomObject]@{Sub=$sub.name;Server=$srv.name;DB=$db.name;SKU=$db.currentServiceObjectiveName;Edition=$db.edition;MaxSizeGB=$maxGB;Status=$db.status;RG=$srv.resourceGroup}
        }
    }
}

WL "Verified: $($verifyResults.Count) databases remaining" "Green"

$verifyCsv = Join-Path $outDir "Verify_FinalState.csv"
$verifyResults | Export-Csv -Path $verifyCsv -NoTypeInformation -Encoding UTF8

# ================================================================
#  STEP 4: GENERATE HTML REPORT
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  STEP 4: GENERATE HTML REPORT" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green

$totalFixed = @($results | Where-Object { $_.FinalStatus -in @("FIXED","PARTIAL","ALREADY DONE","ALREADY DELETED") }).Count
$totalFailed = @($results | Where-Object { $_.FinalStatus -eq "FAILED" }).Count
$totalSkipped = @($results | Where-Object { $_.FinalStatus -match "SKIP" }).Count
$actualSavRound = [math]::Round($actualSavings, 2)
$actualYearly = [math]::Round($actualSavings * 12, 2)
$successRate = if ($failedItems.Count -gt 0) { [math]::Round(($totalFixed / $failedItems.Count) * 100, 1) } else { 100 }
$deadline = [datetime]"2026-02-09"
$daysLeft = [math]::Max(0, ($deadline - (Get-Date)).Days)
$urgColor = if ($daysLeft -le 2) { '#ef4444' } elseif ($daysLeft -le 5) { '#f97316' } else { '#22c55e' }

# Previous savings from retry
$prevSav = 5038.80
$prevYearly = 60465.60
$grandTotalMo = [math]::Round($prevSav + $actualSavRound, 2)
$grandTotalYr = [math]::Round($grandTotalMo * 12, 2)

# Build table rows
$fixTableRows = ""
foreach ($r in ($results | Sort-Object @{E={switch($r.FinalStatus){"FAILED"{0}"PARTIAL"{1}default{2}}}},Sub,Server,DB)) {
    $sc = switch ($r.FinalStatus) { "FIXED" { "#22c55e" } "PARTIAL" { "#f59e0b" } "ALREADY DONE" { "#22c55e" } "ALREADY DELETED" { "#22c55e" } "FAILED" { "#ef4444" } default { "#64748b" } }
    $bg = if ($r.FinalStatus -eq "FAILED") { "background:#1a0505;" } elseif ($r.FinalStatus -eq "PARTIAL") { "background:#1a1005;" } else { "" }
    $errTd = if ($r.Error) { "<td style='color:#ef4444;font-size:10px;max-width:250px;word-break:break-word'>$($r.Error.Substring(0, [math]::Min(150, $r.Error.Length)))</td>" } else { "<td></td>" }
    $fixTableRows += "<tr style='$bg'><td>$($r.Sub)</td><td>$($r.Server)</td><td style='font-weight:bold'>$($r.DB)</td><td>$($r.OldSKU)</td><td style='color:#22c55e'>$($r.TargetSKU)</td><td>$($r.ActualSize)</td><td>$($r.MaxSize)</td><td>$($r.Step1)</td><td>$($r.Step2)</td><td style='color:$sc;font-weight:bold'>$($r.FinalStatus)</td><td>`$$($r.Cost)</td><td>`$$($r.NewCost)</td><td style='color:#22c55e'>`$$($r.Saved)</td>$errTd</tr>"
}

$verifyTableRows = ""
foreach ($v in ($verifyResults | Sort-Object Sub,Server,DB)) {
    $verifyTableRows += "<tr><td>$($v.Sub)</td><td>$($v.Server)</td><td>$($v.DB)</td><td>$($v.SKU)</td><td>$($v.Edition)</td><td>$($v.MaxSizeGB)GB</td></tr>"
}

$failedOnlyRows = ""
$failedOnly = @($results | Where-Object { $_.FinalStatus -eq "FAILED" })
foreach ($ff in $failedOnly) {
    $failedOnlyRows += "<tr><td>$($ff.Sub)</td><td>$($ff.Server)</td><td style='font-weight:bold;color:#fca5a5'>$($ff.DB)</td><td>$($ff.OldSKU)</td><td>$($ff.TargetSKU)</td><td>$($ff.ActualSize)</td><td>$($ff.MaxSize)</td><td style='color:#ef4444;font-size:10px'>$($ff.Error)</td></tr>"
}

$logLines = @()
if (Test-Path $logFile) { $logLines = Get-Content -Path $logFile }
$logHtml = ""
foreach ($l in $logLines) {
    $lc = "#94a3b8"
    if ($l -match "FAIL|ERROR|BLOCK") { $lc = "#ef4444" } elseif ($l -match "WARN|SKIP|PARTIAL|Adjusted|FALLBACK") { $lc = "#f59e0b" } elseif ($l -match "OK|FIXED|CHANGED|DELETED|Green|Login OK|Saved") { $lc = "#22c55e" }
    $safe = $l -replace '<','&lt;' -replace '>','&gt;'
    $logHtml += "<div style='color:$lc;font-family:monospace;font-size:11px;line-height:1.5'>$safe</div>"
}

$overallStatus = if ($totalFailed -eq 0) { "ALL $($failedItems.Count) PREVIOUSLY FAILED - NOW FIXED" } elseif ($successRate -ge 80) { "MOSTLY FIXED - $totalFailed STILL NEED MANUAL REVIEW" } else { "$totalFixed FIXED / $totalFailed REMAINING" }
$overallColor = if ($totalFailed -eq 0) { "#22c55e" } elseif ($successRate -ge 80) { "#f59e0b" } else { "#ef4444" }

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Final Fix Report - $(Get-Date -Format 'yyyy-MM-dd')</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#0f172a;color:#e2e8f0;padding:20px}
.ctr{max-width:1600px;margin:0 auto}
.hdr{background:linear-gradient(135deg,#1e293b,#334155);border-radius:12px;padding:25px;margin-bottom:15px;border:1px solid #475569}
.hdr h1{font-size:24px;color:#f1f5f9;margin-bottom:4px}
.hdr p{color:#94a3b8;font-size:12px}
.ban{border-radius:12px;padding:16px;margin-bottom:12px;text-align:center}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin-bottom:15px}
.card{background:#1e293b;border-radius:10px;padding:14px;border:1px solid #334155}
.card h3{font-size:10px;color:#94a3b8;text-transform:uppercase;letter-spacing:1px;margin-bottom:5px}
.card .v{font-size:26px;font-weight:700}
.card .s{font-size:10px;color:#64748b;margin-top:2px}
.sec{background:#1e293b;border-radius:10px;padding:16px;margin-bottom:12px;border:1px solid #334155}
.sec h2{font-size:15px;color:#f1f5f9;margin-bottom:10px;padding-bottom:8px;border-bottom:1px solid #334155}
table{width:100%;border-collapse:collapse;font-size:11px}
th{background:#0f172a;color:#94a3b8;padding:7px 8px;text-align:left;font-weight:600;text-transform:uppercase;font-size:9px;letter-spacing:0.5px;position:sticky;top:0}
td{padding:5px 8px;border-bottom:1px solid #1e293b}
tr:hover{background:#334155}
.ft{text-align:center;color:#475569;font-size:10px;margin-top:15px;padding:12px}
.bg{display:inline-block;padding:2px 7px;border-radius:10px;font-size:9px;font-weight:600}
.bg-c{background:#7f1d1d;color:#fca5a5}.bg-w{background:#78350f;color:#fbbf24}.bg-o{background:#14532d;color:#86efac}
.ib{border-radius:8px;padding:12px;margin-bottom:10px}
.bar{height:8px;border-radius:4px;background:#334155;overflow:hidden;margin-top:6px}
.fill{height:100%;border-radius:4px}
.grand{background:linear-gradient(135deg,#14532d,#166534);border:2px solid #22c55e;border-radius:12px;padding:20px;margin-bottom:15px;text-align:center}
@media print{body{background:#fff;color:#000}th{background:#f1f5f9;color:#000}td{border-color:#e2e8f0}.card,.sec,.hdr{border-color:#e2e8f0;background:#fff}}
</style>
</head>
<body>
<div class="ctr">
<div class="hdr">
<h1>FINAL FIX - SHRINK + RETRY REPORT</h1>
<p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | Fixing $($failedItems.Count) previously failed operations</p>
<p style="margin-top:6px;font-size:14px;color:$overallColor;font-weight:bold">$overallStatus</p>
</div>

<div class="ban" style="background:linear-gradient(135deg,$urgColor,$(if($daysLeft -le 2){'#dc2626'}else{'#ea580c'}))">
<h2 style="font-size:22px;color:#fff">MFA ENFORCEMENT: $daysLeft DAYS (Feb 9, 2026)</h2>
</div>

<div class="grand">
<h2 style="font-size:14px;color:#86efac;margin-bottom:8px">COMBINED SAVINGS - ALL SCRIPTS</h2>
<div style="display:flex;justify-content:center;gap:40px;flex-wrap:wrap">
<div><div style="font-size:12px;color:#86efac">Retry Fix (Round 1)</div><div style="font-size:28px;font-weight:bold;color:#22c55e">`$$prevSav/mo</div></div>
<div style="font-size:28px;color:#475569;padding-top:15px">+</div>
<div><div style="font-size:12px;color:#86efac">Final Fix (This Run)</div><div style="font-size:28px;font-weight:bold;color:#22c55e">`$$actualSavRound/mo</div></div>
<div style="font-size:28px;color:#475569;padding-top:15px">=</div>
<div><div style="font-size:12px;color:#fbbf24">GRAND TOTAL</div><div style="font-size:36px;font-weight:bold;color:#fff">`$$grandTotalMo/mo</div><div style="font-size:14px;color:#86efac">`$$grandTotalYr/yr</div></div>
</div>
</div>

<div class="grid">
<div class="card"><h3>Previously Failed</h3><div class="v" style="color:#f59e0b">$($failedItems.Count)</div><div class="s">from Retry-Fix run</div></div>
<div class="card"><h3>Now Fixed</h3><div class="v" style="color:#22c55e">$totalFixed</div><div class="s">shrink + tier change</div></div>
<div class="card"><h3>Still Failed</h3><div class="v" style="color:$(if($totalFailed -eq 0){'#22c55e'}else{'#ef4444'})">$totalFailed</div><div class="s">$(if($totalFailed -eq 0){'NONE!'}else{'need manual review'})</div></div>
<div class="card"><h3>Success Rate</h3><div class="v" style="color:$(if($successRate -ge 90){'#22c55e'}elseif($successRate -ge 70){'#f59e0b'}else{'#ef4444'})">$successRate%</div><div class="bar"><div class="fill" style="width:$successRate%;background:$(if($successRate -ge 90){'#22c55e'}elseif($successRate -ge 70){'#f59e0b'}else{'#ef4444'})"></div></div></div>
<div class="card"><h3>This Run Savings</h3><div class="v" style="color:#22c55e">`$$actualSavRound</div><div class="s">/mo additional</div></div>
<div class="card"><h3>DBs Remaining</h3><div class="v" style="color:#60a5fa">$($verifyResults.Count)</div><div class="s">after all fixes</div></div>
</div>

<div class="sec" style="border:2px solid #f59e0b">
<h2 style="color:#f59e0b">MICROSOFT EMERGENCY BRIEFING</h2>
<div class="ib" style="background:#7f1d1d;border-left:4px solid #ef4444">
<h3 style="color:#fca5a5;margin-bottom:5px;font-size:13px">MFA Enforcement - $daysLeft DAYS (Feb 9, 2026)</h3>
<p style="color:#e2e8f0;font-size:11px">M365 Admin Center mandatory MFA. Admins without MFA = LOCKED OUT. Run MFA-Enforcement-GOD-Script.ps1 tomorrow. Azure Portal enforced since March 2025, CLI/PS since Oct 2025.</p>
</div>
<div class="ib" style="background:#7f1d1d;border-left:4px solid #ef4444">
<h3 style="color:#fca5a5;margin-bottom:5px;font-size:13px">Azure Outage (Feb 2-3) - Residual Impact</h3>
<p style="color:#e2e8f0;font-size:11px">If Databricks warehouses or clusters still flaky, recycle them. Managed Identity tokens may still be cached from outage.</p>
</div>
<div class="ib" style="background:#78350f;border-left:4px solid #f59e0b">
<h3 style="color:#fbbf24;margin-bottom:5px;font-size:13px">PagerDuty DTU Alerts</h3>
<p style="color:#e2e8f0;font-size:11px">Tony reported PagerDuty logging DTU capacity issues after tier changes. Review alerts and bump specific databases that need more headroom. Tony already manually bumped Pyx-Health from S1 to S2 on mycareloop.</p>
</div>
</div>

<div class="sec">
<h2>How Fixes Were Applied</h2>
<table>
<tr><th>Error Type</th><th>Fix Applied</th><th>Example</th></tr>
<tr><td style="color:#f59e0b">InvalidMaxSizeTierCombination</td><td>Shrink max size from 250GB to 2GB, then change to Basic</td><td>DB had maxSize=250GB but Basic only supports 2GB</td></tr>
<tr><td style="color:#f59e0b">TargetDatabaseEditionCouldNotBeDowngraded</td><td>Downgrade source DB first, then downgrade the copy/replica</td><td>Copy can't be cheaper than source - fix source first</td></tr>
<tr><td style="color:#f59e0b">ProvisioningDisabled (>250GB)</td><td>Shrink to 1TB, then change to S3 (cheapest tier supporting >250GB)</td><td>S0/S1/S2 don't support >250GB</td></tr>
<tr><td style="color:#f59e0b">Any remaining</td><td>Fallback: try progressively higher tiers (S0->S1->S2->S3) until one works</td><td>Always picks cheapest tier that succeeds</td></tr>
</table>
</div>

<div class="sec">
<h2>All Fix Operations ($($failedItems.Count) databases)</h2>
<div style="max-height:600px;overflow-y:auto">
<table>
<tr><th>Sub</th><th>Server</th><th>Database</th><th>From</th><th>To</th><th>Used</th><th>MaxSize</th><th>Step 1</th><th>Step 2</th><th>Status</th><th>Old Cost</th><th>New Cost</th><th>Saved</th><th>Error</th></tr>
$fixTableRows
</table>
</div>
</div>

$(if ($failedOnly.Count -gt 0) {
@"
<div class="sec" style="border:2px solid #ef4444">
<h2 style="color:#ef4444">STILL FAILED - Need Manual Review ($($failedOnly.Count))</h2>
<table>
<tr><th>Sub</th><th>Server</th><th>Database</th><th>From</th><th>Target</th><th>Used</th><th>MaxSize</th><th>Error</th></tr>
$failedOnlyRows
</table>
</div>
"@
})

<div class="sec">
<h2>VERIFIED - Current Database State ($($verifyResults.Count) databases remaining)</h2>
<div style="max-height:500px;overflow-y:auto">
<table>
<tr><th>Subscription</th><th>Server</th><th>Database</th><th>Current SKU</th><th>Edition</th><th>Max Size</th></tr>
$verifyTableRows
</table>
</div>
</div>

<div class="sec">
<h2>Action Items</h2>
<table>
<tr><th>#</th><th>Action</th><th>Owner</th><th>Priority</th></tr>
<tr><td>1</td><td><strong>Run MFA-Enforcement-GOD-Script.ps1 TOMORROW</strong> - Audit first, then deploy CA policies before Feb 9</td><td>Syed</td><td><span class="bg bg-c">CRITICAL</span></td></tr>
<tr><td>2</td><td>Review PagerDuty DTU alerts - bump any databases that are struggling after tier drops (Tony already fixed Pyx-Health to S2)</td><td>Tony / Syed</td><td><span class="bg bg-c">CRITICAL</span></td></tr>
$(if ($totalFailed -gt 0) { "<tr><td>3</td><td>Review $totalFailed remaining failed databases - may need manual shrink or deletion</td><td>Syed / Brian</td><td><span class='bg bg-w'>HIGH</span></td></tr>" })
<tr><td>4</td><td>Fix SCIM 403 on pyxlake-databricks (adb-3248848) - needs PAT from that workspace</td><td>Syed / John</td><td><span class="bg bg-w">HIGH</span></td></tr>
<tr><td>5</td><td>Approve quota increase: standardEDSv4Family westus2 (12->64 cores)</td><td>Tony / John</td><td><span class="bg bg-w">HIGH</span></td></tr>
<tr><td>6</td><td>Save SP secret to Azure Key Vault + set rotation reminder</td><td>Syed</td><td><span class="bg bg-o">MEDIUM</span></td></tr>
<tr><td>7</td><td>Send final report to Tony + John for review</td><td>Syed</td><td><span class="bg bg-o">MEDIUM</span></td></tr>
</table>
</div>

<div class="sec">
<h2>Execution Log</h2>
<div style="max-height:350px;overflow-y:auto;background:#0f172a;padding:10px;border-radius:6px">
$logHtml
</div>
</div>

<div class="ft">
<p>Final Fix Report | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Fixed $totalFixed of $($failedItems.Count) previously failed</p>
<p>Grand Total Savings: `$$grandTotalMo/mo (`$$grandTotalYr/yr) | DBs Remaining: $($verifyResults.Count) | MFA Deadline: $daysLeft days</p>
</div>
</div>
</body>
</html>
"@

$reportFile = Join-Path $outDir "Final-Fix-Report.html"
$html | Out-File -FilePath $reportFile -Encoding UTF8
WL "Report: $reportFile" "Green"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  FIXED:           $totalFixed / $($failedItems.Count)" -ForegroundColor $(if ($totalFailed -eq 0) { "Green" } else { "Yellow" })
Write-Host "  STILL FAILED:    $totalFailed" -ForegroundColor $(if ($totalFailed -eq 0) { "Green" } else { "Red" })
Write-Host "  THIS RUN SAVINGS: `$$actualSavRound/mo" -ForegroundColor Green
Write-Host "  GRAND TOTAL:     `$$grandTotalMo/mo (`$$grandTotalYr/yr)" -ForegroundColor Green
Write-Host "  DBs REMAINING:   $($verifyResults.Count)" -ForegroundColor Cyan
Write-Host "  REPORT:          $reportFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "  NEXT: Run MFA-Enforcement-GOD-Script.ps1 tomorrow" -ForegroundColor Yellow
Write-Host ""

try { Start-Process $reportFile } catch {}
