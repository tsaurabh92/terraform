<#
.SYNOPSIS
Reports vCenter and ESXi time drift against an NTP server.
.DESCRIPTION
For unattended Windows runs, create the credential file while signed in as the
same Windows account that runs the scheduled task, on the same computer:

    Get-Credential | Export-Clixml -Path 'C:\Secure\vcenter-credential.xml'

Windows protects the password with DPAPI for that account and computer. Limit
access to the file and use a vCenter account with the necessary read access.
The same credential is used for every vCenter in this invocation. Without
-CredentialPath, Connect-VIServer retains its usual interactive behavior.

Example scheduled task action (use absolute paths):
    powershell.exe -NoProfile -File "E:\Automation-PS\HealthCheck\TimeDrift\VcsaNTPv4.ps1" -VCenterServers "vc.example.com" -NtpServer "ntp.example.com" -CredentialPath "C:\Secure\vcenter-credential.xml"

The report uses UTC. Drift is device time minus NTP time, in seconds; positive
values mean the device is ahead. Each reference time is extrapolated from an
NTP sample to the midpoint of the device query using a monotonic clock. Network
latency and asymmetric routes limit the accuracy of this estimate.
Devices with absolute drift greater than 60 seconds are highlighted. Healthy
devices have a successful time check and drift of at most 60 seconds; failed
checks are counted separately. Totals include discovered devices only.
Each run appends UTC-timestamped events and results to the log. Protect the log
and report because they contain infrastructure names and time information.
By default, the report is saved beside the script as
Enterprise_Prod_Time_Drift_<local date and time>.html. Each run also emails the
HTML report through mail.ncrvoyix.com on port 25 without SMTP authentication or
TLS; ensure the relay and network are appropriate for the report's contents.
The saved report and email use table-based layout and inline styles for email
client compatibility.
.PARAMETER VCenterServers
One or more vCenter server names.
.PARAMETER NtpServer
NTP server to query. If omitted, configured NTP servers on connected hosts are tried.
.PARAMETER CredentialPath
Path to a PSCredential exported using Export-Clixml by the scheduled task account.
.PARAMETER ReportPath
HTML report path. The destination directory must already exist. An explicitly
provided path is used as-is and an existing report at that path is overwritten.
.PARAMETER LogPath
Log file path. The destination directory must already exist. Defaults to
vcenter-time-report.log beside the script.
#>
param(
    [Parameter(Mandatory)]
    [string[]]$VCenterServers,
    [string]$NtpServer,
    [string]$CredentialPath,
    [string]$ReportPath = (Join-Path $PSScriptRoot ("Enterprise_Prod_Time_Drift_{0}.html" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'))),
    [string]$LogPath = (Join-Path $PSScriptRoot 'vcenter-time-report.log')
)

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )
    $Timestamp = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $SingleLineMessage = $Message -replace '[\r\n]+', ' '
    Add-Content -LiteralPath $LogPath -Value "[$Timestamp] [$RunId] [$Level] $SingleLineMessage" -Encoding UTF8 -ErrorAction Stop
}

function Get-NtpTime {
    param(
        [Parameter(Mandatory)]
        [string]$Server,
        [Parameter(Mandatory)]
        [System.Diagnostics.Stopwatch]$Clock,
        [int]$TimeoutMilliseconds = 3000
    )

    $Client = [System.Net.Sockets.UdpClient]::new()
    try {
        $Client.Client.ReceiveTimeout = $TimeoutMilliseconds
        $Client.Connect($Server, 123)
        $Request = [byte[]]::new(48)
        $Request[0] = 0x1B
        $Before = $Clock.Elapsed.TotalSeconds
        [void]$Client.Send($Request, $Request.Length)

        $RemoteEndpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $Response = $Client.Receive([ref]$RemoteEndpoint)
        $After = $Clock.Elapsed.TotalSeconds
        if ($Response.Length -lt 48) {
            throw "NTP response from '$Server' was incomplete."
        }
        $Mode = $Response[0] -band 0x07
        $LeapIndicator = $Response[0] -shr 6
        if ($Mode -ne 4 -or $LeapIndicator -eq 3 -or $Response[1] -eq 0 -or $Response[1] -gt 15) {
            throw "NTP response from '$Server' does not contain a synchronized server time."
        }

        $Seconds = ([uint64]$Response[40] * 16777216) +
            ([uint64]$Response[41] * 65536) +
            ([uint64]$Response[42] * 256) +
            [uint64]$Response[43]
        $Fraction = ([uint64]$Response[44] * 16777216) +
            ([uint64]$Response[45] * 65536) +
            ([uint64]$Response[46] * 256) +
            [uint64]$Response[47]
        if ($Seconds -eq 0 -and $Fraction -eq 0) {
            throw "NTP response from '$Server' has no transmit timestamp."
        }

        $Time = [datetime]::new(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddSeconds(
            $Seconds + ($Fraction / 4294967296.0) + (($After - $Before) / 2)
        )
        [PSCustomObject]@{ TimeUTC = $Time; ElapsedSeconds = $After }
    }
    finally {
        $Client.Dispose()
    }
}

function New-TimeResult {
    param(
        [string]$VCenter,
        [string]$Type,
        [string]$Name,
        [string]$NtpSource,
        [datetime]$Time,
        [double]$QueryMidpoint,
        $NtpSample,
        [string]$ErrorMessage
    )

    $ReferenceTime = $null
    $Drift = $null
    $DeviceTime = $null
    $Health = 'Unknown'
    if (-not $ErrorMessage) {
        $DeviceTime = $Time.ToUniversalTime()
        $ReferenceTime = $NtpSample.TimeUTC.AddSeconds($QueryMidpoint - $NtpSample.ElapsedSeconds)
        $RawDrift = ($DeviceTime - $ReferenceTime).TotalSeconds
        $Drift = [math]::Round($RawDrift, 2)
        $Health = if ([math]::Abs($RawDrift) -gt 60) { 'Drift > 60 seconds' } else { 'Healthy' }
    }
    [PSCustomObject]@{
        VCenter       = $VCenter
        Type          = $Type
        Name          = $Name
        DeviceTimeUTC = if ($null -ne $DeviceTime) { $DeviceTime.ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '' }
        NTPServer     = $NtpSource
        NTPTimeUTC    = if ($null -ne $ReferenceTime) { $ReferenceTime.ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '' }
        DriftSeconds  = $Drift
        Health        = $Health
        Status        = if ($ErrorMessage) { "Error: $ErrorMessage" } else { 'OK' }
    }
}

function ConvertTo-ReportTable {
    param(
        [object[]]$Rows,
        [string[]]$Properties
    )

    $Rows | ConvertTo-Html -Fragment -Property $Properties |
        ForEach-Object {
            $_ -replace '<colgroup>.*</colgroup>', '' `
               -replace '<table>', '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse; width:100%; margin-bottom:24px; font-family:Segoe UI, Arial, sans-serif; font-size:13px;">' `
               -replace '<th>', '<th bgcolor="#e8eef5" style="border:1px solid #cbd5e1; padding:8px; text-align:left; color:#1e293b; font-family:Segoe UI, Arial, sans-serif; font-size:13px;">' `
               -replace '<td>', '<td style="border:1px solid #cbd5e1; padding:8px; text-align:left; color:#222222; font-family:Segoe UI, Arial, sans-serif; font-size:13px; word-break:break-word;">'
        }
}

function New-TimeReport {
    param(
        [object[]]$Results,
        [object[]]$OperationalErrors,
        [string]$Generated
    )

    $Healthy = @($Results | Where-Object { $_.Health -eq 'Healthy' })
    $Drifted = @($Results | Where-Object { $_.Health -eq 'Drift > 60 seconds' })
    $Unknown = @($Results | Where-Object { $_.Health -eq 'Unknown' })
    $VCenters = @($Results | Where-Object { $_.Type -eq 'vCenter' })
    $Hosts = @($Results | Where-Object { $_.Type -eq 'ESXi' })

    $GeneratedText = [System.Net.WebUtility]::HtmlEncode($Generated)
    $Content = @(
        '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;"><tr><td style="padding:20px; font-family:Segoe UI, Arial, sans-serif; color:#222222;">'
        '<h1 style="margin:0 0 12px; font-family:Segoe UI, Arial, sans-serif; font-size:24px; color:#1e293b;">vCenter and ESXi Time Report</h1>'
        "<p style=""margin:0 0 20px; font-size:14px;"">Generated: $GeneratedText. Positive drift means the device is ahead of NTP.</p>"
        '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse; margin-bottom:20px; font-family:Segoe UI, Arial, sans-serif;">'
        '<tr>'
        "<td width=""50%"" valign=""top"" bgcolor=""#f1f5f9"" style=""border:1px solid #cbd5e1; padding:12px; font-family:Segoe UI, Arial, sans-serif; font-size:14px;"">Total devices<br><strong style=""font-size:24px; color:#1e293b;"">$($Results.Count)</strong><br>vCenter: $($VCenters.Count) | ESXi: $($Hosts.Count)</td>"
        "<td width=""50%"" valign=""top"" bgcolor=""#eef8f0"" style=""border:1px solid #cbd5e1; padding:12px; font-family:Segoe UI, Arial, sans-serif; font-size:14px;"">Healthy<br><strong style=""font-size:24px; color:#188038;"">$($Healthy.Count)</strong><br>Drift at most 60 seconds</td>"
        '</tr><tr>'
        "<td width=""50%"" valign=""top"" bgcolor=""#fdf1f0"" style=""border:1px solid #cbd5e1; padding:12px; font-family:Segoe UI, Arial, sans-serif; font-size:14px;"">Drift over 60 seconds<br><strong style=""font-size:24px; color:#c5221f;"">$($Drifted.Count)</strong><br>Ahead or behind NTP</td>"
        "<td width=""50%"" valign=""top"" bgcolor=""#fff7e8"" style=""border:1px solid #cbd5e1; padding:12px; font-family:Segoe UI, Arial, sans-serif; font-size:14px;"">Unable to check<br><strong style=""font-size:24px; color:#b06000;"">$($Unknown.Count)</strong><br>Not counted as healthy</td>"
        '</tr></table>'
        '<p style="margin:0 0 20px; font-size:13px; color:#475569;">Totals include discovered devices only; hosts behind an unreachable vCenter cannot be counted. Thresholds use unrounded drift.</p>'
        '<h2 style="margin:20px 0 10px; font-family:Segoe UI, Arial, sans-serif; font-size:18px; color:#1e293b;">Devices with drift over 60 seconds</h2>'
        if ($Drifted.Count -gt 0) {
            ConvertTo-ReportTable -Rows $Drifted -Properties VCenter, Type, Name, DriftSeconds, DeviceTimeUTC, NTPServer, NTPTimeUTC
        }
        else { '<p style="font-size:14px;">No checked devices exceeded the threshold.</p>' }
        '<h2 style="margin:20px 0 10px; font-family:Segoe UI, Arial, sans-serif; font-size:18px; color:#1e293b;">Devices unable to be checked</h2>'
        if ($Unknown.Count -gt 0) {
            ConvertTo-ReportTable -Rows $Unknown -Properties VCenter, Type, Name, Status
        }
        else { '<p style="font-size:14px;">No device time checks failed.</p>' }
        if (@($OperationalErrors).Count -gt 0) {
            '<h2 style="margin:20px 0 10px; font-family:Segoe UI, Arial, sans-serif; font-size:18px; color:#1e293b;">Operational errors</h2>'
            ConvertTo-ReportTable -Rows $OperationalErrors -Properties VCenter, Message
        }
        '<h2 style="margin:20px 0 10px; font-family:Segoe UI, Arial, sans-serif; font-size:18px; color:#1e293b;">All discovered devices</h2>'
        if ($Results.Count -gt 0) {
            ConvertTo-ReportTable -Rows $Results -Properties VCenter, Type, Name, DeviceTimeUTC, NTPServer, NTPTimeUTC, DriftSeconds, Health, Status
        }
        else { '<p style="font-size:14px;">No devices were reported.</p>' }
        '</td></tr></table>'
    )
    '<!DOCTYPE html>'
    '<html><head><meta charset="utf-8"><title>vCenter and ESXi Time Report</title></head><body style="margin:0; padding:0;">'
    $Content
    '</body></html>'
}

$ReportFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
$LogFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
if ([string]::Equals($ReportFullPath, $LogFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'ReportPath and LogPath must be different files.'
}
$RunId = [guid]::NewGuid().ToString()
Write-Log -Level 'INFO' -Message 'Time check started.'

$Credential = $null
if ($CredentialPath) {
    try {
        $Credential = Import-Clixml -LiteralPath $CredentialPath -ErrorAction Stop
        if ($Credential -isnot [System.Management.Automation.PSCredential]) {
            throw 'The credential file does not contain a PSCredential.'
        }
    }
    catch {
        Write-Log -Level 'ERROR' -Message 'Failed to load the credential file.'
        throw "Failed to load credential file '$CredentialPath': $($_.Exception.Message)"
    }
}

$Clock = [System.Diagnostics.Stopwatch]::StartNew()
$OperationalErrors = [System.Collections.Generic.List[object]]::new()
$AllResults = @(foreach ($Server in $VCenterServers) {
    $VIServer = $null
    $VMHosts = @()
    Write-Log -Level 'INFO' -Message "Checking vCenter '$Server'."
    try {
        $ConnectParameters = @{ Server = $Server; ErrorAction = 'Stop' }
        if ($Credential) {
            $ConnectParameters.Credential = $Credential
        }
        $VIServer = Connect-VIServer @ConnectParameters
        $VcInstance = Get-View -Server $VIServer -Id 'ServiceInstance' -ErrorAction Stop
        $VMHosts = @(Get-VMHost -Server $VIServer -ErrorAction Stop)
        $ConnectedHosts = @($VMHosts | Where-Object { $_.ConnectionState -eq 'Connected' })
        $HostData = @(foreach ($VMHost in $ConnectedHosts) {
            try {
                $DateTimeSystem = Get-View -Server $VIServer -Id $VMHost.ExtensionData.ConfigManager.DateTimeSystem -ErrorAction Stop
                [PSCustomObject]@{ VMHost = $VMHost; DateTimeSystem = $DateTimeSystem; ErrorMessage = $null }
            }
            catch {
                [PSCustomObject]@{ VMHost = $VMHost; DateTimeSystem = $null; ErrorMessage = $_.Exception.Message }
            }
        })

        if ($NtpServer) {
            $NtpServers = @($NtpServer)
        }
        else {
            $NtpServers = @(
                $HostData | Where-Object { $_.DateTimeSystem } |
                    ForEach-Object { $_.DateTimeSystem.DateTimeInfo.NtpConfig.Server } |
                    Where-Object { $_ } | Select-Object -Unique
            )
            if ($NtpServers.Count -eq 0) {
                throw 'No NTP server is configured on the connected ESXi hosts. Specify -NtpServer.'
            }
        }

        $NtpSample = $null
        $UsedNtpServer = $null
        foreach ($NtpSource in $NtpServers) {
            try {
                $NtpSample = Get-NtpTime -Server $NtpSource -Clock $Clock
                $UsedNtpServer = $NtpSource
                break
            }
            catch {
                $WarningMessage = "Could not query NTP server '$NtpSource' for '$Server': $($_.Exception.Message)"
                Write-Log -Level 'WARNING' -Message $WarningMessage
                Write-Warning $WarningMessage
            }
        }
        if ($null -eq $NtpSample) {
            throw 'Unable to query any configured NTP server over UDP port 123.'
        }

        try {
            $Before = $Clock.Elapsed.TotalSeconds
            $VcTime = $VcInstance.CurrentTime()
            $After = $Clock.Elapsed.TotalSeconds
            if ($null -eq $VcTime) {
                throw 'vCenter returned no time.'
            }
            New-TimeResult -VCenter $Server -Type 'vCenter' -Name $Server -NtpSource $UsedNtpServer -Time $VcTime -QueryMidpoint (($Before + $After) / 2) -NtpSample $NtpSample
        }
        catch {
            New-TimeResult -VCenter $Server -Type 'vCenter' -Name $Server -NtpSource $UsedNtpServer -ErrorMessage $_.Exception.Message
        }

        foreach ($HostEntry in $HostData) {
            try {
                if ($HostEntry.ErrorMessage) {
                    throw $HostEntry.ErrorMessage
                }
                $Before = $Clock.Elapsed.TotalSeconds
                $HostTime = $HostEntry.DateTimeSystem.QueryDateTime()
                $After = $Clock.Elapsed.TotalSeconds
                if ($null -eq $HostTime) {
                    throw 'Host returned no time.'
                }
                New-TimeResult -VCenter $Server -Type 'ESXi' -Name $HostEntry.VMHost.Name -NtpSource $UsedNtpServer -Time $HostTime -QueryMidpoint (($Before + $After) / 2) -NtpSample $NtpSample
            }
            catch {
                New-TimeResult -VCenter $Server -Type 'ESXi' -Name $HostEntry.VMHost.Name -NtpSource $UsedNtpServer -ErrorMessage $_.Exception.Message
            }
        }
        foreach ($VMHost in $VMHosts | Where-Object { $_.ConnectionState -ne 'Connected' }) {
            New-TimeResult -VCenter $Server -Type 'ESXi' -Name $VMHost.Name -NtpSource $UsedNtpServer -ErrorMessage "Host is $($VMHost.ConnectionState)."
        }
    }
    catch {
        $Failure = $_.Exception.Message
        New-TimeResult -VCenter $Server -Type 'vCenter' -Name $Server -ErrorMessage $Failure
        foreach ($VMHost in $VMHosts) {
            New-TimeResult -VCenter $Server -Type 'ESXi' -Name $VMHost.Name -ErrorMessage "Time check unavailable: $Failure"
        }
    }
    finally {
        if ($VIServer) {
            try {
                Disconnect-VIServer -Server $VIServer -Confirm:$false -ErrorAction Stop | Out-Null
            }
            catch {
                $OperationalErrors.Add([PSCustomObject]@{ VCenter = $Server; Message = "Disconnect failed: $($_.Exception.Message)" })
            }
        }
    }
})

foreach ($Result in $AllResults) {
    $Level = if ($Result.Status -ne 'OK') { 'ERROR' } elseif ($Result.Health -eq 'Drift > 60 seconds') { 'WARNING' } else { 'INFO' }
    Write-Log -Level $Level -Message ("Result: " + ($Result | ConvertTo-Json -Compress))
}
foreach ($OperationalError in $OperationalErrors) {
    Write-Log -Level 'ERROR' -Message ("Operational error: " + ($OperationalError | ConvertTo-Json -Compress))
}

$Generated = [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss UTC')
$Html = (New-TimeReport -Results $AllResults -OperationalErrors $OperationalErrors.ToArray() -Generated $Generated) -join [Environment]::NewLine
try {
    if (-not $PSBoundParameters.ContainsKey('ReportPath')) {
        New-Item -Path $ReportPath -ItemType File -ErrorAction Stop | Out-Null
    }
    $Html | Set-Content -LiteralPath $ReportPath -Encoding UTF8 -ErrorAction Stop
}
catch {
    Write-Log -Level 'ERROR' -Message "Failed to write HTML report to '$ReportPath': $($_.Exception.Message)"
    throw
}

$AllResults | Format-Table VCenter, Type, Name, DriftSeconds, Health, Status -AutoSize
Write-Host "HTML report saved to $ReportPath"
try {
    Send-MailMessage -SmtpServer 'mail.ncrvoyix.com' -Port 25 `
        -From 'InfrastructureEngineeringReporting.Application@ncrvoyix.com' `
        -To 'saurabh.tripathi@ncrvoyix.com','Dennis.Gedeon@ncrvoyix.com', 'Simon.Weaver@ncrvoyix.com', 'GeraldE.Schul@ncrvoyix.com', 'Yia.Lee@ncrvoyix.com', 'Kritika.Gupta@ncrvoyix.com', 'VE230021@ncrvoyix.com' -Subject 'Enterprise Production vSphere Time Drift Report' `
        -Body $Html -BodyAsHtml -Encoding UTF8 -ErrorAction Stop
    Write-Log -Level 'INFO' -Message "HTML report emailed successfully. Report: $ReportPath"
}
catch {
    Write-Log -Level 'ERROR' -Message "Failed to email HTML report '$ReportPath': $($_.Exception.Message)"
    throw
}
if (@($AllResults | Where-Object { $_.Status -ne 'OK' }).Count -gt 0 -or $OperationalErrors.Count -gt 0) {
    Write-Log -Level 'ERROR' -Message "Time check completed with errors. HTML report: $ReportPath"
    Write-Error 'One or more time checks or operational steps failed. See the HTML report for details.' -ErrorAction Stop
}
Write-Log -Level 'INFO' -Message "Time check completed successfully. HTML report: $ReportPath"
