import requests
import getpass
import os
import json
import sys 

#source_url = input('Source Url:')
source_url = "http://172.35.1.46"
#source_username = input('Source Username:')
source_username = "admin@cx"
#source_password = getpass.getpass('Source Password:')
source_password = ""

# TODO: make these parameters?
######## What to Update ? - Config ########
updateComments = True
updateSeverity = True
updateState = True
updateAssignee = False

######## Results Update Rate - Config ########
resultsProcessPrintRate = 5 #Print Every 5% the Progress of comparing results
resultsUpdateRate = 100 #Update 100 Results at Once

contentType = "text/xml; charset=utf-8"
openSoapEnvelope = '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
closeSoapEnvelope = '</soap:Body></soap:Envelope>'
actionPrefix = 'http://Checkmarx.com'

######## Get URL ########
def get_url(server):
    return f"{server}/CxWebInterface/Portal/CxWebService.asmx"


######## Get Proxy ########
#def get_proxy(url) {
#    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#    return New-WebServiceProxy -Uri "${url}?wsdl"
#}


######## Login ########
def get_token(server, username, password) :
    print (f"getToken: Logging in to {server} as {username}")
    body = {
        "username": username,
        "password": password,
        "grant_type": "password",
        "scope": "offline_access sast_api",
        "client_id": "resource_owner_sast_client",
        "client_secret": "014DF517-39D1-4453-B7B3-9930C563627C",
    }
    api_url = f"{server}/cxrestapi/auth/identity/connect/token"
    headers = {'Content-type': 'application/x-www-form-urlencoded'}

    try:
        response = requests.post(api_url, data=body, headers=headers)
    except Exception as e:
        print(type(e))
    token = json.loads(response.text)
    return token["token_type"] + " " + token["access_token"]

######## Get Headers ########
def get_headers(token, action):
    return {
        "Authorization": token,
        "SOAPAction": f"{actionPrefix}/{action}",
        "Content-Type": contentType,
    }

######## Get Projects with Scans - Last Scan ########
def get_last_scan(url, token, projectId):
    print(f"getLastScan: projectId: ${projectId}")

    payload = openSoapEnvelope + """<GetScansDisplayData xmlns="http://Checkmarx.com">
                      <sessionID></sessionID>
                      <projectID>""" + projectId + """</projectID>
                    </GetScansDisplayData>""" + closeSoapEnvelope

    headers = get_headers(token, "GetScansDisplayData")

    response = requests.post(url, data=payload, headers=headers)
    #[xml]$res = (Invoke-WebRequest $url -Method POST -Body $payload -Headers $headers)

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


######## Get Results for a Scan ########
def get_results(url, token, scanId):
    print(f"getResults: scanId: {scanId}")

    payload = openSoapEnvelope +"""<GetResultsForScan xmlns="http://Checkmarx.com">
                      <sessionID></sessionID>
                      <scanId>""" + scanId + """</scanId>
                    </GetResultsForScan>""" + closeSoapEnvelope

    headers = get_headers(token, "GetResultsForScan")

    response = requests.post(url, data=payload, headers=headers)

    $res1 = $res.Envelope.Body.GetResultsForScanResponse.GetResultsForScanResult

    if ($res1.IsSuccesfull) {
        return $res1.Results.ChildNodes
    } else {
        Write-Host "Failed to get Results: " $res1.ErrorMessage
        throw "getResults: " + $res1.ErrorMessage
    }


######## Get Queries for a Scan ########
def get_queries(url, token, scanId):
    print(f"getQueries: scanId: {scanId}")

    payload = openSoapEnvelope +"""<GetQueriesForScan xmlns="http://Checkmarx.com">
                      <sessionID></sessionID>
                      <scanId>""" + $scanId + """</scanId>
                    </GetQueriesForScan>""" + $closeSoapEnvelope

    headers = get_headers(token, "GetQueriesForScan")

    response = requests.post(url, data=payload, headers=headers)

    $res1 = $res.Envelope.Body.GetQueriesForScanResponse.GetQueriesForScanResult

    if ($res1.IsSuccesfull) {
        return $res1.Queries.ChildNodes
    } else {
        Write-Host "Failed to get Queries for Scan ID ${scanId}:" $res1.ErrorMessage
        throw "getQueries: " + $res1.ErrorMessage
    }


######## Get Comments for a result ########
def get_comments($url, $token, $scanId, $pathId):
    Write-Host "getComments: scanId: ${scanId}, pathId: ${pathId}"

    payload = openSoapEnvelope +'<GetPathCommentsHistory xmlns="http://Checkmarx.com">
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
def get_query(queryList, queryId):
    for ($i=0; $i -lt $queryList.Length; $i++) {
        $q = $queryList[$i]
        if ($q.QueryId -eq $queryId) {
            return $q
        }
    }
    sys.exit(f"Unable to get Query {queryId}")

######## Check Queries are the same ########
def is_equal_query(queriesSource, queriesDest, queryIdSource, queryIdDest):

    $sourceQuery = getQuery $queriesSource $queryIdSource
    $destQuery = getQuery $queriesDest $queryIdDest

    return $sourceQuery.LanguageName -eq $destQuery.LanguageName -and $sourceQuery.QueryName -eq $destQuery.QueryName

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


def main():
    srcToken = get_token(source_url, source_username, source_password)

main()