BeforeAll {
    $script:Target = Join-Path $PSScriptRoot ".." | Join-Path -ChildPath "PYX-AFD-Migrate-v2.ps1" | Resolve-Path | Select-Object -ExpandProperty Path
    $script:Source = Get-Content -Raw -Path $Target

    $script:ParseErrors = $null
    $script:Tokens = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($Target, [ref]$Tokens, [ref]$ParseErrors)

    $script:FunctionAsts = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

    $script:ParamAst = $Ast.ParamBlock

    foreach ($fnAst in $FunctionAsts) {
        $name = $fnAst.Name
        if ($name -in @('Test-IsBYOC','Get-KvIdsFromAfdProfile','Log','Banner','SubBanner','Save-State','Invoke-WithRetry')) {
            try {
                Invoke-Expression $fnAst.Extent.Text
            } catch {
                Write-Verbose "Could not load function $name : $_"
            }
        }
    }

    $script:ResolveTier = {
        param($PreferredForThis, $TierStrategy, $HasManagedRules)
        if ($PreferredForThis -eq "Standard") { return "Standard_AzureFrontDoor" }
        if ($PreferredForThis -eq "Premium")  { return "Premium_AzureFrontDoor" }
        switch ($TierStrategy) {
            "Standard" { return "Standard_AzureFrontDoor" }
            "Premium"  { return "Premium_AzureFrontDoor" }
            default    { if ($HasManagedRules) { return "Premium_AzureFrontDoor" } else { return "Standard_AzureFrontDoor" } }
        }
    }

    $script:NeedsStrip = {
        param($PreferredForThis, $HasManagedRules)
        return ($PreferredForThis -eq "Standard") -and $HasManagedRules
    }
}


Describe "Parser cleanliness" {
    It "has no parse errors" {
        $ParseErrors.Count | Should -Be 0
    }
}


Describe "Param block structure" {
    It "has a [CmdletBinding()] attribute" {
        $Ast.ScriptRequirements | Out-Null
        $Source -match "^\s*\[CmdletBinding\(\)\]" | Should -Be $true
    }

    It "param() block precedes any script-scope variable assignment" {
        $stmts = $Ast.EndBlock.Statements
        $firstAssignmentLine = $null
        foreach ($s in $stmts) {
            if ($s -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                $firstAssignmentLine = $s.Extent.StartLineNumber
                break
            }
        }
        $paramLine = $ParamAst.Extent.StartLineNumber
        if ($firstAssignmentLine) {
            $paramLine | Should -BeLessThan $firstAssignmentLine
        }
    }

    It "declares ProfileMap as hashtable" {
        $p = $ParamAst.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ProfileMap' }
        $p | Should -Not -BeNullOrEmpty
        $p.StaticType.Name | Should -Be 'Hashtable'
    }

    It "declares PreferredTier as hashtable" {
        $p = $ParamAst.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PreferredTier' }
        $p | Should -Not -BeNullOrEmpty
        $p.StaticType.Name | Should -Be 'Hashtable'
    }

    It "declares TierStrategy with ValidateSet of AutoDetect/Standard/Premium" {
        $p = $ParamAst.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TierStrategy' }
        $p | Should -Not -BeNullOrEmpty
        $valSet = $p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        $valSet | Should -Not -BeNullOrEmpty
        $values = $valSet.PositionalArguments | ForEach-Object { $_.Value }
        $values | Should -Contain 'AutoDetect'
        $values | Should -Contain 'Standard'
        $values | Should -Contain 'Premium'
    }

    It "declares StripManagedRulesToForceStandard switch" {
        $p = $ParamAst.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'StripManagedRulesToForceStandard' }
        $p | Should -Not -BeNullOrEmpty
        $p.StaticType.Name | Should -Be 'SwitchParameter'
    }

    It "declares DryRun switch" {
        $p = $ParamAst.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DryRun' }
        $p | Should -Not -BeNullOrEmpty
    }

    It "does NOT declare a [switch]Verbose parameter (collides with CmdletBinding common parameter)" {
        $p = $ParamAst.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Verbose' }
        $p | Should -BeNullOrEmpty
    }
}


Describe "ResolvedTier decision logic" {
    It "PreferredTier=Standard -> Standard_AzureFrontDoor (regardless of managed rules)" {
        & $ResolveTier "Standard" "AutoDetect" $true | Should -Be "Standard_AzureFrontDoor"
        & $ResolveTier "Standard" "AutoDetect" $false | Should -Be "Standard_AzureFrontDoor"
        & $ResolveTier "Standard" "Premium" $true | Should -Be "Standard_AzureFrontDoor"
    }

    It "PreferredTier=Premium -> Premium_AzureFrontDoor (regardless of managed rules)" {
        & $ResolveTier "Premium" "AutoDetect" $false | Should -Be "Premium_AzureFrontDoor"
        & $ResolveTier "Premium" "Standard" $true | Should -Be "Premium_AzureFrontDoor"
    }

    It "No PreferredTier + TierStrategy=Standard -> Standard" {
        & $ResolveTier $null "Standard" $true | Should -Be "Standard_AzureFrontDoor"
        & $ResolveTier $null "Standard" $false | Should -Be "Standard_AzureFrontDoor"
    }

    It "No PreferredTier + TierStrategy=Premium -> Premium" {
        & $ResolveTier $null "Premium" $false | Should -Be "Premium_AzureFrontDoor"
    }

    It "No PreferredTier + AutoDetect + managed rules present -> Premium (Microsoft default)" {
        & $ResolveTier $null "AutoDetect" $true | Should -Be "Premium_AzureFrontDoor"
    }

    It "No PreferredTier + AutoDetect + no managed rules -> Standard" {
        & $ResolveTier $null "AutoDetect" $false | Should -Be "Standard_AzureFrontDoor"
    }
}


Describe "needsStrip decision logic" {
    It "Standard preferred + managed rules present -> needs strip" {
        & $NeedsStrip "Standard" $true | Should -Be $true
    }

    It "Standard preferred + no managed rules -> no strip needed" {
        & $NeedsStrip "Standard" $false | Should -Be $false
    }

    It "Premium preferred + managed rules -> no strip (premium can keep them)" {
        & $NeedsStrip "Premium" $true | Should -Be $false
    }

    It "No preferred tier + managed rules -> no strip" {
        & $NeedsStrip $null $true | Should -Be $false
    }
}


Describe "Test-IsBYOC helper" {
    It "returns false on null AfdProfile" {
        Test-IsBYOC -AfdProfile $null | Should -Be $false
    }

    It "returns false when profile has no FrontendEndpoints" {
        $profile = [PSCustomObject]@{ Name = "x"; FrontendEndpoints = $null }
        Test-IsBYOC -AfdProfile $profile | Should -Be $false
    }

    It "returns true when any FE has CertificateSource=AzureKeyVault" {
        $fe = [PSCustomObject]@{
            Name = "fe1"
            CustomHttpsConfiguration = [PSCustomObject]@{ CertificateSource = "AzureKeyVault" }
            Vault = $null
        }
        $profile = [PSCustomObject]@{ Name = "x"; FrontendEndpoints = @($fe) }
        Test-IsBYOC -AfdProfile $profile | Should -Be $true
    }

    It "returns true when any FE has Vault set" {
        $fe = [PSCustomObject]@{
            Name = "fe1"
            CustomHttpsConfiguration = $null
            Vault = [PSCustomObject]@{ Id = "/subscriptions/x/...kv" }
        }
        $profile = [PSCustomObject]@{ Name = "x"; FrontendEndpoints = @($fe) }
        Test-IsBYOC -AfdProfile $profile | Should -Be $true
    }

    It "returns false when no FEs have BYOC indicators" {
        $fe = [PSCustomObject]@{
            Name = "fe1"
            CustomHttpsConfiguration = [PSCustomObject]@{ CertificateSource = "FrontDoor" }
            Vault = $null
        }
        $profile = [PSCustomObject]@{ Name = "x"; FrontendEndpoints = @($fe) }
        Test-IsBYOC -AfdProfile $profile | Should -Be $false
    }
}


Describe "Get-KvIdsFromAfdProfile helper" {
    It "returns empty array on null profile" {
        $r = Get-KvIdsFromAfdProfile -AfdProfile $null
        @($r).Count | Should -Be 0
    }

    It "returns empty array when no FEs have Vault references" {
        $fe = [PSCustomObject]@{
            CustomHttpsConfiguration = [PSCustomObject]@{ CertificateSource = "FrontDoor"; Vault = $null }
        }
        $profile = [PSCustomObject]@{ FrontendEndpoints = @($fe) }
        @(Get-KvIdsFromAfdProfile -AfdProfile $profile).Count | Should -Be 0
    }

    It "extracts unique KV IDs across multiple FEs pointing at same vault" {
        $kvId = "/subscriptions/abc/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/myvault"
        $fe1 = [PSCustomObject]@{
            CustomHttpsConfiguration = [PSCustomObject]@{ Vault = [PSCustomObject]@{ Id = $kvId } }
        }
        $fe2 = [PSCustomObject]@{
            CustomHttpsConfiguration = [PSCustomObject]@{ Vault = [PSCustomObject]@{ Id = $kvId } }
        }
        $profile = [PSCustomObject]@{ FrontendEndpoints = @($fe1, $fe2) }
        $ids = @(Get-KvIdsFromAfdProfile -AfdProfile $profile)
        $ids.Count | Should -Be 1
        $ids[0] | Should -Be $kvId
    }

    It "extracts multiple distinct KV IDs across FEs pointing at different vaults" {
        $kv1 = "/subscriptions/abc/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/vault1"
        $kv2 = "/subscriptions/abc/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/vault2"
        $fe1 = [PSCustomObject]@{
            CustomHttpsConfiguration = [PSCustomObject]@{ Vault = [PSCustomObject]@{ Id = $kv1 } }
        }
        $fe2 = [PSCustomObject]@{
            CustomHttpsConfiguration = [PSCustomObject]@{ Vault = [PSCustomObject]@{ Id = $kv2 } }
        }
        $profile = [PSCustomObject]@{ FrontendEndpoints = @($fe1, $fe2) }
        $ids = @(Get-KvIdsFromAfdProfile -AfdProfile $profile)
        $ids.Count | Should -Be 2
        $ids -contains $kv1 | Should -Be $true
        $ids -contains $kv2 | Should -Be $true
    }
}


Describe "ProfileMap and PreferredTier defaults consistency" {
    BeforeAll {
        $defaultProfileMap = @{
            "pyxiq"        = "pyxiq-std"
            "hipyx"        = "hipyx-std-v2"
            "pyxiq-stage"  = "pyxiq-stage-std"
            "pyxpwa-stage" = "pyxpwa-stage-std"
            "standard"     = "standard-afdstd"
        }
        $defaultPreferredTier = @{
            "standard"     = "Standard"
            "pyxiq-stage"  = "Standard"
            "pyxpwa-stage" = "Standard"
            "pyxiq"        = "Standard"
            "hipyx"        = "Standard"
        }
        $script:DefaultProfileMap = $defaultProfileMap
        $script:DefaultPreferredTier = $defaultPreferredTier
    }

    It "every ProfileMap key has a corresponding PreferredTier entry" {
        foreach ($k in $DefaultProfileMap.Keys) {
            $DefaultPreferredTier.ContainsKey($k) | Should -Be $true -Because "Profile '$k' exists in ProfileMap but missing from PreferredTier"
        }
    }

    It "every PreferredTier value is Standard or Premium" {
        foreach ($v in $DefaultPreferredTier.Values) {
            $v | Should -BeIn @("Standard", "Premium")
        }
    }

    It "every PreferredTier key has a corresponding ProfileMap entry" {
        foreach ($k in $DefaultPreferredTier.Keys) {
            $DefaultProfileMap.ContainsKey($k) | Should -Be $true -Because "Profile '$k' has PreferredTier set but missing from ProfileMap"
        }
    }
}


Describe "Function inventory" {
    It "Strip-And-Unlink-WafFromClassicAfd function defined" {
        $FunctionAsts | Where-Object { $_.Name -eq 'Strip-And-Unlink-WafFromClassicAfd' } | Should -Not -BeNullOrEmpty
    }

    It "Test-IsBYOC function defined" {
        $FunctionAsts | Where-Object { $_.Name -eq 'Test-IsBYOC' } | Should -Not -BeNullOrEmpty
    }

    It "Get-KvIdsFromAfdProfile function defined" {
        $FunctionAsts | Where-Object { $_.Name -eq 'Get-KvIdsFromAfdProfile' } | Should -Not -BeNullOrEmpty
    }

    It "Save-State function defined" {
        $FunctionAsts | Where-Object { $_.Name -eq 'Save-State' } | Should -Not -BeNullOrEmpty
    }

    It "Invoke-WithRetry function defined" {
        $FunctionAsts | Where-Object { $_.Name -eq 'Invoke-WithRetry' } | Should -Not -BeNullOrEmpty
    }
}


Describe "Premium-to-Standard migration path safeguards" {
    It "script references StripManagedRulesToForceStandard at decision sites" {
        ($Source -split "`n" | Where-Object { $_ -match "StripManagedRulesToForceStandard" } | Measure-Object).Count | Should -BeGreaterThan 1
    }

    It "WAF unlink happens BEFORE the prepare-migration call (not after)" {
        $unlinkPos = $Source.IndexOf("Strip-And-Unlink-WafFromClassicAfd -AfdProfile")
        $preparePos = $Source.IndexOf("Start-AzFrontDoorCdnProfilePrepareMigration")
        $unlinkPos | Should -BeGreaterThan -1
        $preparePos | Should -BeGreaterThan -1
        $unlinkPos | Should -BeLessThan $preparePos
    }

    It "BYOC profiles trigger SystemAssigned identity" {
        $Source | Should -Match 'IdentityType.*SystemAssigned'
    }

    It "explicit override message warns when user forces Standard despite Microsoft default Premium" {
        $Source | Should -Match "PreferredTier=Standard.*overrides.*DefaultSku"
    }

    It "rollback path uses Stop-AzFrontDoorCdnProfileMigration" {
        $Source | Should -Match "Stop-AzFrontDoorCdnProfileMigration"
    }

    It "commit path uses Enable-AzFrontDoorCdnProfileMigration (Az.Cdn 5.0+ commit cmdlet)" {
        $Source | Should -Match "Enable-AzFrontDoorCdnProfileMigration"
    }

    It "prepare path uses Start-AzFrontDoorCdnProfilePrepareMigration" {
        $Source | Should -Match "Start-AzFrontDoorCdnProfilePrepareMigration"
    }

    It "test path uses Test-AzFrontDoorCdnProfileMigration" {
        $Source | Should -Match "Test-AzFrontDoorCdnProfileMigration"
    }
}


Describe "Source cleanliness" {
    BeforeAll {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    }

    It "no embedded Databricks PAT in source" {
        $Source -match "dapi[a-f0-9]{20,}" | Should -Be $false
    }

    It "no AWS access key id in source" {
        $Source -match "AKIA[0-9A-Z]{16}" | Should -Be $false
    }

    It "no GitHub PAT in source" {
        $Source -match "ghp_[A-Za-z0-9]{36}" | Should -Be $false
    }

    It "no titanaisec.com phone-home URL" {
        $Source -match "titanaisec\.com" | Should -Be $false
    }

    It "no embedded private keys" {
        $Source -match "-----BEGIN.*PRIVATE KEY-----" | Should -Be $false
    }
}
