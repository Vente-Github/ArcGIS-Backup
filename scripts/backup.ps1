Param(
    [Parameter(Mandatory=$True,Position=1)][string]$workdir,
    [Parameter(Mandatory=$True)][string]$pushgateway_host,
    [Parameter(Mandatory=$True)][string]$pushgateway_credentials,
    [Parameter(Mandatory=$True)][string]$pushgateway_job,
    [Parameter(Mandatory=$True)][string]$webgisdr_path,
    [Parameter(Mandatory=$True)][string]$file_properties,
    [Parameter(Mandatory=$True)][string]$type,
    [Parameter(Mandatory=$True)][int]$num_keep_backups
)

$global:backup_log = $null


function Log-Message-Base
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateSet("INFO","WARN","ERROR","FATAL","DEBUG")]
        [String]$Level = "INFO",
        [Parameter(Mandatory=$true, Position=1, ValueFromPipeline)]
        [string]$LogMessage
    )
    $line = Write-Output ("{0} {1}: {2}`n" -f (Get-Date -format "yyyy-MM-ddTHH:mm:ss.fffK"), $Level, $LogMessage)
    $line | Out-File $backup_log -Encoding UTF8 -Append -NoNewline
}


function Log-Message-Info
{
    Param
    (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline)]
        [string]$LogMessage
    )
    Log-Message-Base "INFO" $LogMessage
}

function Log-Message-Error
{
    Param
    (
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline)]
        [string]$LogMessage
    )
    Log-Message-Base "ERROR" $LogMessage
}


function Run-WebGisDR {
    Param (
        [string]$webgisdr_path,
        [string]$file_properties,
        [string]$webgisdr_log
    )
    Log-Message-Info "WebGISDR starting"

    $args = "-e -f $file_properties"
    $stderr = New-TemporaryFile
    $process = Start-Process -FilePath $webgisdr_path -Args $args -NoNewWindow -RedirectStandardError $stderr -RedirectStandardOutput $webgisdr_log -PassThru -Wait

    # El proceso de webgisdr falla
    if ($process.ExitCode -ne 0) {
        throw "$stderr"
    }

    # Espera por fichero log con la traza del backup, en caso de no crearse se retorna con fallo
    $exists_webgisdr_log = (Wait-Action -Condition {Test-Path $webgisdr_log -PathType leaf})
    if ($exists_webgisdr_log -eq 0) {
        throw "File $webgisdr_log not exists"
    }

    # Chequea el log de WebGISDR para comprobar que el backup estᠣreado
    $backup_successfully = Check-Status-Backup -webgisdr_log $webgisdr_log
    if ($backup_successfully -eq 0) {
        throw "Error creating ArcGIS Enterprise backup"
    }

    Log-Message-Info "WebGISDR completed"
}


function Check-Status-Backup {
    Param (
        [string]$webgisdr_log
    )
    $regex = "^The\sWebGIS\sDR\sutility\scompleted\ssuccessfully"
    $path_matches = Get-Content -Path $webgisdr_log | Select-String -Pattern $regex -AllMatches
    if ($path_matches.Matches.Length -gt 0) {
        return 1
    }
    return 0
}


function Wait-Action {
    [OutputType([int])]
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [scriptblock]$Condition,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [int]$Timeout = 60,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [object[]]$ArgumentList,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [int]$RetryInterval = 5
    )
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (($timer.Elapsed.TotalSeconds -lt $Timeout) -and (-not (& $Condition $ArgumentList))) {
            Start-Sleep -Seconds $RetryInterval
            $totalSecs = [math]::Round($timer.Elapsed.TotalSeconds, 0)
            Log-Message-Info "Still waiting for action to complete after [$totalSecs] seconds..."
        }
        $timer.Stop()
        if ($timer.Elapsed.TotalSeconds -gt $Timeout) {
            throw 'Action did not complete before timeout period.'
        } else {
            return 1
        }
    } catch {
        return 0
    }
}

function Create-Metric-File {
    Param (
        [string]$path
    )

    if ( Test-Path $path -PathType leaf ) {
        Remove-Item $path
    }

    New-Item $path | Out-Null
    return $path
}


function Extract-Metrics {
    Param (
        [string]$metric_file,
        [string]$webgisdr_log,
        [string]$type
    )
    Log-Message-Info "Extracting metrics of WebGISDR log: $webgisdr_log"

    $content = Get-Content -Path $webgisdr_log
    $regex_component_time = "^The\sbackup\sof\s(.+)\shas\scompleted\sin\s[0-9]{1,2}hr:[0-9]{1,2}min:[0-9]{1,2}sec\.$"

    foreach ($line in $content) {
        $matches = echo $line | select-string -Pattern $regex_component_time -AllMatches
        if ($matches.Matches.Length -gt 0) {
            if ((Get-Item $metric_file).length -eq 0) {
                Add-Content $metric_file "# HELP arcgis_backup_duration_seconds duration of each stage execution in seconds."
                Add-Content $metric_file "# TYPE arcgis_backup_duration_seconds gauge"
            }
            $component = $matches.Matches.Groups[1] | % { $_.Value }
            $duration_seconds = Extract-Duration-Seconds -line $line
            Add-Content $metric_file "arcgis_backup_duration_seconds{component=`"$component`", type=`"$type`"} $duration_seconds"
        }
    }
}


function Extract-Duration-Seconds {
    Param (
        [string]$line
    )

    $regex = "([0-9]{1,2})hr:([0-9]{1,2})min:([0-9]{1,2})sec\.$"
    $matches = echo $line | select-string -Pattern $regex -AllMatches

    if ($matches.Matches.Length -gt 0) {
        $hours = $matches.Matches.Groups[1] | % { $_.Value }
        $minutes = $matches.Matches.Groups[2] | % { $_.Value }
        $seconds = $matches.Matches.Groups[3] | % { $_.Value }

        return [int]$hours * 3600 + [int]$minutes * 60 + [int]$seconds
    }
}


function Extract-Path-Backup {
    Param (
        [string]$webgisdr_log
    )

    $regex = "^The\sbackup\sfile\sfor\sthe\scurrent\sweb\sGIS\ssite\sis\slocated\sat\s(.*)\.$"
    $path_matches = Get-Content -Path $webgisdr_log | Select-String -Pattern $regex -AllMatches
    if ($path_matches.Matches.Length -gt 0) {
        return $path_matches.Matches.Groups[1] | % { $_.Value }
    }
    throw "No valid backup path"
}

function Extract-Filename-Backup {
    Param (
        [string]$path,
        [string]$type
    )

    $regex = "$type\\\\(.*\.webgissite)$"
    $path_matches = $path | Select-String -Pattern $regex -AllMatches
    if ($path_matches.Matches.Length -gt 0) {
        return $path_matches.Matches.Groups[1] | % { $_.Value }
    }
    throw "No valid filename"
}


function Append-Metric-Size-Backup {
    Param (
        [string]$path_backup,
        [string]$metric_file,
        [string]$type
    )

    if (( $path_backup ) -and ( Test-Path $path_backup -PathType leaf )) {
        $backup_size = (Get-Item $path_backup).length
        Add-Content $metric_file "# HELP arcgis_backup_size size of backup in bytes."
        Add-Content $metric_file "# TYPE arcgis_backup_size gauge"
        Add-Content $metric_file "arcgis_backup_size_bytes{type=`"$type`"} $backup_size"
    }
}


function Append-Metric-Status-Backup {
    Param (
        [string]$metric_file,
        [string]$type,
        [string]$status
    )
    Add-Content $metric_file "# HELP arcgis_backup outcome of the backup ArcGIS Enterprise job (0=failed, 1=success)."
    Add-Content $metric_file "# TYPE arcgis_backup gauge"
    Add-Content $metric_file "arcgis_backup{type=`"$type`"} $status"
}

function Append-Metric-Creation-Date {
    Param (
        [string]$metric_file,
        [string]$type
    )

    if ( (Get-Item $metric_file).length -gt 0 ) {
        $date_seconds = (Get-Date (Get-Date).ToUniversalTime() -UFormat %s).Replace(',','.')
        Add-Content $metric_file "# HELP backup_created_date_seconds created date in seconds."
        Add-Content $metric_file "# TYPE backup_created_date_seconds gauge"
        Add-Content $metric_file "arcgis_backup_created_date_seconds{type=`"$type`"} $date_seconds"
    }
}


function Replace-NewLine {
    Param (
        [string]$metric_file
    )

    (Get-Content $metric_file -Raw).Replace("`r`n","`n") | Set-Content -NoNewline $metric_file -Force
}


function Clean-Old-Backups
{
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [string]$path,
        [Parameter(Mandatory=$true, Position=1)]
        [int]$num_keep_backups = 1
    )
    Get-ChildItem -Path $path -File -Filter *.webgissite | Sort-Object -Property LastWriteTime -Descending | Select-Object -Skip $num_keep_backups |
    Foreach-Object {
        Remove-Item $_.FullName
        Log-Message-Info "Backup $_.FullName deleted"
    }
}


function Push-Metrics {
    Param (
        [string]$pushgateway_host,
        [string]$credential_path,
        [string]$pushgateway_job,
        [string]$metric_file
    )
    add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Ssl3, [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12

    if ( (Get-Item $metric_file).length -eq 0 ) {
        Log-Message-Error "No exists metrics file"
        exit 1
    }
    Replace-NewLine -metric_file $metric_file

    Log-Message-Info "Sending metrics to $pushgateway_host"

    $credential = Import-CliXml -Path $credential_path
    $status = (Invoke-WebRequest -Uri "$pushgateway_host/metrics/job/$pushgateway_job" -Method POST -InFile $metric_file -Credential $credential).statuscode

    if ( $status -ne 200 ) {
        Log-Message-Error "Error sending metrics to pushgateway"
        exit 1
    }
    Log-Message-Info "Metrics sent"
}

function Main {
    Param (
        [string]$workdir,
        [string]$pushgateway_host,
        [string]$pushgateway_credential,
        [string]$pushgateway_job,
        [string]$webgisdr_path,
        [string]$file_properties,
        [string]$type,
        [int]$num_keep_backups
    )
    $datetime = (Get-Date).ToString("s").Replace(":","-")
    $logs_path = "$workdir\logs"
    $webgisdr_log = "$logs_path\$datetime-$type-webgisdr.log"
    $global:backup_log = "$logs_path\$datetime-$type-backup.log"
    $metric_file = "$logs_path\$datetime-metrics.txt"
    $minio_path = "$workdir\mc.exe"
    $status_backup = 1

    try {
        New-Item -ItemType Directory -Force -Path $logs_path | Out-Null
        Log-Message-Info "Starting ArcGIS Enterprise backup"
        Create-Metric-File -path $metric_file
        Run-WebGisDR -webgisdr_path $webgisdr_path -file_properties $file_properties -webgisdr_log $webgisdr_log
        $path_backup = Extract-Path-Backup -webgisdr_log $webgisdr_log
        $filename_backup = Extract-Filename-Backup -path $path_backup -type $type
        Clean-Old-Backups -path $path_backup -num_keep_backups $num_keep_backups
        Extract-Metrics -metric_file $metric_file -webgisdr_log $webgisdr_log -type $type
        Append-Metric-Size-Backup -path_backup $path_backup -metric_file $metric_file -type $type
        Log-Message-Info "ArcGIS Enterprise backup completed successfully"
    } catch {
        Log-Message-Error "$_"
        $status_backup = 0
    } finally {
        Append-Metric-Status-Backup -metric_file $metric_file -type $type -status $status_backup
        Append-Metric-Creation-Date -metric_file $metric_file -type $type
        Push-Metrics -pushgateway_host $pushgateway_host -credential_path $pushgateway_credentials -pushgateway_job $pushgateway_job -metric_file $metric_file
    }
}

Main -workdir $workdir -pushgateway_host $pushgateway_host -pushgateway_credential $pushgateway_credential -pushgateway_job $pushgateway_job -webgisdr_path $webgisdr_path -file_properties $file_properties -type $type -num_keep_backups $num_keep_backups
