Param(
    [Parameter(Mandatory=$True,Position=1)][string]$workdir,
    [Parameter(Mandatory=$True)][string]$pushgateway_host, 
    [Parameter(Mandatory=$True)][string]$pushgateway_credentials,
    [Parameter(Mandatory=$True)][string]$pushgateway_job,
    [Parameter(Mandatory=$True)][string]$webgisdr_path,
    [Parameter(Mandatory=$True)][string]$file_properties
)


function Run-WebGisDR {
    Param (
        [string]$webgisdr_path,
        [string]$file_properties,
        [string]$stdout,
        [string]$sterr
    )
    $args = "-e -f $file_properties"
    $process = Start-Process -FilePath $webgisdr_path -Args $args -NoNewWindow -RedirectStandardError $stderr -RedirectStandardOutput $stdout -PassThru -Wait
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
        [string]$logfile
    )

    $content = Get-Content -Path $logfile

    $regex_component_time = "^The\sbackup\sof\s(.+)\shas\scompleted\sin\s[0-9]{1,2}hr:[0-9]{1,2}min:[0-9]{1,2}sec\.$"
    $path_backup
    $backup_duration

    foreach ($line in $content) {
        $matches = echo $line | select-string -Pattern $regex_component_time -AllMatches
        if ($matches.Matches.Length -gt 0) {
            # Añade cabecera de la métrica sino se había inicializado antes
            if ((Get-Item $metric_file).length -eq 0) {
                Add-Content $metric_file "# HELP arcgis_backup_duration_seconds duration of each stage execution in seconds."
                Add-Content $metric_file "# TYPE arcgis_backup_duration_seconds gauge"
            }
            $component = $matches.Matches.Groups[1] | % { $_.Value }        
            $duration_seconds = Extract-Duration-Seconds -line $line
            Add-Content $metric_file "arcgis_backup_duration_seconds{component=`"$component`"} $duration_seconds"

        } elseif (!$path_backup ) {
            $path_backup = Extract-Path-Backup -line $line
        }
    }

    Append-Metric-Size-Backup -path_backup $path_backup -metric_file $metric_file
    Append-Metric-Creation-Date -metric_file $metric_file
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
        [string]$line
    )

    $regex = "^The\sbackup\sfile\sfor\sthe\scurrent\sweb\sGIS\ssite\sis\slocated\sat\s(.*)\.$"
    $path_matches = echo $line | select-string -Pattern $regex -AllMatches
    if ($path_matches.Matches.Length -gt 0) {
        return $path_matches.Matches.Groups[1] | % { $_.Value }
    }
}


function Append-Metric-Size-Backup {
    Param (
        [string]$path_backup,
        [string]$metric_file
    )

    if (( $path_backup ) -and ( Test-Path $path_backup -PathType leaf )) {
        $backup_size = (Get-Item $path_backup).length
        Add-Content $metric_file "# HELP arcgis_backup_size size of backup in bytes."
        Add-Content $metric_file "# TYPE arcgis_backup_size gauge"
        Add-Content $metric_file "arcgis_backup_size_bytes $backup_size"
    }
}


function Append-Metric-Creation-Date {
    Param (
        [string]$metric_file
    )

    if ( (Get-Item $metric_file).length -gt 0 ) {
        $date_seconds = (Get-Date (Get-Date).ToUniversalTime() -UFormat %s).Replace(',','.')
        Add-Content $metric_file "# HELP backup_created_date_seconds created date in seconds."
        Add-Content $metric_file "# TYPE backup_created_date_seconds gauge"
        Add-Content $metric_file "arcgis_backup_created_date_seconds $date_seconds"
    }
}


function Replace-NewLine {
    Param (
        [string]$metric_file
    )

    (Get-Content $metric_file -Raw).Replace("`r`n","`n") | Set-Content -NoNewline $metric_file -Force
}


function Push-Metrics {
    Param (
        [string]$pushgateway_host,
        [string]$credential_path,
        [string]$pushgateway_job,
        [string]$metric_file
    )
    
    $credential = Import-CliXml -Path $credential_path
    $status = (Invoke-WebRequest -Uri "$pushgateway_host/metrics/job/$pushgateway_job" -Method POST -InFile $metric_file -Credential $credential).statuscode
    
    return $status
}

function Main {
    Param (
        [string]$workdir,
        [string]$pushgateway_host,
        [string]$pushgateway_credential,
        [string]$pushgateway_job,
        [string]$webgisdr_path,
        [string]$file_properties
    )

    $stdout = "$workdir\webgisrd.log"
    $stderr = "$workdir\error.log"
    $metric_file = "$workdir\metrics.txt"
    $exit_code = 0

    Run-WebGisDR -webgisdr_path $webgisdr_path -file_properties $file_properties -stdout $stdout -sterr $stderr
    Create-Metric-File -path $metric_file
    Extract-Metrics -metric_file $metric_file -logfile $stdout

    if ( (Get-Item $metric_file).length -gt 0 ) {
        Replace-NewLine -metric_file $metric_file
        $status = Push-Metrics -pushgateway_host $pushgateway_host -credential_path $pushgateway_credentials -pushgateway_job $pushgateway_job -metric_file $metric_file
        if ( $status -ne 200 ) {
            echo "ERROR - No sent metrics to pushgateway"
            $exit_code = 1
        }
    } else {
        echo "ERROR - Backup not created"
        $exit_code = 1

    }
    $host.SetShouldExit($exit_code)
    exit
}

Main  -workdir $workdir -pushgateway_host $pushgateway_host -pushgateway_credential $pushgateway_credential -pushgateway_job $pushgateway_job -webgisdr_path $webgisdr_path -file_properties $file_properties
