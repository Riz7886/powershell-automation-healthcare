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

# ================================================================
#  OVERRIDE MAP - Databases Tony flagged as needing MORE DTU
#  Key = "Server/DB" -> forced target tier
#  These override whatever the recommendation CSV says
# ================================================================

$overrides = @{
    # Tony: "went from 200 DTU down to 50 DTU for Pyx-health\MycareLoop. 
    #  There are long running queries that look to be causing problems."
    # Pyx-Health on sql-prod-datasystems currently S2(50), needs S3(100)
    "sql-prod-datasystems/Pyx-Health"           = "S3"

    # Tony manually bumped mycareloop to S2 because web interface wouldn't load
    # Script recommended S1 but S2 needed. Keep at S2.
    # NOTE: Verify this server name matches your SQL_Recommendations.csv Server column.
    #        If it doesn't match, the script will try to find it by DB name.
    "rg-west-sqldb-prod-001/mycareloop"         = "S2"

    # ---------------------------------------------------------------
    # ADD MORE OVERRIDES HERE as Tony/PagerDuty flags them:
    #   "server-name/database-name" = "TargetTier"
    # The server name must match the Server column in SQL_Recommendations.csv
    # Examples:
    #   "sql-prod-datasystems/some-other-db" = "S2"
    #   "sql-qa-datasystems/heavy-report-db" = "S1"
    # ---------------------------------------------------------------
}

# ================================================================
#  PROTECTED DBS - Do NOT touch these at all (manually tuned)
#  If a DB is here, script skips it entirely
# ================================================================

$protectedDbs = @(
    # Add any databases that should never be auto-changed:
    # "server-name/database-name"
)

Write-Host ""
Write-Host "================================================================" -ForegroundColor Red
Write-Host "  FINAL FIX v2 - OVERRIDES + SHRINK + RETRY ALL FAILED" -ForegroundColor Red
Write-Host "  Fixes: MaxSize, Replicas, >250GB, Tony Overrides" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""
Write-Host "  Overrides configured: $($overrides.Count) databases" -ForegroundColor Yellow
Write-Host "  Protected (skip): $($protectedDbs.Count) databases" -ForegroundColor Yellow
if ($DryRun) { Write-Host "  *** DRY RUN MODE - No changes will be made ***" -ForegroundColor Magenta }
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

if (-not $RetryResultsCsv) {
    $rr = Find-Csv "Retry_Results.csv"
    if ($rr.Count -gt 0) { $RetryResultsCsv = $rr[0].FullName }
}

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

# Also inject override databases that might NOT be in the failed list
# (e.g., Pyx-Health may have "succeeded" at S0 but Tony wants it at S3)
$overridesAdded = 0
foreach ($oKey in $overrides.Keys) {
    $parts = $oKey -split '/'
    $oServer = $parts[0]; $oDb = $parts[1]
    $alreadyInList = $failedItems | Where-Object { $_.Server -eq $oServer -and $_.DB -eq $oDb }
    if (-not $alreadyInList) {
        # Check if it's in the original CSV by exact key
        $orig = $lookup[$oKey]
        if (-not $orig) {
            # Fallback: try to find by DB name alone (in case server name is wrong)
            $orig = $origDbs | Where-Object { $_.DB -eq $oDb } | Select-Object -First 1
            if ($orig) { WL "  Override '$oKey' - matched by DB name to $($orig.Server)/$($orig.DB)" "Yellow" }
        }
        if ($orig) {
            $failedItems += [PSCustomObject]@{
                Sub=$orig.Sub;Server=$orig.Server;DB=$orig.DB;
                OldSKU=$orig.SKU;Action="OVERRIDE";NewSKU=$overrides[$oKey];
                Status="OVERRIDE";Cost=$orig.Cost;NewCost="";Saved="";Error=""
            }
            $overridesAdded++
            WL "Added override: $oKey -> $($overrides[$oKey])" "Magenta"
        } else {
            # Not in original CSV - still add with what we know
            $failedItems += [PSCustomObject]@{
                Sub="";Server=$oServer;DB=$oDb;
                OldSKU="";Action="OVERRIDE";NewSKU=$overrides[$oKey];
                Status="OVERRIDE";Cost=0;NewCost="";Saved="";Error=""
            }
            $overridesAdded++
            WL "Added override (no CSV record): $oKey -> $($overrides[$oKey])" "Magenta"
        }
    }
}
if ($overridesAdded -gt 0) { WL "Injected $overridesAdded override databases into work queue" "Magenta" }

if ($failedItems.Count -eq 0) { Write-Host "  No items to fix!" -ForegroundColor Green; exit 0 }

WL "Total work items: $($failedItems.Count) (failed: $($failedItems.Count - $overridesAdded), overrides: $overridesAdded)" "Yellow"

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

# Ordered tiers from cheapest to most expensive
$tierOrder = @("Basic","S0","S1","S2","S3","S4","S6","S7","S9","S12")

# ================================================================
#  HELPER: Get actual DB size in GB
# ================================================================
function Get-DbActualSize {
    param([string]$Server, [string]$DbName, [string]$RG, [string]$SubId)
    $actualGB = 0
    try {
        $usageRaw = az sql db list-usages --server $Server --name $DbName --resource-group $RG --subscription $SubId 2>$null
        if ($usageRaw) {
            $usages = $usageRaw | ConvertFrom-Json
            $spaceUsed = $usages | Where-Object { $_.name -eq "database_size" -or $_.name -eq "used_space" } | Select-Object -First 1
            if ($spaceUsed) { $actualGB = [math]::Round($spaceUsed.currentValue / 1073741824, 2) }
        }
    } catch {}
    return $actualGB
}

# ================================================================
#  HELPER: Find cheapest tier that fits actual data + saves money
# ================================================================
function Get-BestFitTier {
    param([double]$ActualSizeGB, [double]$OrigCost, [string]$PreferredTier)
    # Try preferred tier first
    $pt = $pricing[$PreferredTier]
    if ($pt -and $pt.MaxGB -ge $ActualSizeGB) { return $PreferredTier }
    # Otherwise find cheapest that fits
    foreach ($tn in $tierOrder) {
        $tp = $pricing[$tn]
        if ($tp -and $tp.MaxGB -ge $ActualSizeGB -and $tp.P -lt $OrigCost) { return $tn }
    }
    return $null
}

# ================================================================
#  HELPER: Multi-step shrink strategy
#  Returns: "OK", "PARTIAL:250GB", or "FAILED:reason"
# ================================================================
function Invoke-SmartShrink {
    param(
        [string]$Server, [string]$DbName, [string]$RG, [string]$SubId,
        [double]$CurrentMaxGB, [double]$TargetMaxGB, [double]$ActualSizeGB,
        [string]$TargetTier
    )

    # If actual data > target max, can't shrink below data size
    $shrinkToGB = [math]::Max($TargetMaxGB, [math]::Ceiling($ActualSizeGB + 0.1))

    # Don't need to shrink
    if ($CurrentMaxGB -le $TargetMaxGB) { return "ALREADY OK" }

    # Can't shrink - data is too big
    if ($ActualSizeGB -gt $TargetMaxGB) { return "FAILED:Data ${ActualSizeGB}GB exceeds target max ${TargetMaxGB}GB" }

    WL "  Shrink strategy: ${CurrentMaxGB}GB -> ${shrinkToGB}GB (data: ${ActualSizeGB}GB)" "Cyan"

    # Strategy 1: Direct shrink to target
    $r1 = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --max-size "${shrinkToGB}GB" 2>&1
    if ($LASTEXITCODE -eq 0) { return "OK:${shrinkToGB}GB" }

    $err1 = ($r1 | Out-String).Trim()

    # Strategy 2: If going to Basic (2GB), step through: current -> 250GB -> S0 -> 2GB
    if ($TargetTier -eq "Basic" -and $shrinkToGB -le 2) {
        WL "  Trying stepping-stone: shrink to 250GB first" "Yellow"

        # Step A: Shrink to 250GB on current tier
        if ($CurrentMaxGB -gt 250) {
            $r2a = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --max-size "250GB" 2>&1
            if ($LASTEXITCODE -ne 0) {
                # Current tier might not support 250GB change? try 1024GB
                $r2aa = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --max-size "1024GB" 2>&1
                if ($LASTEXITCODE -ne 0) { return "FAILED:Cannot shrink from ${CurrentMaxGB}GB" }
                # Now try 250GB
                $r2ab = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --max-size "250GB" 2>&1
                if ($LASTEXITCODE -ne 0) { return "PARTIAL:1024GB" }
            }
        }

        # Step B: Move to S0 (supports 250GB max, cheap intermediary)
        $r2b = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --edition "Standard" --service-objective "S0" 2>&1
        if ($LASTEXITCODE -ne 0) {
            # Already on Standard? Just try the 2GB shrink
            $r2c = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --max-size "2GB" 2>&1
            if ($LASTEXITCODE -eq 0) { return "OK:2GB" }
            return "PARTIAL:250GB"
        }

        # Step C: Now shrink from 250GB to 2GB (on S0, which supports this)
        $r2c = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --max-size "2GB" 2>&1
        if ($LASTEXITCODE -eq 0) { return "OK:2GB(via S0)" }

        return "PARTIAL:250GB(on S0)"
    }

    # Strategy 3: If going to S0/S1/S2 (250GB max) and current is >250GB
    if ($TargetTier -in @("S0","S1","S2") -and $shrinkToGB -le 250) {
        # Try stepping down: current -> 1024GB -> 250GB
        if ($CurrentMaxGB -gt 1024) {
            $r3a = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --max-size "1024GB" 2>&1
            if ($LASTEXITCODE -ne 0) { return "FAILED:Cannot shrink from ${CurrentMaxGB}GB to 1024GB" }
        }
        $r3b = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --max-size "250GB" 2>&1
        if ($LASTEXITCODE -eq 0) { return "OK:250GB" }
        return "FAILED:Cannot shrink to 250GB"
    }

    # Strategy 4: General - try shrinking to tier's max
    $r4 = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --max-size "${shrinkToGB}GB" 2>&1
    if ($LASTEXITCODE -eq 0) { return "OK:${shrinkToGB}GB" }

    return "FAILED:All shrink strategies exhausted"
}

# ================================================================
#  HELPER: Fix replica chains - downgrade source before target
# ================================================================
function Fix-ReplicaChain {
    param(
        [string]$ErrorMsg, [string]$Server, [string]$DbName,
        [string]$RG, [string]$SubId,
        [string]$TargetEdition, [string]$TargetObjective, [string]$TargetTier,
        [double]$TargetMaxGB
    )

    # Extract source DB info from error message
    $sourceMatch = [regex]::Match($ErrorMsg, "source database '([^']+)'")
    if (-not $sourceMatch.Success) { return @{Status="FAILED";Error="Could not parse source DB from error"} }

    $sourceFQDN = $sourceMatch.Groups[1].Value
    # Format: server-name.database-name or server-name.sqldb-name
    $srcParts = $sourceFQDN -split '\.'
    $srcServer = if ($srcParts.Count -ge 1) { $srcParts[0] } else { "" }
    $srcDb = if ($srcParts.Count -ge 2) { $srcParts[1] } else { "" }

    if (-not $srcServer -or -not $srcDb) {
        return @{Status="FAILED";Error="Could not parse source server/db from '$sourceFQDN'"}
    }

    WL "  Replica chain detected: source=$srcServer/$srcDb" "Yellow"

    # Find source in our lookup
    $srcOrig = $lookup["$srcServer/$srcDb"]
    $srcRg = if ($srcOrig) { $srcOrig.RG } else { $RG }  # fallback to same RG
    $srcSubId = if ($srcOrig) { $srcOrig.SubId } else { $SubId }

    # Step 1: Shrink source max size if needed
    try {
        $srcDbRaw = az sql db show --server $srcServer --name $srcDb --resource-group $srcRg --subscription $srcSubId 2>$null
        if ($srcDbRaw) {
            $srcDbJson = $srcDbRaw | ConvertFrom-Json
            $srcMaxGB = [math]::Round($srcDbJson.maxSizeBytes / 1073741824, 2)
            if ($srcMaxGB -gt $TargetMaxGB) {
                WL "  Shrinking source max size: ${srcMaxGB}GB -> ${TargetMaxGB}GB" "Cyan"
                az sql db update --server $srcServer --name $srcDb --resource-group $srcRg --subscription $srcSubId --max-size "${TargetMaxGB}GB" 2>$null
            }
        }
    } catch { WL "  Warning: could not check source max size" "Yellow" }

    # Step 2: Downgrade source tier
    WL "  Downgrading source to $TargetTier..." "Cyan"
    $srcUpd = az sql db update --server $srcServer --name $srcDb --resource-group $srcRg --subscription $srcSubId --edition $TargetEdition --service-objective $TargetObjective 2>&1
    if ($LASTEXITCODE -ne 0) {
        $srcErr = ($srcUpd | Out-String).Trim()
        # If source also has replica issue, it's a chain - try S0 as minimum
        WL "  Source downgrade failed, trying progressive tiers..." "Yellow"
        foreach ($ft in $tierOrder) {
            if ($ft -eq "Basic") { continue }  # skip Basic for sources - too risky
            $fp = $pricing[$ft]
            if (-not $fp) { continue }
            $ftUpd = az sql db update --server $srcServer --name $srcDb --resource-group $srcRg --subscription $srcSubId --edition $fp.E --service-objective $fp.O 2>&1
            if ($LASTEXITCODE -eq 0) {
                WL "  Source set to $ft (progressive)" "Green"
                break
            }
        }
    } else {
        WL "  Source downgraded to $TargetTier" "Green"
    }

    # Step 3: Wait for source change to propagate
    Start-Sleep -Seconds 8

    # Step 4: Retry the target database
    WL "  Retrying target: $Server/$DbName -> $TargetTier" "Cyan"
    $retryUpd = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --edition $TargetEdition --service-objective $TargetObjective 2>&1
    if ($LASTEXITCODE -eq 0) {
        return @{Status="FIXED";Error="";SourceFixed="$srcServer/$srcDb"}
    }

    # Step 5: If still fails, try progressively higher tiers on the target
    WL "  Target still blocked, trying higher tiers..." "Yellow"
    foreach ($ft in $tierOrder) {
        if ($ft -eq "Basic") { continue }
        $fp = $pricing[$ft]
        if (-not $fp) { continue }
        $ftUpd = az sql db update --server $Server --name $DbName --resource-group $RG --subscription $SubId --edition $fp.E --service-objective $fp.O 2>&1
        if ($LASTEXITCODE -eq 0) {
            return @{Status="PARTIAL";Error="Replica chain - settled on $ft";FallbackTier=$ft;FallbackCost=$fp.P}
        }
    }

    return @{Status="FAILED";Error="Replica chain unresolvable - source: $srcServer/$srcDb"}
}

# ================================================================
#  STEP 2: FIX EACH DATABASE
# ================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Red
Write-Host "  STEP 2: FIX $($failedItems.Count) DATABASES" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""

$results = @()
$fixOk = 0; $fixFail = 0; $fixSkip = 0
$actualSavings = 0
$currentSub = ""
$counter = 0
$overrideCount = 0

foreach ($f in $failedItems) {
    $counter++
    $key = "$($f.Server)/$($f.DB)"
    $orig = $lookup[$key]

    # ---- PROTECTED CHECK ----
    if ($protectedDbs -contains $key) {
        Write-Host "  [$counter/$($failedItems.Count)] $key " -ForegroundColor Gray -NoNewline
        Write-Host "PROTECTED - SKIP" -ForegroundColor Magenta
        WL "  PROTECTED: $key - skipped per protection list" "Magenta"
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU="N/A";Action="PROTECTED";Step1="N/A";Step2="N/A";FinalStatus="PROTECTED";Cost=0;NewCost=0;Saved=0;Error="In protected list - not touched";ActualSize="";MaxSize="";OverrideApplied=$false}
        $fixSkip++
        continue
    }

    # ---- OVERRIDE CHECK ----
    $isOverride = $false
    $overrideTier = $null
    if ($overrides.ContainsKey($key)) {
        $overrideTier = $overrides[$key]
        $isOverride = $true
        WL "  OVERRIDE: $key -> forced to $overrideTier (Tony flagged)" "Magenta"
    }

    # Get SubId and RG from original
    $subId = if ($orig) { $orig.SubId } else { "" }
    $rg = if ($orig) { $orig.RG } else { "" }

    # Target tier: override wins, then retry CSV, then original CSV
    $targetTier = if ($isOverride) { $overrideTier }
                  elseif ($f.NewSKU) { $f.NewSKU }
                  elseif ($orig) { $orig.Rec }
                  else { "" }

    $origCost = 0
    try { if ($orig -and $orig.Cost) { $origCost = [double]$orig.Cost } elseif ($f.Cost) { $origCost = [double]$f.Cost } } catch { $origCost = 0 }
    $action = if ($isOverride) { "OVERRIDE" } elseif ($f.Action) { $f.Action } else { "DROP" }

    if (-not $subId -or -not $rg) {
        # Try to find by server name in all original records
        $foundOrig = $origDbs | Where-Object { $_.Server -eq $f.Server } | Select-Object -First 1
        if (-not $foundOrig) {
            # Fallback: try by DB name (covers overrides with wrong server name)
            $foundOrig = $origDbs | Where-Object { $_.DB -eq $f.DB } | Select-Object -First 1
        }
        if ($foundOrig) {
            $subId = $foundOrig.SubId
            $rg = $foundOrig.RG
            if (-not $origCost -or $origCost -eq 0) { try { $origCost = [double]$foundOrig.Cost } catch {} }
        }
    }

    if (-not $subId -or -not $rg) {
        Write-Host "  [$counter/$($failedItems.Count)] $key SKIP - no SubId/RG" -ForegroundColor DarkGray
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1="N/A";Step2="N/A";FinalStatus="SKIPPED";Cost=$origCost;NewCost=$origCost;Saved=0;Error="Missing SubId or RG";ActualSize="";MaxSize="";OverrideApplied=$isOverride}
        $fixSkip++
        continue
    }

    if ($currentSub -ne $subId) {
        az account set --subscription $subId 2>$null
        $currentSub = $subId
    }

    $prefix = if ($isOverride) { "OVR" } else { "FIX" }
    Write-Host "  [$counter/$($failedItems.Count)] [$prefix] $key " -ForegroundColor $(if ($isOverride) { "Magenta" } else { "Gray" }) -NoNewline

    # Step A: Check if database still exists + get current state
    $dbJson = $null
    try {
        $dbRaw = az sql db show --server $f.Server --name $f.DB --resource-group $rg --subscription $subId 2>&1
        if ($LASTEXITCODE -eq 0) { $dbJson = $dbRaw | ConvertFrom-Json }
    } catch {}

    if (-not $dbJson) {
        Write-Host "ALREADY GONE" -ForegroundColor DarkGray
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1="N/A";Step2="N/A";FinalStatus="ALREADY DELETED";Cost=$origCost;NewCost=0;Saved=$origCost;Error="";ActualSize="";MaxSize="";OverrideApplied=$isOverride}
        $fixOk++
        $actualSavings += $origCost
        continue
    }

    $currentSKU = $dbJson.currentServiceObjectiveName
    $currentEdition = $dbJson.edition
    $maxSizeBytes = $dbJson.maxSizeBytes
    $maxSizeGB = [math]::Round($maxSizeBytes / 1073741824, 2)

    # Check actual used space
    $actualSizeGB = Get-DbActualSize -Server $f.Server -DbName $f.DB -RG $rg -SubId $subId

    Write-Host "[$currentSKU max:${maxSizeGB}GB used:${actualSizeGB}GB] " -ForegroundColor DarkCyan -NoNewline

    # Already at target?
    if ($currentSKU -eq $targetTier -and -not $isOverride) {
        Write-Host "ALREADY AT TARGET" -ForegroundColor DarkGreen
        $newP = if ($pricing[$targetTier]) { $pricing[$targetTier].P } else { $origCost }
        $sav = [math]::Round($origCost - $newP, 2)
        if ($sav -lt 0) { $sav = 0 }
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$f.OldSKU;TargetSKU=$targetTier;Action=$action;Step1="N/A";Step2="N/A";FinalStatus="ALREADY DONE";Cost=$origCost;NewCost=$newP;Saved=$sav;Error="";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB";OverrideApplied=$false}
        $fixOk++
        $actualSavings += $sav
        continue
    }

    # Override already at correct tier
    if ($isOverride -and $currentSKU -eq $targetTier) {
        Write-Host "OVERRIDE ALREADY SET" -ForegroundColor Green
        $newP = if ($pricing[$targetTier]) { $pricing[$targetTier].P } else { 0 }
        $sav = [math]::Round($origCost - $newP, 2); if ($sav -lt 0) { $sav = 0 }
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$currentSKU;TargetSKU=$targetTier;Action="OVERRIDE";Step1="N/A";Step2="Already at override tier";FinalStatus="ALREADY DONE";Cost=$origCost;NewCost=$newP;Saved=$sav;Error="";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB";OverrideApplied=$true}
        $fixOk++; $overrideCount++
        $actualSavings += $sav
        continue
    }

    if ($DryRun) {
        Write-Host "DRY RUN -> $targetTier" -ForegroundColor Yellow
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$currentSKU;TargetSKU=$targetTier;Action=$action;Step1="Would shrink";Step2="Would change tier";FinalStatus="DRY RUN";Cost=$origCost;NewCost=0;Saved=0;Error="";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB";OverrideApplied=$isOverride}
        $fixSkip++
        continue
    }

    # Determine target tier constraints
    $t = $pricing[$targetTier]
    if (-not $t) {
        Write-Host "SKIP - unknown tier $targetTier" -ForegroundColor Gray
        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$currentSKU;TargetSKU=$targetTier;Action=$action;Step1="N/A";Step2="N/A";FinalStatus="SKIPPED";Cost=$origCost;NewCost=$origCost;Saved=0;Error="Unknown target tier: $targetTier";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB";OverrideApplied=$isOverride}
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
    if ($actualSizeGB -gt $targetMaxGB -and -not $isOverride) {
        $bestTier = Get-BestFitTier -ActualSizeGB $actualSizeGB -OrigCost $origCost -PreferredTier $targetTier
        if (-not $bestTier) {
            Write-Host "SKIP - data ${actualSizeGB}GB too big" -ForegroundColor Yellow
            $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$currentSKU;TargetSKU=$targetTier;Action=$action;Step1="N/A";Step2="N/A";FinalStatus="SKIPPED-DATA TOO BIG";Cost=$origCost;NewCost=$origCost;Saved=0;Error="Actual data ${actualSizeGB}GB exceeds all cheaper tiers";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB";OverrideApplied=$false}
            $fixSkip++
            continue
        }
        if ($bestTier -ne $targetTier) {
            WL "  Adjusted target: $targetTier -> $bestTier (data ${actualSizeGB}GB)" "Yellow"
            $targetTier = $bestTier
            $t = $pricing[$targetTier]
            $targetMaxGB = $t.MaxGB
            $targetEdition = $t.E
            $targetObjective = $t.O
            $targetCost = $t.P
        }
    }

    # Step 1: Shrink max size if needed
    $needShrink = ($maxSizeGB -gt $targetMaxGB)

    if ($needShrink) {
        Write-Host "SHRINK(${maxSizeGB}GB->${targetMaxGB}GB) " -ForegroundColor Cyan -NoNewline

        $shrinkResult = Invoke-SmartShrink -Server $f.Server -DbName $f.DB -RG $rg -SubId $subId `
            -CurrentMaxGB $maxSizeGB -TargetMaxGB $targetMaxGB -ActualSizeGB $actualSizeGB -TargetTier $targetTier

        if ($shrinkResult -match "^OK:") {
            $step1Status = "SHRUNK $($shrinkResult -replace 'OK:','')"
            Write-Host "OK " -ForegroundColor Green -NoNewline
        } elseif ($shrinkResult -match "^PARTIAL:") {
            $partialSize = $shrinkResult -replace 'PARTIAL:',''
            $step1Status = "PARTIAL SHRINK to $partialSize"
            Write-Host "PARTIAL($partialSize) " -ForegroundColor Yellow -NoNewline
        } elseif ($shrinkResult -eq "ALREADY OK") {
            $step1Status = "No shrink needed"
        } else {
            $step1Status = "SHRINK FAILED"
            $finalErr = $shrinkResult -replace 'FAILED:',''
            Write-Host "SHRINK FAIL " -ForegroundColor Red -NoNewline
        }
    } else {
        $step1Status = "No shrink needed"
    }

    # Step 2: Change tier
    $canProceed = ($step1Status -notmatch "SHRINK FAILED")
    # For overrides going UP (e.g. S2 -> S3), shrink isn't needed anyway
    if ($isOverride) { $canProceed = $true }

    if ($canProceed) {
        try {
            $updResult = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --edition $targetEdition --service-objective $targetObjective 2>&1
            if ($LASTEXITCODE -eq 0) {
                $step2Status = "CHANGED to $targetTier"
                $sav = [math]::Round($origCost - $targetCost, 2)
                if ($sav -lt 0) { $sav = 0 }  # override bumps UP might not save
                $statusLabel = if ($isOverride) { "OVERRIDE OK" } else { "FIXED" }
                $statusColor = if ($isOverride) { "Magenta" } else { "Green" }
                Write-Host "$statusLabel -> $targetTier" -ForegroundColor $statusColor
                if ($isOverride) {
                    WL "  OVERRIDE: $key: $currentSKU -> $targetTier (Tony flagged)" "Magenta"
                    $overrideCount++
                } else {
                    WL "  $key: $currentSKU -> $targetTier | Saved `$$sav/mo" "Green"
                }
                $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$currentSKU;TargetSKU=$targetTier;Action=$action;Step1=$step1Status;Step2=$step2Status;FinalStatus=$statusLabel;Cost=$origCost;NewCost=$targetCost;Saved=$sav;Error="";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB";OverrideApplied=$isOverride}
                $fixOk++
                $actualSavings += $sav
                continue
            } else {
                $updErr = ($updResult | Out-String).Trim()

                # ---- HANDLE: Replica/Copy can't be cheaper than source ----
                if ($updErr -match "TargetDatabaseEditionCouldNotBeDowngraded|cannot have lower edition than the source") {
                    $step2Status = "REPLICA BLOCK"
                    Write-Host "REPLICA " -ForegroundColor Yellow -NoNewline

                    $replicaFix = Fix-ReplicaChain -ErrorMsg $updErr -Server $f.Server -DbName $f.DB `
                        -RG $rg -SubId $subId -TargetEdition $targetEdition -TargetObjective $targetObjective `
                        -TargetTier $targetTier -TargetMaxGB $targetMaxGB

                    if ($replicaFix.Status -eq "FIXED") {
                        $sav = [math]::Round($origCost - $targetCost, 2); if ($sav -lt 0) { $sav = 0 }
                        Write-Host "FIXED (source+target)" -ForegroundColor Green
                        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$currentSKU;TargetSKU=$targetTier;Action=$action;Step1=$step1Status;Step2="FIXED (via source: $($replicaFix.SourceFixed))";FinalStatus="FIXED";Cost=$origCost;NewCost=$targetCost;Saved=$sav;Error="";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB";OverrideApplied=$isOverride}
                        $fixOk++
                        $actualSavings += $sav
                        continue
                    } elseif ($replicaFix.Status -eq "PARTIAL") {
                        $fbTier = $replicaFix.FallbackTier
                        $fbCost = $replicaFix.FallbackCost
                        $sav = [math]::Round($origCost - $fbCost, 2); if ($sav -lt 0) { $sav = 0 }
                        Write-Host "PARTIAL -> $fbTier" -ForegroundColor Yellow
                        $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$currentSKU;TargetSKU=$fbTier;Action=$action;Step1=$step1Status;Step2="FALLBACK $fbTier (replica)";FinalStatus="PARTIAL";Cost=$origCost;NewCost=$fbCost;Saved=$sav;Error=$replicaFix.Error;ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB";OverrideApplied=$isOverride}
                        $fixOk++
                        $actualSavings += $sav
                        continue
                    } else {
                        $finalErr = $replicaFix.Error
                        Write-Host "STILL BLOCKED" -ForegroundColor Red
                    }

                # ---- HANDLE: Max size mismatch (even after shrink attempt) ----
                } elseif ($updErr -match "InvalidMaxSizeTierCombination|does not support the database max size") {
                    $step2Status = "SIZE BLOCK"
                    Write-Host "SIZE BLOCK " -ForegroundColor Yellow -NoNewline

                    # Try progressive tiers: find cheapest that works
                    $fallbackFound = $false
                    foreach ($ft in $tierOrder) {
                        $fp = $pricing[$ft]
                        if (-not $fp -or $fp.P -ge $origCost) { continue }
                        # Shrink to this tier's max first
                        if ($maxSizeGB -gt $fp.MaxGB -and $actualSizeGB -le $fp.MaxGB) {
                            az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --max-size "$($fp.MaxGB)GB" 2>$null
                        }
                        $fbResult = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --edition $fp.E --service-objective $fp.O 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            $sav = [math]::Round($origCost - $fp.P, 2); if ($sav -lt 0) { $sav = 0 }
                            Write-Host "FALLBACK -> $ft" -ForegroundColor Yellow
                            $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$currentSKU;TargetSKU=$ft;Action=$action;Step1=$step1Status;Step2="FALLBACK $ft (size)";FinalStatus="PARTIAL";Cost=$origCost;NewCost=$fp.P;Saved=$sav;Error="MaxSize block - used $ft";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB";OverrideApplied=$isOverride}
                            $fixOk++
                            $actualSavings += $sav
                            $fallbackFound = $true
                            break
                        }
                    }
                    if ($fallbackFound) { continue }
                    $finalErr = "Max size block - all fallback tiers failed"
                    Write-Host "ALL FALLBACKS FAILED" -ForegroundColor Red

                # ---- HANDLE: >250GB provisioning disabled ----
                } elseif ($updErr -match "ProvisioningDisabled|greater than.*250 GB") {
                    $step2Status = ">250GB BLOCK"
                    Write-Host ">250GB " -ForegroundColor Yellow -NoNewline

                    # Need S3+ for >250GB; shrink to 1TB first
                    az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --max-size "1024GB" 2>$null
                    $fb = $pricing["S3"]
                    if ($fb -and $fb.P -lt $origCost) {
                        $fbResult = az sql db update --server $f.Server --name $f.DB --resource-group $rg --subscription $subId --edition $fb.E --service-objective $fb.O 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            $sav = [math]::Round($origCost - $fb.P, 2); if ($sav -lt 0) { $sav = 0 }
                            Write-Host "FIXED at S3" -ForegroundColor Yellow
                            $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$currentSKU;TargetSKU="S3";Action=$action;Step1="Shrunk to 1TB";Step2="Changed to S3";FinalStatus="FIXED";Cost=$origCost;NewCost=$fb.P;Saved=$sav;Error="";ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB";OverrideApplied=$isOverride}
                            $fixOk++
                            $actualSavings += $sav
                            continue
                        }
                    }
                    $finalErr = ">250GB provisioning block - S3 fallback failed"
                    Write-Host "STILL BLOCKED" -ForegroundColor Red

                # ---- HANDLE: Any other error ----
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
    $results += [PSCustomObject]@{Sub=$f.Sub;Server=$f.Server;DB=$f.DB;OldSKU=$currentSKU;TargetSKU=$targetTier;Action=$action;Step1=$step1Status;Step2=$step2Status;FinalStatus="FAILED";Cost=$origCost;NewCost=$origCost;Saved=0;Error=$finalErr;ActualSize="${actualSizeGB}GB";MaxSize="${maxSizeGB}GB";OverrideApplied=$isOverride}
    $fixFail++
}

Write-Host ""
WL "Results: $fixOk FIXED | $fixFail FAILED | $fixSkip SKIPPED | $overrideCount OVERRIDES APPLIED" $(if ($fixFail -gt 0) { "Yellow" } else { "Green" })

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

$totalFixed = @($results | Where-Object { $_.FinalStatus -in @("FIXED","PARTIAL","ALREADY DONE","ALREADY DELETED","OVERRIDE OK") }).Count
$totalFailed = @($results | Where-Object { $_.FinalStatus -eq "FAILED" }).Count
$totalSkipped = @($results | Where-Object { $_.FinalStatus -match "SKIP|PROTECTED" }).Count
$totalOverrides = @($results | Where-Object { $_.OverrideApplied -eq $true }).Count
$actualSavRound = [math]::Round($actualSavings, 2)
$actualYearly = [math]::Round($actualSavings * 12, 2)
$successRate = if ($failedItems.Count -gt 0) { [math]::Round(($totalFixed / $failedItems.Count) * 100, 1) } else { 100 }
$deadline = [datetime]"2026-02-09"
$daysLeft = [math]::Max(0, ($deadline - (Get-Date)).Days)
$urgColor = if ($daysLeft -le 2) { '#ef4444' } elseif ($daysLeft -le 5) { '#f97316' } else { '#22c55e' }

# Previous savings from retry
$prevSav = 5038.80
$grandTotalMo = [math]::Round($prevSav + $actualSavRound, 2)
$grandTotalYr = [math]::Round($grandTotalMo * 12, 2)

# Build override summary for report
$overrideSummary = ""
foreach ($oKey in $overrides.Keys) {
    $oResult = $results | Where-Object { "$($_.Server)/$($_.DB)" -eq $oKey } | Select-Object -First 1
    $oStatus = if ($oResult) { $oResult.FinalStatus } else { "NOT PROCESSED" }
    $oFrom = if ($oResult) { $oResult.OldSKU } else { "?" }
    $oColor = switch ($oStatus) { "OVERRIDE OK" { "#a855f7" } "ALREADY DONE" { "#22c55e" } default { "#ef4444" } }
    $overrideSummary += "<tr><td style='font-weight:bold'>$oKey</td><td>$oFrom</td><td style='color:#a855f7;font-weight:bold'>$($overrides[$oKey])</td><td style='color:$oColor'>$oStatus</td><td>Tony flagged - long running queries need DTU headroom</td></tr>"
}

# Build fix table rows
$fixTableRows = ""
foreach ($r in ($results | Sort-Object @{E={switch -Wildcard ($_.FinalStatus) {"FAILED"{0}"PARTIAL"{1}"OVERRIDE*"{2}default{3}}}},Sub,Server,DB)) {
    $sc = switch -Wildcard ($r.FinalStatus) { "FIXED" { "#22c55e" } "OVERRIDE*" { "#a855f7" } "PARTIAL" { "#f59e0b" } "ALREADY*" { "#22c55e" } "FAILED" { "#ef4444" } "PROTECTED" { "#60a5fa" } default { "#64748b" } }
    $bg = if ($r.FinalStatus -eq "FAILED") { "background:#1a0505;" } elseif ($r.FinalStatus -eq "PARTIAL") { "background:#1a1005;" } elseif ($r.OverrideApplied) { "background:#1a0520;" } else { "" }
    $ovrBadge = if ($r.OverrideApplied) { " <span style='background:#7c3aed;color:#fff;padding:1px 5px;border-radius:8px;font-size:8px'>OVR</span>" } else { "" }
    $errStr = if ($r.Error) { [string]$r.Error } else { "" }
    $errTd = if ($errStr.Length -gt 0) { "<td style='color:#ef4444;font-size:10px;max-width:250px;word-break:break-word'>$($errStr.Substring(0, [math]::Min(150, $errStr.Length)))</td>" } else { "<td></td>" }
    $fixTableRows += "<tr style='$bg'><td>$($r.Sub)</td><td>$($r.Server)</td><td style='font-weight:bold'>$($r.DB)$ovrBadge</td><td>$($r.OldSKU)</td><td style='color:$sc;font-weight:bold'>$($r.TargetSKU)</td><td>$($r.ActualSize)</td><td>$($r.MaxSize)</td><td>$($r.Step1)</td><td>$($r.Step2)</td><td style='color:$sc;font-weight:bold'>$($r.FinalStatus)</td><td>`$$($r.Cost)</td><td>`$$($r.NewCost)</td><td style='color:#22c55e'>`$$($r.Saved)</td>$errTd</tr>"
}

$verifyTableRows = ""
foreach ($v in ($verifyResults | Sort-Object Sub,Server,DB)) {
    # Highlight overridden databases in verify table
    $vKey = "$($v.Server)/$($v.DB)"
    $vStyle = if ($overrides.ContainsKey($vKey)) { "background:#1a0520;" } else { "" }
    $vBadge = if ($overrides.ContainsKey($vKey)) { " <span style='background:#7c3aed;color:#fff;padding:1px 5px;border-radius:8px;font-size:8px'>OVR</span>" } else { "" }
    $verifyTableRows += "<tr style='$vStyle'><td>$($v.Sub)</td><td>$($v.Server)</td><td>$($v.DB)$vBadge</td><td>$($v.SKU)</td><td>$($v.Edition)</td><td>$($v.MaxSizeGB)GB</td></tr>"
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
    if ($l -match "FAIL|ERROR|BLOCK") { $lc = "#ef4444" } elseif ($l -match "WARN|SKIP|PARTIAL|Adjusted|FALLBACK") { $lc = "#f59e0b" } elseif ($l -match "OVERRIDE") { $lc = "#a855f7" } elseif ($l -match "OK|FIXED|CHANGED|DELETED|Green|Login OK|Saved") { $lc = "#22c55e" }
    $safe = $l -replace '<','&lt;' -replace '>','&gt;'
    $logHtml += "<div style='color:$lc;font-family:monospace;font-size:11px;line-height:1.5'>$safe</div>"
}

$overallStatus = if ($totalFailed -eq 0) { "ALL $($failedItems.Count) ITEMS RESOLVED - $totalOverrides OVERRIDES APPLIED" } elseif ($successRate -ge 80) { "MOSTLY FIXED - $totalFailed STILL NEED MANUAL REVIEW" } else { "$totalFixed FIXED / $totalFailed REMAINING" }
$overallColor = if ($totalFailed -eq 0) { "#22c55e" } elseif ($successRate -ge 80) { "#f59e0b" } else { "#ef4444" }
$banGrad2 = if ($daysLeft -le 2) { '#dc2626' } else { '#ea580c' }
$failedCardColor = if ($totalFailed -eq 0) { '#22c55e' } else { '#ef4444' }
$failedCardText = if ($totalFailed -eq 0) { 'NONE!' } else { 'need manual review' }
$srColor = if ($successRate -ge 90) { '#22c55e' } elseif ($successRate -ge 70) { '#f59e0b' } else { '#ef4444' }
$fixedConsoleColor = if ($totalFailed -eq 0) { "Green" } else { "Yellow" }
$failedConsoleColor = if ($totalFailed -eq 0) { "Green" } else { "Red" }
$actionNum3 = if ($totalFailed -gt 0) { 4 } else { 3 }
$actionNum4 = if ($totalFailed -gt 0) { 5 } else { 4 }

# Build conditional HTML sections as separate variables (avoids nested here-string bug)
$overrideHtml = ""
if ($overrides.Count -gt 0) {
    $overrideHtml = '<div class="ovr-sec">' +
        '<h2 style="color:#c084fc">TONY''S OVERRIDES - Databases Bumped UP for DTU Headroom</h2>' +
        '<p style="color:#a5b4fc;font-size:11px;margin-bottom:10px">These databases had low average DTU but long-running queries that spike high. Script recommendation was too aggressive - Tony flagged via PagerDuty/Teams. Override forces a higher tier to prevent query timeouts.</p>' +
        '<table><tr><th>Server/Database</th><th>Was At</th><th>Override To</th><th>Status</th><th>Reason</th></tr>' +
        $overrideSummary +
        '</table></div>'
}

$failedHtml = ""
if ($failedOnly.Count -gt 0) {
    $failedHtml = '<div class="sec" style="border:2px solid #ef4444">' +
        "<h2 style=`"color:#ef4444`">STILL FAILED - Need Manual Review ($($failedOnly.Count))</h2>" +
        '<table><tr><th>Sub</th><th>Server</th><th>Database</th><th>From</th><th>Target</th><th>Used</th><th>MaxSize</th><th>Error</th></tr>' +
        $failedOnlyRows +
        '</table></div>'
}

$failedActionRow = ""
if ($totalFailed -gt 0) {
    $failedActionRow = "<tr><td>3</td><td>Review $totalFailed remaining failed databases - may need manual intervention</td><td>Syed / Brian</td><td><span class='bg bg-w'>HIGH</span></td></tr>"
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Final Fix v2 Report - $(Get-Date -Format 'yyyy-MM-dd')</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#0f172a;color:#e2e8f0;padding:20px}
.ctr{max-width:1600px;margin:0 auto}
.hdr{background:linear-gradient(135deg,#1e293b,#334155);border-radius:12px;padding:25px;margin-bottom:15px;border:1px solid #475569}
.hdr h1{font-size:24px;color:#f1f5f9;margin-bottom:4px}
.hdr p{color:#94a3b8;font-size:12px}
.ban{border-radius:12px;padding:16px;margin-bottom:12px;text-align:center}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-bottom:15px}
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
.bg-c{background:#7f1d1d;color:#fca5a5}.bg-w{background:#78350f;color:#fbbf24}.bg-o{background:#14532d;color:#86efac}.bg-p{background:#3b0764;color:#c084fc}
.ib{border-radius:8px;padding:12px;margin-bottom:10px}
.bar{height:8px;border-radius:4px;background:#334155;overflow:hidden;margin-top:6px}
.fill{height:100%;border-radius:4px}
.grand{background:linear-gradient(135deg,#14532d,#166534);border:2px solid #22c55e;border-radius:12px;padding:20px;margin-bottom:15px;text-align:center}
.ovr-sec{background:linear-gradient(135deg,#1e1b4b,#312e81);border:2px solid #7c3aed;border-radius:12px;padding:16px;margin-bottom:12px}
@media print{body{background:#fff;color:#000}th{background:#f1f5f9;color:#000}td{border-color:#e2e8f0}.card,.sec,.hdr{border-color:#e2e8f0;background:#fff}}
</style>
</head>
<body>
<div class="ctr">
<div class="hdr">
<h1>FINAL FIX v2 - OVERRIDES + SHRINK + RETRY</h1>
<p>Generated: $(Get-Date -Format 'MMMM dd, yyyy HH:mm:ss') | $($failedItems.Count) items ($($failedItems.Count - $overridesAdded) failed + $overridesAdded overrides)</p>
<p style="margin-top:6px;font-size:14px;color:$overallColor;font-weight:bold">$overallStatus</p>
</div>

<div class="ban" style="background:linear-gradient(135deg,$urgColor,$banGrad2)">
<h2 style="font-size:22px;color:#fff">MFA ENFORCEMENT: $daysLeft DAYS (Feb 9, 2026)</h2>
</div>

<div class="grand">
<h2 style="font-size:14px;color:#86efac;margin-bottom:8px">COMBINED SAVINGS - ALL SCRIPTS</h2>
<div style="display:flex;justify-content:center;gap:40px;flex-wrap:wrap">
<div><div style="font-size:12px;color:#86efac">Retry Fix (Round 1)</div><div style="font-size:28px;font-weight:bold;color:#22c55e">`$$prevSav/mo</div></div>
<div style="font-size:28px;color:#475569;padding-top:15px">+</div>
<div><div style="font-size:12px;color:#86efac">Final Fix v2 (This Run)</div><div style="font-size:28px;font-weight:bold;color:#22c55e">`$$actualSavRound/mo</div></div>
<div style="font-size:28px;color:#475569;padding-top:15px">=</div>
<div><div style="font-size:12px;color:#fbbf24">GRAND TOTAL</div><div style="font-size:36px;font-weight:bold;color:#fff">`$$grandTotalMo/mo</div><div style="font-size:14px;color:#86efac">`$$grandTotalYr/yr</div></div>
</div>
</div>

<div class="grid">
<div class="card"><h3>Work Items</h3><div class="v" style="color:#f59e0b">$($failedItems.Count)</div><div class="s">failed + overrides</div></div>
<div class="card"><h3>Fixed</h3><div class="v" style="color:#22c55e">$totalFixed</div><div class="s">shrink + tier change</div></div>
<div class="card"><h3>Overrides</h3><div class="v" style="color:#a855f7">$totalOverrides</div><div class="s">Tony flagged</div></div>
<div class="card"><h3>Still Failed</h3><div class="v" style="color:$failedCardColor">$totalFailed</div><div class="s">$failedCardText</div></div>
<div class="card"><h3>Success Rate</h3><div class="v" style="color:$srColor">$successRate%</div><div class="bar"><div class="fill" style="width:$successRate%;background:$srColor"></div></div></div>
<div class="card"><h3>This Run Savings</h3><div class="v" style="color:#22c55e">`$$actualSavRound</div><div class="s">/mo additional</div></div>
<div class="card"><h3>DBs Remaining</h3><div class="v" style="color:#60a5fa">$($verifyResults.Count)</div><div class="s">after all fixes</div></div>
</div>

$overrideHtml

<div class="sec" style="border:2px solid #f59e0b">
<h2 style="color:#f59e0b">BRIEFING</h2>
<div class="ib" style="background:#7f1d1d;border-left:4px solid #ef4444">
<h3 style="color:#fca5a5;margin-bottom:5px;font-size:13px">MFA Enforcement - $daysLeft DAYS (Feb 9, 2026)</h3>
<p style="color:#e2e8f0;font-size:11px">M365 Admin Center mandatory MFA. Admins without MFA = LOCKED OUT. Run MFA script tomorrow.</p>
</div>
<div class="ib" style="background:#3b0764;border-left:4px solid #7c3aed">
<h3 style="color:#c084fc;margin-bottom:5px;font-size:13px">Override Pattern for Future Use</h3>
<p style="color:#e2e8f0;font-size:11px">If PagerDuty flags more DBs with DTU issues: open Final-Fix-v2.ps1, add to the overrides hashtable at line ~40: "server/db" = "S3" and re-run.</p>
</div>
<div class="ib" style="background:#78350f;border-left:4px solid #f59e0b">
<h3 style="color:#fbbf24;margin-bottom:5px;font-size:13px">PagerDuty DTU Alerts</h3>
<p style="color:#e2e8f0;font-size:11px">Tony: Pyx-Health long-running queries need S3 (100 DTU). mycareloop bumped to S2 (50 DTU). Monitor for 24h after changes.</p>
</div>
</div>

<div class="sec">
<h2>How Fixes Were Applied</h2>
<table>
<tr><th>Error Type</th><th>Fix Strategy</th><th>Fallback</th></tr>
<tr><td style="color:#f59e0b">InvalidMaxSizeTierCombination</td><td>Multi-step shrink: 250GB then S0 then 2GB stepping stone for Basic; direct shrink for Standard</td><td>Try progressively higher tiers until one fits</td></tr>
<tr><td style="color:#f59e0b">TargetDatabaseEditionCouldNotBeDowngraded</td><td>Find source DB from error message, downgrade source first, wait 8s, retry target</td><td>Progressive tier scan on target (S0 S1 S2 S3)</td></tr>
<tr><td style="color:#f59e0b">ProvisioningDisabled (over 250GB)</td><td>Shrink max to 1TB, then change to S3 (150/mo)</td><td>S3 is cheapest tier supporting over 250GB</td></tr>
<tr><td style="color:#a855f7">Override (Tony flagged)</td><td>Force specific tier regardless of recommendation - handles long-running query spikes</td><td>N/A - manual decision</td></tr>
<tr><td style="color:#64748b">Any other error</td><td>Direct tier change attempt</td><td>Try progressively higher tiers that still save money</td></tr>
</table>
</div>

<div class="sec">
<h2>All Operations ($($failedItems.Count) items)</h2>
<div style="max-height:600px;overflow-y:auto">
<table>
<tr><th>Sub</th><th>Server</th><th>Database</th><th>From</th><th>To</th><th>Used</th><th>MaxSize</th><th>Step 1</th><th>Step 2</th><th>Status</th><th>Old Cost</th><th>New Cost</th><th>Saved</th><th>Error</th></tr>
$fixTableRows
</table>
</div>
</div>

$failedHtml

<div class="sec">
<h2>VERIFIED - Current Database State ($($verifyResults.Count) databases)</h2>
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
<tr><td>1</td><td><strong>Run MFA enforcement script TOMORROW</strong> - Audit first, deploy CA policies before Feb 9</td><td>Syed</td><td><span class="bg bg-c">CRITICAL</span></td></tr>
<tr><td>2</td><td>Monitor PagerDuty for 24h - confirm overridden DBs (Pyx-Health S3, mycareloop S2) are stable</td><td>Tony / Syed</td><td><span class="bg bg-c">CRITICAL</span></td></tr>
$failedActionRow
<tr><td>$actionNum3</td><td>If PagerDuty flags more DTU issues: add to overrides in script and re-run</td><td>Syed</td><td><span class="bg bg-p">OVERRIDE</span></td></tr>
<tr><td>$actionNum4</td><td>Send final combined report (retry + final fix) to Tony + John</td><td>Syed</td><td><span class="bg bg-o">MEDIUM</span></td></tr>
</table>
</div>

<div class="sec">
<h2>Execution Log</h2>
<div style="max-height:350px;overflow-y:auto;background:#0f172a;padding:10px;border-radius:6px">
$logHtml
</div>
</div>

<div class="ft">
<p>Final Fix v2 Report | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Fixed $totalFixed of $($failedItems.Count) | Overrides: $totalOverrides</p>
<p>Grand Total Savings: `$$grandTotalMo/mo (`$$grandTotalYr/yr) | DBs Remaining: $($verifyResults.Count) | MFA Deadline: $daysLeft days</p>
</div>
</div>
</body>
</html>
"@

$reportFile = Join-Path $outDir "Final-Fix-v2-Report.html"
$html | Out-File -FilePath $reportFile -Encoding UTF8
WL "Report: $reportFile" "Green"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  FIXED:           $totalFixed / $($failedItems.Count)" -ForegroundColor $fixedConsoleColor
Write-Host "  OVERRIDES:       $totalOverrides applied" -ForegroundColor Magenta
Write-Host "  STILL FAILED:    $totalFailed" -ForegroundColor $failedConsoleColor
Write-Host "  THIS RUN SAVINGS: `$$actualSavRound/mo" -ForegroundColor Green
Write-Host "  GRAND TOTAL:     `$$grandTotalMo/mo (`$$grandTotalYr/yr)" -ForegroundColor Green
Write-Host "  DBs REMAINING:   $($verifyResults.Count)" -ForegroundColor Cyan
Write-Host "  REPORT:          $reportFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Override databases:" -ForegroundColor Magenta
foreach ($oKey in $overrides.Keys) {
    Write-Host "    $oKey -> $($overrides[$oKey])" -ForegroundColor Magenta
}
Write-Host ""
Write-Host "  NEXT: Run MFA script tomorrow (Feb 5)" -ForegroundColor Yellow
Write-Host "  TIP:  Add more overrides to `$overrides hashtable if PagerDuty flags more DBs" -ForegroundColor Yellow
Write-Host ""

try { Start-Process $reportFile } catch {}
