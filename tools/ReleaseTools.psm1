# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#requires -Version 7.0

using module PowerShellForGitHub
using namespace System.Management.Automation

class RepoNames: IValidateSetValuesGenerator {
    # NOTE: This is super over-engineered, but it was fun.
    static [string[]] $Values = "vscode-powershell", "PowerShellEditorServices"
    [String[]] GetValidValues() { return [RepoNames]::Values }
}

$ChangelogFile = "CHANGELOG.md"

<#
.SYNOPSIS
  Given a collection of PRs, generates a bulleted list.
#>
function Get-Bullets {
    param(
        [Parameter(Mandatory)]
        [ValidateSet([RepoNames])]
        [string]$RepositoryName,

        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject[]]$PullRequests
    )
    begin {
        $SkipThanks = @(
            'andschwa'
            'daxian-dbw'
            'PaulHigin'
            'rjmholt'
            'SteveL-MSFT'
            'TylerLeonhardt'
        )

        $LabelEmoji = @{
            'Issue-Enhancement'         = '✨'
            'Issue-Bug'                 = '🐛'
            'Issue-Performance'         = '⚡️'
            'Area-Build & Release'      = '👷'
            'Area-Code Formatting'      = '💎'
            'Area-Configuration'        = '🔧'
            'Area-Debugging'            = '🔍'
            'Area-Documentation'        = '📖'
            'Area-Engine'               = '🚂'
            'Area-Folding'              = '📚'
            'Area-Integrated Console'   = '📟'
            'Area-IntelliSense'         = '🧠'
            'Area-Logging'              = '💭'
            'Area-Pester'               = '🐢'
            'Area-Script Analysis'      = '‍🕵️'
            'Area-Snippets'             = '✂️'
            'Area-Startup'              = '🛫'
            'Area-Symbols & References' = '🔗'
            'Area-Tasks'                = '✅'
            'Area-Test'                 = '🚨'
            'Area-Threading'            = '⏱️'
            'Area-UI'                   = '📺'
            'Area-Workspaces'           = '📁'
        }

        $CloseKeywords = @(
            'close'
            'closes'
            'closed'
            'fix'
            'fixes'
            'fixed'
            'resolve'
            'resolves'
            'resolved'
        )

        $IssueRegex = '(' + ($CloseKeywords -join '|') + ')\s+(?<repo>\D+)(?<number>\d+)'
    }

    process {
        $PullRequests | ForEach-Object {
            # Map all the labels to emoji (or use a default).
            # NOTE: Whitespacing here is weird.
            $emoji = if ($_.labels) {
                $LabelEmoji[$_.labels.LabelName] -join ""
            } else {
                '#️⃣ 🙏'
            }

            # Get a linked issue number if it exists (or use the PR).
            $link = if ($_.body -match $IssueRegex) {
                $number = $Matches.number
                $repo = $Matches.repo
                # Handle links to issues in both repos, in both shortcode and URLs.
                $name = [RepoNames]::Values | Where-Object { $repo -match $_ } | Select-Object -First 1
                "$($name ?? $RepositoryName) #$number"
            } else {
                "$RepositoryName #$($_.number)"
            }

            # Thank the contributor if they are not one of us.
            $thanks = if ($_.user.UserName -notin $SkipThanks) {
                "(Thanks @$($_.user.UserName)!)"
            }

            # Put the bullet point together.
            ("-", $emoji, "[$link]($($_.html_url))", "-", "$($_.title).", $thanks -join " ").Trim()
        }
    }
}

<#
.SYNOPSIS
  Gets the unpublished content from the changelog.
.DESCRIPTION
  This is used so that we can manually touch-up the automatically updated
  changelog, and then bring its contents into the extension's changelog or
  the GitHub release. It just gets the first header's contents.
#>
function Get-FirstChangelog {
    param(
        [Parameter(Mandatory)]
        [ValidateSet([RepoNames])]
        [string]$RepositoryName
    )
    $Changelog = Get-Content -Path "$PSScriptRoot/../../$RepositoryName/$ChangelogFile"
    # NOTE: The space after the header marker is important! Otherwise ### matches.
    $Header = $Changelog.Where({$_.StartsWith("## ")}, "First")
    $Changelog.Where(
        { $_ -eq $Header }, "SkipUntil"
    ).Where(
        { $_.StartsWith("## ") -and $_ -ne $Header }, "Until"
    )
}

<#
.SYNOPSIS
  Creates and checks out `release/v<version>` if not already on it.
#>
function Update-Branch {
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )
    $branch = git branch --show-current
    if ($branch -ne "release/v$Version") {
        git checkout -b "release/v$Version"
    }
}

<#
.SYNOPSIS
  Gets current version from changelog as [semver].
#>
function Get-Version {
    param(
        [Parameter(Mandatory)]
        [ValidateSet([RepoNames])]
        [string]$RepositoryName
    )
    # NOTE: The first line should always be the header.
    $Changelog = (Get-FirstChangelog -RepositoryName $RepositoryName)[0]
    if ($Changelog -match '## v(?<version>\d+\.\d+\.\d+(-preview\.?\d*)?)') {
        return [semver]$Matches.version
    } else {
        Write-Error "Couldn't find version from changelog!"
    }
}

<#
.SYNOPSIS
  Updates the CHANGELOG file with PRs merged since the last release.
.DESCRIPTION
  Uses the local Git repositories but does not pull, so ensure HEAD is where
  you want it. Creates a new branch at 'release/$Version' if not already
  checked out. Handles any merge option for PRs, but is a little slow as it
  queries all PRs.
#>
function Update-Changelog {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet([RepoNames])]
        [string]$RepositoryName,

        # TODO: Validate version style for each repo.
        [Parameter(Mandatory)]
        [ValidateScript({ $_.StartsWith("v") })]
        [string]$Version
    )
    # NOTE: This a side effect neccesary for Git operations to work.
    Push-Location -Path "$PSScriptRoot/../../$RepositoryName"

    # Get the repo object, latest release, and commits since its tag.
    $Repo = Get-GitHubRepository -OwnerName PowerShell -RepositoryName $RepositoryName
    $Commits = git rev-list "v$(Get-Version -RepositoryName $RepositoryName)..."

    # NOTE: This is a slow API as it gets all PRs, and then filters.
    $Bullets = $Repo | Get-GitHubPullRequest -State All |
        Where-Object { $_.merge_commit_sha -in $Commits } |
        Where-Object { -not $_.user.UserName.EndsWith("[bot]") } |
        Where-Object { "Ignore" -notin $_.labels.LabelName } |
        Where-Object { -not $_.title.StartsWith("[Ignore]") } |
        Where-Object { -not $_.title.StartsWith("Update CHANGELOG") } |
        Where-Object { -not $_.title.StartsWith("Bump version") } |
        Get-Bullets -RepositoryName $RepositoryName

    $NewSection = switch ($RepositoryName) {
        "vscode-powershell" {
            @(
                "#### [vscode-powershell](https://github.com/PowerShell/vscode-powershell)"
                ""
                $Bullets
                ""
                "#### [PowerShellEditorServices](https://github.com/PowerShell/PowerShellEditorServices)"
                ""
                (Get-FirstChangelog -RepositoryName "PowerShellEditorServices").Where({ $_.StartsWith("- ") }, "SkipUntil")
            )
        }
        "PowerShellEditorServices" {
            @($Bullets)
        }
    }

    $CurrentChangelog = Get-Content -Path $ChangelogFile

    @(
        $CurrentChangelog[0..1]
        "## $Version"
        "### $([datetime]::Now.ToString('dddd, MMMM dd, yyyy'))"
        ""
        $NewSection
        ""
        $CurrentChangelog[2..$CurrentChangelog.Length]
    ) | Set-Content -Encoding utf8NoBOM -Path $ChangelogFile

    if ($PSCmdlet.ShouldProcess("$RepositoryName/$ChangelogFile", "git")) {
        Update-Branch -Version $Version.Substring(1) # Has "v" prefix
        git add $ChangelogFile
        git commit -m "Update CHANGELOG for ``$Version``"
    }

    Pop-Location
}

<#
.SYNOPSIS
  Updates version in repository.
.DESCRIPTION
  Note that our Git tags and changelog prefix all versions with `v`.

  PowerShellEditorServices: version is `x.y.z-preview.d`

  - PowerShellEditorServices.psd1:
    - `ModuleVersion` variable with `'x.y.z'` string, no pre-release info
  - PowerShellEditorServices.Common.props:
    - `VersionPrefix` field with `x.y.z`
    - `VersionSuffix` field with pre-release portion excluding hyphen

  vscode-powershell: version is `yyyy.mm.x-preview`

  - package.json:
    - `version` field with `"x.y.z"` and no prefix or suffix
    - `preview` field set to `true` or `false` if version is a preview
    - `name` field has `-preview` appended similarly
    - `displayName` field has ` Preview` appended similarly
    - `description` field has `(Preview) ` prepended similarly
#>
function Update-Version {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet([RepoNames])]
        [string]$RepositoryName
    )
    # NOTE: This a side effect neccesary for Git operations to work.
    Push-Location -Path "$PSScriptRoot/../../$RepositoryName"

    $Version = Get-Version -RepositoryName $RepositoryName
    $v = "$($Version.Major).$($Version.Minor).$($Version.Patch)"
    # TODO: Maybe cleanup the replacement logic.
    switch ($RepositoryName) {
        "vscode-powershell" {
            $d = "Develop PowerShell modules, commands and scripts in Visual Studio Code!"
            if ($Version.PreReleaseLabel) {
                $name = "powershell-preview"
                $displayName = "PowerShell Preview"
                $preview = "true"
                $description = "(Preview) $d"
            } else {
                $name = "powershell"
                $displayName = "PowerShell"
                $preview = "false"
                $description = $d
            }
            $path = "package.json"
            $f = Get-Content -Path $path
            # NOTE: The prefix regex match two spaces exactly to avoid matching
            # nested objects in the file.
            $f = $f -replace '^(?<prefix>  "name":\s+")(.+)(?<suffix>",)$', "`${prefix}${name}`${suffix}"
            $f = $f -replace '^(?<prefix>  "displayName":\s+")(.+)(?<suffix>",)$', "`${prefix}${displayName}`${suffix}"
            $f = $f -replace '^(?<prefix>  "version":\s+")(.+)(?<suffix>",)$', "`${prefix}${v}`${suffix}"
            $f = $f -replace '^(?<prefix>  "preview":\s+)(.+)(?<suffix>,)$', "`${prefix}${preview}`${suffix}"
            $f = $f -replace '^(?<prefix>  "description":\s+")(.+)(?<suffix>",)$', "`${prefix}${description}`${suffix}"
            $f | Set-Content -Path $path
            git add $path
        }
        "PowerShellEditorServices" {
            $path = "PowerShellEditorServices.Common.props"
            $f = Get-Content -Path $path
            $f = $f -replace '^(?<prefix>\s+<VersionPrefix>)(.+)(?<suffix></VersionPrefix>)$', "`${prefix}${v}`${suffix}"
            $f = $f -replace '^(?<prefix>\s+<VersionSuffix>)(.*)(?<suffix></VersionSuffix>)$', "`${prefix}$($Version.PreReleaseLabel)`${suffix}"
            $f | Set-Content -Path $path
            git add $path

            $path = "module/PowerShellEditorServices/PowerShellEditorServices.psd1"
            $f = Get-Content -Path $path
            $f = $f -replace "^(?<prefix>ModuleVersion = ')(.+)(?<suffix>')`$", "`${prefix}${v}`${suffix}"
            $f | Set-Content -Path $path
            git add $path
        }
    }

    if ($PSCmdlet.ShouldProcess("$RepositoryName/v$Version", "git commit")) {
        Update-Branch -Version $Version
        git commit -m "Bump version to ``v$Version``"
    }

    Pop-Location
}

<#
.SYNOPSIS
  Creates a new draft GitHub release and Git tag from the updated changelog.
.DESCRIPTION
  Requires that the changelog has been updated first as it pulls the release
  content and new version number from it. Note that our tags and version name
  are prefixed with a `v`. Creates a Git tag if it does not already exist.
#>
function New-DraftRelease {
    param(
        [Parameter(Mandatory)]
        [ValidateSet([RepoNames])]
        [string]$RepositoryName,

        [Parameter(ValueFromPipeline)]
        [string[]]$Assets
    )
    $Version = Get-Version -RepositoryName $RepositoryName
    $Changelog = (Get-FirstChangelog -RepositoryName $RepositoryName) -join "`n"
    $ReleaseParams = @{
        Draft      = $true
        # NOTE: We rely on GitHub to create the tag at that branch.
        Tag        = "v$Version"
        Committish = "release/v$Version"
        Name       = "v$Version"
        Body       = $ChangeLog
        PreRelease = [bool]$Version.PreReleaseLabel
        OwnerName  = "PowerShell"
        RepositoryName = $RepositoryName
    }

    $Release = New-GitHubRelease @ReleaseParams
    $Assets | New-GitHubReleaseAsset -Release $Release.Id
}
