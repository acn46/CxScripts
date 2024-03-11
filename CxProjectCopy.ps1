# CxProjectCopy.ps1
#
# Copyright 2021 Checkmarx
#
# Version 0.2.0a2
#
# This script copies a project, including triage results for the
# latest successful full scan, from one CxSAST instance to another.
param (
    # The base URL of the source CxSAST instance
    [Parameter(Mandatory=$true)]
    [string]
    $srcUrl,

    # The username for the source CxSAST instance
    [Parameter(Mandatory=$true)]
    [string]
    $srcUsername,

    # The username for the destination CxSAST instance
    [Parameter(Mandatory=$true)]
    [string]
    $srcPassword,

    # The base URL for the destination CxSAST instance
    [Parameter(Mandatory=$true)]
    [string]
    $dstUrl,

    # The username for the destination CxSAST instance
    [Parameter(Mandatory=$true)]
    [string]
    $dstUsername,

    # The password for the destination CxSAST instance
    [Parameter(Mandatory=$true)]
    [string]
    $dstPassword,

    # The path of a file containing the projects to copy and their
    # destination project names
    [Parameter(Mandatory=$true)]
    [ValidateScript({ Test-Path -PathType Leaf $_ })]
    [string]
    $mappingFile
)

Set-StrictMode -Version 3.0

# TODO: make these parameters?
######## What to Update ? - Config ########
$updateComments = $true
$updateSeverity = $true
$updateState = $true
$updateAssignee = $false

######## Results Update Rate - Config ########
$resultsProcessPrintRate = 5 #Print Every 5% the Progress of comparing results
$resultsUpdateRate = 100 #Update 100 Results at Once

$contentType = "text/xml; charset=utf-8"
$openSoapEnvelope = '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
$closeSoapEnvelope = '</soap:Body></soap:Envelope>'
$actionPrefix = 'http://Checkmarx.com'

######## Get URL ########
function getUrl($server) {
    return "${server}/CxWebInterface/Portal/CxWebService.asmx"
}

######## Get Proxy ########
function getProxy($url) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    return New-WebServiceProxy -Uri "${url}?wsdl"
}

######## Login ########
function getToken($server, $username, $password) {
    Write-Host "getToken: Logging in to $server as $username"
    $body = @{
        username = $username
        password = $password
        grant_type = "password"
        scope = "offline_access sast_api"
        client_id = "resource_owner_sast_client"
        client_secret = "014DF517-39D1-4453-B7B3-9930C563627C"
    }

    try {
        $response = Invoke-RestMethod -uri "${server}/cxrestapi/auth/identity/connect/token" -method post -body $body -contenttype 'application/x-www-form-urlencoded'
    } catch {
        Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__
        Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
        $result = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($result)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $responseBody = $reader.ReadToEnd()
        Write-Host $responseBody
        throw "Could not authenticate - User: ${username}"
    }

    return $response.token_type + " " + $response.access_token
}

######## Get Headers ########
function getHeaders($token, $action) {
    return @{
        Authorization = $token
        "SOAPAction" = "${actionPrefix}/${action}"
        "Content-Type" = $contentType
    }
}

######## Get Projects with Scans - Last Scan ########
function getLastScan($url, $token, $projectId) {
    Write-Host "getLastScan: projectId: ${projectId}"

    $payload = $openSoapEnvelope +'<GetScansDisplayData xmlns="http://Checkmarx.com">
                      <sessionID></sessionID>
                      <projectID>' + $projectId + '</projectID>
                    </GetScansDisplayData>' + $closeSoapEnvelope

    $headers = getHeaders $token "GetScansDisplayData"

    [xml]$res = (Invoke-WebRequest $url -Method POST -Body $payload -Headers $headers)

    $res1 = $res.Envelope.Body.GetScansDisplayDataResponse.GetScansDisplayDataResult

    if ($res1.IsSuccesfull -and $res1.ScanList.ScanDisplayData.ChildNodes.Count -gt 0){
        if (-not $res1.ScanList.ScanDisplayData[0]) {
            return $res1.ScanList.ScanDisplayData
        } else {
            return $res1.ScanList.ScanDisplayData[0]
        }
    } else {
        Write-Host "Failed to get Projects: " $res1.ErrorMessage
        Write-Host ($res1| ConvertTo-Json)
        throw "getLastScan: " + $res1.ErrorMessage
    }
}

######## Get Results for a Scan ########
function getResults($url, $token, $scanId) {
    Write-Host "getResults: scanId: ${scanId}"

    $payload = $openSoapEnvelope +'<GetResultsForScan xmlns="http://Checkmarx.com">
                      <sessionID></sessionID>
                      <scanId>' + $scanId + '</scanId>
                    </GetResultsForScan>' + $closeSoapEnvelope

    $headers = getHeaders $token "GetResultsForScan"

    [xml]$res = (Invoke-WebRequest $url -Method POST -Body $payload -Headers $headers)

    $res1 = $res.Envelope.Body.GetResultsForScanResponse.GetResultsForScanResult

    if ($res1.IsSuccesfull) {
        return $res1.Results.ChildNodes
    } else {
        Write-Host "Failed to get Results: " $res1.ErrorMessage
        throw "getResults: " + $res1.ErrorMessage
    }
}

######## Get Queries for a Scan ########
function getQueries($url, $token, $scanId) {
    Write-Host "getQueries: scanId: ${scanId}"

    $payload = $openSoapEnvelope +'<GetQueriesForScan xmlns="http://Checkmarx.com">
                      <sessionID></sessionID>
                      <scanId>' + $scanId + '</scanId>
                    </GetQueriesForScan>' + $closeSoapEnvelope

    $headers = getHeaders $token "GetQueriesForScan"

    [xml]$res = (Invoke-WebRequest $url -Method POST -Body $payload -Headers $headers)

    $res1 = $res.Envelope.Body.GetQueriesForScanResponse.GetQueriesForScanResult

    if ($res1.IsSuccesfull) {
        return $res1.Queries.ChildNodes
    } else {
        Write-Host "Failed to get Queries for Scan ID ${scanId}:" $res1.ErrorMessage
        throw "getQueries: " + $res1.ErrorMessage
    }
}

######## Get Comments for a result ########
function getComments($url, $token, $scanId, $pathId) {
    Write-Host "getComments: scanId: ${scanId}, pathId: ${pathId}"

    $payload = $openSoapEnvelope +'<GetPathCommentsHistory xmlns="http://Checkmarx.com">
                      <sessionId></sessionId>
                      <scanId>' + $scanId + '</scanId>
                      <pathId>' + $pathId + '</pathId>
                      <labelType>Remark</labelType>
                    </GetPathCommentsHistory>' + $closeSoapEnvelope
    $headers = getHeaders $token "GetPathCommentsHistory"

    [xml]$res = (Invoke-WebRequest $url -Method POST -Body $payload -Headers $headers)

    $res1 = $res.Envelope.Body.GetPathCommentsHistoryResponse.GetPathCommentsHistoryResult

    if ($res1.IsSuccesfull) {
        return $res1.Path
    } else {
        Write-Host "Failed to get Results Comments: " $res1.ErrorMessage
        throw "getComments: " + $res1.ErrorMessage
    }
}

######## Get Query From List by ID ########
function getQuery($queryList, $queryId) {
    for ($i=0; $i -lt $queryList.Length; $i++) {
        $q = $queryList[$i]
        if ($q.QueryId -eq $queryId) {
            return $q
        }
    }
    throw "Unable to get Query ${queryId}"
}

######## Check Queries are the same ########
function isEqualQuery($queriesSource, $queriesDest, $queryIdSource, $queryIdDest) {

    $sourceQuery = getQuery $queriesSource $queryIdSource
    $destQuery = getQuery $queriesDest $queryIdDest

    return $sourceQuery.LanguageName -eq $destQuery.LanguageName -and $sourceQuery.QueryName -eq $destQuery.QueryName
}

######## Remove Accents From Strings ########
function RemoveDiacritics([System.String] $text) {
    $regex = "[^a-zA-Z0-9='|/!(){}\s:-_;,]"
    if ([System.String]::IsNullOrEmpty($text)) {
        return $text -replace $regex, "_"
    }
    $normalized = $text.Normalize([System.Text.NormalizationForm]::FormD)
    $newString = New-Object -TypeName System.Text.StringBuilder

    $normalized.ToCharArray() | ForEach{
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($psitem) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$newString.Append($psitem)
        }
    }
    return $newString.ToString() -replace $regex, "_"
}

######## Get Results to Update ########
function getResultsToUpdate($urlSource, $namespace, $tokenSource, $tokenDest, $projectSource, $projectDest, $resultsSource, $resultsDest, $queriesSource, $queriesDest, $updateComments, $updateSeverity, $updateState, $updateAssignee) {
    Write-Host "getResultsToUpdate: starting"

    $rsdList = New-Object System.Collections.ArrayList
    $resultsCount = $resultsSource.Length
    for ($i=0; $i -lt $resultsSource.Length; $i++) {
        $resultsPercentage = [math]::Round(($i*100.00)/$resultsCount, 0)
        if (($resultsPercentage % $resultsProcessPrintRate) -eq 0) {
            Write-Host "getResultsToUpdate:`t5.${i} - Processing Results...(${i}/${resultsCount}) ${resultsPercentage}%"
        }
        $s = $resultsSource[$i]
        for ($j=0; $j -lt $resultsDest.Length; $j++) {
            $d = $resultsDest[$j]
            if ($s.DestFile.ToLower() -eq $d.DestFile.ToLower() -and $s.DestLine -eq $d.DestLine -and $s.DestObject.ToLower() -eq $d.DestObject.ToLower() -and
            $s.SourceFile.ToLower() -eq $d.SourceFile.ToLower() -and $s.SourceLine -eq $d.SourceLine -and $s.SourceObject.ToLower() -eq $d.SourceObject.ToLower() -and
            $s.NumberOfNodes -eq $d.NumberOfNodes -and $s.Comment.Length -gt 0) {
                $queriesAreEqual = isEqualQuery $queriesSource $queriesDest $s.QueryId $d.QueryId
                if ($queriesAreEqual) {
                    if ($updateComments) {#Comments
                        Write-Host "getResultsToUpdate:`t5.${i}.${j} - Getting Comments from Source"
                        $commentsResp = getComments $urlSource $tokenSource $projectSource.ScanID $s.PathId
                        $comments = $commentsResp.Comment
                        $comments = $comments.Split("ÿ")
                        if ($comments.Count -eq 1) {
                            $comments = $comments.Replace(' ??', "ÿ").Split("ÿ")
                        }
                        foreach ($comment in $comments) {
                            if ($comment.Length -gt 0) {
                                $rsd = New-Object("$namespace.ResultStateData")
                                $rsd.ResultLabelType = 1
                                $rsd.projectId = $projectDest.ProjectId
                                $rsd.scanId = $projectDest.ScanID
                                $rsd.PathId = $d.PathId
                                $rsd.Remarks = RemoveDiacritics $comment
                                $rsd.data = RemoveDiacritics $comment
                                $rsdList.Add($rsd) | Out-Null
                            }
                        }
                    }

                    if ($updateSeverity -and ($s.Severity -ne $d.Severity)) {#Severity
                        Write-Host "getResultsToUpdate:`t5.${i}.${j} - Getting Severity from Source"
                        $rsdg = New-Object("$namespace.ResultStateData")
                        $rsdg.projectId = $projectDest.ProjectId
                        $rsdg.scanId = $projectDest.ScanID
                        $rsdg.PathId = $d.PathId
                        $rsdg.ResultLabelType = 2
                        $rsdg.data = $s.Severity
                        $rsdList.Add($rsdg) | Out-Null
                    }

                    if ($updateState -and ($s.State -ne $d.State)) {#Result State
                        Write-Host "getResultsToUpdate:`t5.${i}.${j} - Getting Result State from Source"
                        $rsdg = New-Object("$namespace.ResultStateData")
                        $rsdg.projectId = $projectDest.ProjectId
                        $rsdg.scanId = $projectDest.ScanID
                        $rsdg.PathId = $d.PathId
                        $rsdg.ResultLabelType = 3
                        $rsdg.data = $s.State
                        $rsdList.Add($rsdg) | Out-Null
                    }

                    if ($updateAssignee -and ($s.AssignedUser -ne $d.AssignedUser)) {#assignee
                        Write-Host "getResultsToUpdate:`t5.${i}.${j} - Getting Assignee from Source"
                        $rsdg = New-Object("$namespace.ResultStateData")
                        $rsdg.projectId = $projectDest.ProjectId
                        $rsdg.scanId = $projectDest.ScanID
                        $rsdg.PathId = $d.PathId
                        $rsdg.ResultLabelType = 4
                        $rsdg.data = $s.AssignedUser
                        $rsdList.Add($rsdg) | Out-Null
                    }
                } else {
                    Write-Host "getResultsToUpdate:`t5.${i}.${j} - Queries are not the same - Query ID Source:" $s.QueryId "- Query ID Dest:" $d.QueryId
                }
            }
        }
    }
    return $rsdList
}
######## Update Results ########
function updateResults($url, $token, $list, $listLength, $count) {
    Write-Host "updateResults: starting"

    $listXml = ""
    for ($i=0; $i -lt $list.Length; $i++) {
      $item = $list[$i]
      $scanId = $item.scanId
      $pathId = $item.PathId
      $resultLabelType = $item.ResultLabelType
      if ($item.data) {
        $data = $item.data.Replace("<", "").Replace(">", "")
      } else {
        $data = ""
      }
      $projectId = $item.projectId
      if ($item.Remarks) {
        $remarks = $item.Remarks.Replace("<", "").Replace(">", "")
      } else {
        $remarks= ""
      }
      $listXml += "<ResultStateData><scanId>${scanId}</scanId><PathId>${pathId}</PathId><projectId>${projectId}</projectId><Remarks>${remarks}</Remarks><ResultLabelType>${resultLabelType}</ResultLabelType><data>${data}</data></ResultStateData>"
    }

    $payload = $openSoapEnvelope +'<UpdateSetOfResultState xmlns="http://Checkmarx.com">
                      <sessionID></sessionID>
                      <resultsStates>' + $listXml + '</resultsStates>
                    </UpdateSetOfResultState>' + $closeSoapEnvelope

    Write-Host "updateResults:`t6.1.1 - Payload: ${payload}"
    $headers = getHeaders $token "UpdateSetOfResultState"

    [xml]$res = (Invoke-WebRequest $url -Method POST -Body $payload -Headers $headers)

    $res1 = $res.Envelope.Body.UpdateSetOfResultStateResponse.UpdateSetOfResultStateResult

    if ($res1.IsSuccesfull) {
        $percentage = [math]::Round($count*100.00/$listLength,2)
        Write-Host "updateResults:`t6.1.2 - Updated ${percentage}% (${count}/${listLength})"
    } else {
        Write-Host "updateResults:`t6.1.1 - Error Updating : " $res1.ErrorMessage
        throw "updateResults: " + $res1.ErrorMessage
    }
}

function copyTriageResults($serverSource, $serverDest, $tokenSource, $tokenDest, $projectIdSource, $projectIdDest) {
    <#
    .SYNOPSIS
        Copy triage results from a scan on one CxSAST instance to a
        scan on another CxSAST instance
    #>

    Write-Host "copyTriageResults: projectIdSource: ${projectIdSource}, projectIdDest: ${projectIdDest}"
    $urlSource = getUrl $serverSource
    $urlDest = getUrl $serverDest

    $proxy = getProxy $urlDest
    $namespace = $proxy.gettype().Namespace

    Write-Host "copyTriageResults: 2 - Get Project Info"
    $projectLastScanSource = getLastScan $urlSource $tokenSource $projectIdSource
    $projectNameSource = $projectLastScanSource.ProjectName
    Write-Host "copyTriageResults: `t2.1 - Get Project Info Source - " $projectIdSource $projectNameSource
    $projectLastScanDest = getLastScan $urlDest $tokenDest $projectIdDest
    $projectNameDest = $projectLastScanDest.ProjectName
    Write-Host "copyTriageResults: `t2.2 - Get Project Info Dest - " $projectIdDest $projectNameDest

    $locSource = $projectLastScanSource.LOC
    $locDest = $projectLastScanDest.LOC
    if ($locSource -ne $locDest) {
        $diffLoc = Read-Host "LOC (${locSource}) from Source is different from LOC (${locDest}) Destination. Do you want to proceed ? (y/n)"
        if ($diffLoc -ne "y") {
            continue
        }
    }

    $scanVersionSource = $projectLastScanSource.CxVersion
    $scanVersionDest = $projectLastScanDest.CxVersion

    if ($scanVersionSource -eq $scanVersionDest) {
        $list = @()

        Write-Host "copyTriageResults: 3 - Get Results for the Scans"
        Write-Host "copyTriageResults: `t3.1 - ScanID SRC:" $projectLastScanSource.ScanID
        Write-Host "copyTriageResults: `t3.2 - ScanID DEST:" $projectLastScanDest.ScanID
        $resultsSource = getResults $urlSource $tokenSource $projectLastScanSource.ScanID
        Write-Host "copyTriageResults: `t3.3 - Get Results for the Scans Source:" $resultsSource.Count
        $resultsDest = getResults $urlDest $tokenDest $projectLastScanDest.ScanID
        Write-Host "copyTriageResults: `t3.4 - Get Results for the Scans Dest:" $resultsDest.Count
        if ($resultsSource.Count -ne $resultsDest.Count) {
            $diff = Read-Host "Results from Source are different from Destination. Do you want to proceed ? (y/n)"
            if ($diff -ne "y") {
                continue
            }
        }

        Write-Host "copyTriageResults: 4 - Get Queries for the Scans"
        $queriesSource = getQueries $urlSource $tokenSource $projectLastScanSource.ScanID
        Write-Host "copyTriageResults: `t4.1 - Get Queries for the Scans Source ID" $projectLastScanSource.ScanID ":" $queriesSource.Count
        $queriesDest = getQueries $urlDest $tokenDest $projectLastScanDest.ScanID
        Write-Host "copyTriageResults: `t4.1 - Get Queries for the Scans Dest ID" $projectLastScanDest.ScanID ":" $queriesDest.Count

        Write-Host "copyTriageResults: 5 - Comparing Results"
        $list = getResultsToUpdate $urlSource $namespace $tokenSource $tokenDest $projectLastScanSource $projectLastScanDest $resultsSource $resultsDest $queriesSource $queriesDest $updateComments $updateSeverity $updateState $updateAssignee

        Write-Host "copyTriageResults: 6 - Total Updates Required: " $list.Length
        if ($list.Length -ne 0) {
            Write-Host "copyTriageResults: `t6.1 - Updating..."
            $smallList = @()
            $count = 0
            $listLength = $list.Length
            foreach ($elem in $list) {
                $smallList += $elem
                if ($smallList.Length -eq $resultsUpdateRate) {
                    $count += $resultsUpdateRate
                    updateResults $urlDest $tokenDest $smallList $listLength $count
                    $smallList = @()
                }
            }
            if ($smallList.Length -gt 0) {
                $count += $smallList.Length
                updateResults $urlDest $tokenDest $smallList $listLength $count
                $smallList = @()
            }
        } else {
            Write-Host "copyTriageResults: 7 - Nothing to Update"
        }
    } else {
        Write-Host "copyTriageResults: Different Versions of Scans - Source: " $scanVersionSource " Dest: " $scanVersionDest
    }
}

# ----<snip>----

function getAuditHeaders($token, $action) {
    <#
    .SYNOPSIS
        Returns the HTTP headers for a request for CxAuditWebService Web
        service request
    #>
    return @{
        Authorization = $token
        "SOAPAction" = "${actionPrefix}/v7/${action}"
        "Content-Type" = $contentType
    }
}

function getAuditUrl($server) {
    <#
    .SYNOPSIS
        Builds the URL of the CxAuditWebService Web service
    #>
    return "${server}/CxWebInterface/Audit/CxAuditWebService.asmx"
}

function uploadSourceCode($server, $token, $projectId, $filename) {

    $LF = "`r`n"
    $boundary = [System.Guid]::NewGuid().ToString()
    $headers = @{
        Authorization = $token
        "Content-Type" = "multipart/form-data; boundary=$boundary"
    }

    $path = Get-Location | Join-Path -ChildPath $filename

    $fileBytes = [System.IO.File]::ReadAllBytes($path)
    $fileEnc = [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetString($fileBytes)
    $body = (
        "--$boundary",
        "Content-Disposition: form-data; name=`"zippedSource`"; filename=`"$filename`"",
        "Content-Type: application/octet-stream$LF",
        $fileEnc,
        "--$boundary--$LF"
    ) -Join $LF

    try {
        $response = Invoke-RestMethod -Uri "${server}/cxrestapi/projects/${projectId}/sourceCode/attachments" -Method POST -Headers $headers -Body $body
    } catch {
        throw "Error uploading source"
    }

    return $response
}

function getTeams($server, $token) {
    $headers = @{
        Authorization = $token
    }

    try {
        $response = Invoke-RestMethod -Uri "${server}/cxrestapi/auth/teams" -Method GET -Headers $headers
    } catch {
        Write-Host "Error retrieving teams"
        throw "Could not retrieve teams"
    }

    return $response
}


function findTeam($server, $token, $teamName) {
    <#
    .SYNOPSIS
        Looks up a team and returns its identifier

    .NOTES
        Throws an exception if the team cannot be found
    #>
    Write-Host "findTeam: finding team $teamName"

    $headers = @{
        Authorization = $token
    }

    $response = Invoke-RestMethod -Uri "${server}/cxrestapi/auth/teams" -Method GET -Headers $headers
    foreach ($team in $response) {
        if ($teamName -eq $team.fullName) {
            Write-Host "findTeam: found team:" $team
            return $team.id
        }
    }

    Write-Host "${teamName}: cannot find team"
    throw "${teamName}: cannot find team"

}

function splitProjectName($projectFullName) {
    <#
    .SYNOPSIS
        Split a fully qualified project name into a team name and a
        project name
    #>
    $bits = $projectFullName.Split("/")
    $end = $bits.Length - 2
    $teamName = $bits[0..$end] -Join "/"
    $projectName = $bits[-1]

    return New-Object PsObject -Property @{
        teamName = $teamName
        projectName = $projectName
    }
}

function findProject($server, $token, $project) {
    <#
    .SYNOPSIS
        Looks up a project and returns its identifier

    .NOTES
        Returns -1 if the project cannot be found
    #>
    Write-Host "findProject: finding project" $project.projectName

    $teamId = findTeam $server $token $project.teamName
    Write-Host "findProject: teamId is $teamId"

    $headers = @{
        Authorization = $token
    }

    try {
        $response = Invoke-RestMethod -Uri "${server}/cxrestapi/projects?projectName=$($project.projectName)&teamId=${teamId}" -Method GET -Headers $headers
        foreach ($proj in $response) {
            Write-Host "findProject: found project" $project
            return $proj.id
        }
    } catch {
        Write-Host "Invoke-RestMethod failed: $PSItem"
    }

    return -1
}

function findLatestScan($server, $token, $projectId) {
    <#
    .SYNOPSIS
        Retrieves the latest scan for a project

    .NOTES
        Throws an exception if the latest scan cannot be found, was
        not successful, or was incremental
    #>
    Write-Host "findLatestScan: finding latest scan for project" $projectId

    $headers = @{
        Authorization = $token
    }

    $response = Invoke-RestMethod -Uri "${server}/cxrestapi/sast/scans?projectId=${projectId}&last=1" -Method GET -Headers $headers
    foreach ($scan in $response) {
        Write-Host "findLatestScan: found scan" $scan
        if ($scan.status.id -ne 7) {
            Write-Host "findLatestScan: scan status invalid:" $scan.status.id
            throw "findLatestScan: scan status invalid"
        }
        if ($scan.isIncremental) {
            Write-Host "findLatestScan: latest scan was incremental"
            throw "findLatestScan: latest scan was incremental"
        }
        return $scan.id
    }

    throw "findLatestScan: project ${projectId}: cannot find latest scan"
}

function getScanSettings($server, $token, $projectId) {
    <#
    .SYNOPSIS
        Retrieves the scan settings (preset and engine configuration) for a project

    .NOTES
        Throws an exception if the scan settings cannot be found
    #>
    Write-Host "findScanSettings: finding scan settings for project" $projectId

    $headers = @{
        Authorization = $token
    }

    $response = Invoke-RestMethod -Uri "${server}/cxrestapi/sast/scanSettings/${projectId}" -Method GET -Headers $headers
    Write-Host "getScanSettings: $response"
    return New-Object PsObject -Property @{
        id = $projectId
        presetId = $response.preset.id
        engineConfigurationId = $response.engineConfiguration.id
    }
}

function getExcludeSettings($server, $token, $projectId) {
    <#
    .SYNOPSIS
        Retrieves the exclude settings for a project

    .NOTES
        Throws an exception if the exclude settings cannot be found
    #>
    Write-Host "findExcludeSettings: finding exclude settings for project" $projectId

    $headers = @{
        Authorization = $token
    }

    $response = Invoke-RestMethod -Uri "${server}/cxrestapi/projects/${projectId}/sourceCode/excludeSettings" -Method GET -Headers $headers
    Write-Host "getExcludeSettings: $response"

    return New-Object PsObject -Property @{
        id = $projectId
        excludeFoldersPattern = $response.excludeFoldersPattern
        excludeFilesPattern = $response.excludeFilesPattern
    }
}

function createProject($server, $token, $teamId, $projectName) {
    <#
    .SYNOPSIS
        Creates a project

    .NOTES
        Invoke-RestMethod may throw an exception
    #>
    Write-Host "createProject: creating project" $projectName "under team" $teamId

    $headers = @{
        Authorization = $token
        "Content-Type" = "application/json"
    }

    $body = @{
        name = $projectName
        owningTeam = $teamId
        isPublic = $true
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri "${server}/cxrestapi/projects" -Method POST -Headers $headers -Body $body

    return $response.id
}

function setScanSettings($server, $token, $projectId, $scanSettings) {
    <#
    .SYNOPSIS
        Sets a project's scan settings

    .NOTES
        Invoke-RestMethod may throw an exception
    #>
    Write-Host "setScanSettings: setting scan settings for project" $projectId "to" $scanSettings

    $headers = @{
        Authorization = $token
        "Content-Type" = "application/json"
    }

    $body = @{
        projectId = $projectId
        presetId = $scanSettings.presetId
        engineConfigurationId = $scanSettings.engineConfigurationId
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri "${server}/cxrestapi/sast/scanSettings" -Method POST -Headers $headers -Body $body
}

function setExcludeSettings($server, $token, $projectId, $excludeSettings) {
    <#
    .SYNOPSIS
        Sets a project's exclude settings

    .NOTES
        Invoke-RestMethod may throw an exception
    #>
    Write-Host "setExcludeSettings: setting exclude settings for project" $projectId "to" $excludeSettings

    $headers = @{
        Authorization = $token
        "Content-Type" = "application/json"
    }

    $body = @{
        excludeFoldersPattern = $excludeSettings.excludeFoldersPattern
        excludeFilesPattern = $excludeSettings.excludeFilesPattern
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri "${server}/cxrestapi/projects/$projectId/sourceCode/excludeSettings" -Method PUT -Headers $headers -Body $body
}

function getSourceCodeForScan($server, $token, $scanId) {
    <#
    .SYNOPSIS
        Retrieves the source code associated with a scan
    .NOTES
        The source code is retrieved as Zip archive which is stored in the
        current directory.

        Throws an exception if the source code cannot be retrieved.
    #>
    Write-Host "getSourceCodeForScan: getting source code for scan" $scanId

    $payload = $openSoapEnvelope + '<GetSourceCodeForScan xmlns="http://Checkmarx.com/v7">
         <sessionID></sessionID>
         <scanId>' + $scanId + '</scanId>
</GetSourceCodeForScan>' + $closeSoapEnvelope

    $headers = getAuditHeaders $token "GetSourceCodeForScan"

    $url = getAuditUrl $server
    [xml]$res = (Invoke-WebRequest $url -Method POST -Body $payload -Headers $headers)
    $res1 = $res.Envelope.Body.GetSourceCodeForScanResponse.GetSourceCodeForScanResult
    if ($res1.IsSuccesfull -eq "true") {
        $container = $res1.sourceCodeContainer
        $path = Get-Location | Join-Path -ChildPath $container.FileName
        [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($container.ZippedFile))
        return $container.FileName
    } else {
        Write-Host "getSourceCodeForScan: Failed to get source code for scan: " + $res1.ErrorMessage
        Write-Host ($res1 | ConvertTo-Json)

        throw "getSourceCodeForScan: Failed to get source code for scan: " + $res1.ErrorMessage
    }
}

function uploadSourceCode($server, $token, $projectId, $filename) {
    <#
    .SYNOPSIS
        Uploads source code for a project

    .NOTES
        Invoke-RestMethod may throw an exception
    #>
    Write-Host "uploadSourceCode: uploading" $filename "to project" $projectId

    $LF = "`r`n"
    $boundary = [System.Guid]::NewGuid().ToString()
    $headers = @{
        Authorization = $token
        "Content-Type" = "multipart/form-data; boundary=$boundary"
    }

    $path = Get-Location | Join-Path -ChildPath $filename

    $fileBytes = [System.IO.File]::ReadAllBytes($path)
    $fileEnc = [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetString($fileBytes)
    $body = (
        "--$boundary",
        "Content-Disposition: form-data; name=`"zippedSource`"; filename=`"$filename`"",
        "Content-Type: application/octet-stream$LF",
        $fileEnc,
        "--$boundary--$LF"
    ) -Join $LF

    Invoke-RestMethod -Uri "${server}/cxrestapi/projects/${projectId}/sourceCode/attachments" -Method POST -Headers $headers -Body $body
}

function createScan($server, $token, $projectId) {
    <#
    .SYNOPSIS
        Creates a scan for a project

    .NOTES
        Invoke-RestMethod may throw an exception
    #>
    Write-Host "createScan: creating scan for project" $projectId

    $headers = @{
        Authorization = $token
        "Content-Type" = "application/json"
    }

    $body = @{
        projectId = $projectId
        isIncremental = $false
        isPublic = $true
        forceScan = $true
        comment = "Created by CxProjectScan.ps1"
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri "${server}/cxrestapi/sast/scans" -Method POST -Headers $headers -Body $body

    return $response.id
}

function waitForScan($server, $token, $scanId) {
    <#
    .SYNOPSIS
        Wait for the specified scan to complete
    .NOTES
        Throws an exception if the scan is not successful
#>
    Write-Host "waitForScan: waiting for scan" $scanId "to complete"

    $headers = @{
        Authorization = $token
    }

    while ($true) {
        $response = Invoke-RestMethod -Uri "${server}/cxrestapi/sast/scans/${scanId}" -Method GET -Headers $headers
        switch ($response.status.id) {
            7 { return }
            8 { throw "Scan $scanId cancelled" }
            9 { throw "Scan $scanId failed" }
            default {
                Write-Host -NoNewLine "."
                Start-Sleep -Seconds 30
            }
        }
    }
}

function copyProject($srcUrl, $dstUrl, $srcToken, $dstToken, $srcProject, $dstProject) {
    Write-Host "copyProject: copying $srcProject to $dstProject"
    $srcProjectId = findProject $srcUrl $srcToken $srcProject
    Write-Host "copyProject: source projectId:" $srcProjectId
    $dstTeamId = findTeam $dstUrl $dstToken $dstProject.teamName
    Write-Host "copyProject: destination teamId:" $dstTeamId
    $dstProjectId = findProject $dstUrl $dstToken $dstProject
    if ($dstProjectId -ne -1) {
        Write-Host "copyProject: destination projectId:" $dstProjectId
        throw "Destination project already exists"
    }
    $srcScanId = findLatestScan $srcUrl $srcToken $srcProjectId
    Write-Host "copyProject: srcScanId:" $srcScanId
    $srcScanSettings = getScanSettings $srcUrl $srcToken $srcProjectId
    Write-Host "copyProject: srcScanSettings:" $srcScanSettings
    $srcExcludeSettings = getExcludeSettings $srcUrl $srcToken $srcProjectId
    Write-Host "copyProject: srcExcludeSettings:" $srcExcludeSettings
    $filename = getSourceCodeForScan $srcUrl $srcToken $srcScanId
    Write-Host "copyProject: fileName:" $fileName
    try {
        $dstProjectId = createProject $dstUrl $dstToken $dstTeamId $dstProject.projectName
        Write-Host "copyProject: dstProjectId:" $dstProjectId
        setScanSettings $dstUrl $dstToken $dstProjectId $srcScanSettings
        Write-Host "copyProject: destination project scan settings updated"
        setExcludeSettings $dstUrl $dstToken $dstProjectId $srcExcludeSettings
        Write-Host "copyProject: destination project exclude settings updated"
        uploadSourceCode $dstUrl $dstToken $dstProjectId $fileName
        Write-Host "copyProject: source code uploaded to destination project"
        $dstScanId = createScan $dstUrl $dstToken $dstProjectId
        Write-Host "copyProject: dstScanId:" $dstScanId
        waitForScan $dstUrl $dstToken $dstScanId
        Write-Host "copyProject: scan $dstScanId completed"
        copyTriageResults $srcUrl $dstUrl $srcToken $dstToken $srcProjectId $dstProjectId
        Write-Host "copyProject: triage results copied"
    } finally {
        Write-Host "copyProject: deleting" $filename
        Remove-Item -Path $filename
    }
}

function main() {
    <#
    .SYNOPSIS
        Main entry point
    #>
    $srcToken = getToken $srcUrl $srcUsername $srcPassword
    $dstToken = getToken $dstUrl $dstUsername $dstPassword

    $startTime = get-date
    Import-Csv -Path $mappingFile -Header src, dst | Foreach-Object {
        $startTimeProject = get-date
        $srcProject = splitProjectName $_.src
        Write-Host "main: srcProject:" $srcProject
        $dstProject = splitProjectName $_.dst
        try {
            copyProject $srcUrl $dstUrl $srcToken $dstToken $srcProject $dstProject
        } catch {
            Write-Host $_.Exception.Message -Foreground "Red"
            Write-Host $_.ScriptStackTrace -Foreground "DarkGray"
            Write-Output "Error copying ${srcProject} to ${dstProject}: $PSItem"
        }
        $endTimeProject = get-date
        $durationProject = New-TimeSpan -Start $startTimeProject -End $endTimeProject
        Write-Host "main: srcProject: ${srcProject}: duration: ${durationProject}"
    }
    $endTime = get-date
    $duration = New-TimeSpan -Start $startTime -End $endTime
    Write-Host "main: overall duration: ${duration}"
}

main
