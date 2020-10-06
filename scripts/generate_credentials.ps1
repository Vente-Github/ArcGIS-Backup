Param (
    [Parameter(Mandatory=$True)][string]$user, 
    [Parameter(Mandatory=$True)][string]$password,
    [Parameter(Mandatory=$True)][string]$path
)

$secpasswd = ConvertTo-SecureString $password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($user, $secpasswd)
$credential | Export-CliXml -Path $path